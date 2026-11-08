import ARKit
import SwiftUI
import simd

struct DepthDot {
    var point: CGPoint
    var depth: Float
    var floor: Bool
}

struct LidarSnapshot {
    var timestamp = Date.distantPast
    var tracking = "Not started"
    var message = "Start the camera to inspect depth"
    var depthCoverage: Float = 0
    var corridor = CorridorEstimate()
    var dots: [DepthDot] = []
    var polygon: [CGPoint] = []
    var yawDegrees: Float?
    var calibrated = false
}

final class LidarModel: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    @Published private(set) var snapshot = LidarSnapshot()
    @Published private(set) var previewRunning = false
    @Published private(set) var error: String?
    let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    private let queue = DispatchQueue(label: "trashketball.depth", qos: .userInitiated)
    private var sessionRunning = false
    private var uwbRequested = false
    private var previewRequested = false
    // These fields belong to the serial delegate queue.
    private var sampling = false
    private var viewport = CGSize(width: 350, height: 420)
    private var lastTimestamp: TimeInterval = -1
    private var floor = FloorReference()
    private let corridorWidth = AssumedRobotDimensions.width + 2*AssumedRobotDimensions.sideClearance

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }
    func acquireForUWB() {
        uwbRequested = true
        runIfNeeded()
    }
    func releaseUWB() {
        uwbRequested = false
        pauseIfUnused()
    }
    func startPreview() {
        guard supportsDepth else { error = "LiDAR scene depth is unavailable on this device. Use the can’s Pro iPhone."; return }
        previewRequested = true
        previewRunning = true
        error = nil
        queue.async { self.sampling = true; self.lastTimestamp = -1 }
        runIfNeeded()
    }
    func stopPreview() {
        previewRequested = false
        previewRunning = false
        queue.async { self.sampling = false }
        pauseIfUnused()
    }
    func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        queue.async { self.viewport = size }
    }
    private func configuration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isCollaborationEnabled = false
        config.userFaceTrackingEnabled = false
        config.initialWorldMap = nil
        if supportsDepth { config.frameSemantics.insert(.sceneDepth) }
        return config
    }
    private func runIfNeeded() {
        guard ARWorldTrackingConfiguration.isSupported else { error = "AR world tracking is unavailable on this device."; return }
        guard !sessionRunning else { return }
        sessionRunning = true
        queue.async { self.floor.reset() }
        session.run(configuration(), options: [.resetTracking, .removeExistingAnchors])
    }
    private func pauseIfUnused() {
        guard !uwbRequested, !previewRequested else { return }
        session.pause()
        sessionRunning = false
        queue.async {
            self.floor.reset()
            DispatchQueue.main.async { self.snapshot = LidarSnapshot() }
        }
    }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }
    func session(_ session: ARSession, didFailWithError error: Error) {
        floor.reset()
        DispatchQueue.main.async {
            self.error = error.localizedDescription
            self.sessionRunning = false; self.previewRunning = false
            self.snapshot = LidarSnapshot(message: "Unknown · camera session failed")
        }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        floor.reset()
        DispatchQueue.main.async { self.snapshot = LidarSnapshot(message: "Unknown · camera interrupted; floor will reinitialize") }
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        floor.reset()
        DispatchQueue.main.async {
            self.sessionRunning = false
            if self.uwbRequested || self.previewRequested { self.runIfNeeded() }
        }
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard sampling, frame.timestamp-lastTimestamp >= 0.2 else { return }
        lastTimestamp = frame.timestamp
        var result = LidarSnapshot(timestamp: .now)
        switch frame.camera.trackingState {
        case .normal: result.tracking = "Normal"
        case .notAvailable: result.tracking = "Unavailable"
        case .limited(let reason): result.tracking = "Limited · \(reason)"
        }
        let transform = frame.camera.transform
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }
        let floorY = floor.update(cameraY: origin.y, trackingNormal: trackingNormal)
        let forward = SIMD3<Float>(-transform.columns.2.x, 0, -transform.columns.2.z)
        if simd_length(forward) > 0.1 { result.yawDegrees = atan2(forward.x, -forward.z)*180 / .pi }
        if let depth = frame.sceneDepth, let confidence = depth.confidenceMap {
            let map = depth.depthMap
            CVPixelBufferLockBaseAddress(map, .readOnly)
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(map, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(map), let confBase = CVPixelBufferGetBaseAddress(confidence) else { return }
            let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
            let rowBytes = CVPixelBufferGetBytesPerRow(map), confRowBytes = CVPixelBufferGetBytesPerRow(confidence)
            let intrinsics = frame.camera.intrinsics
            let sx = Float(width)/Float(frame.camera.imageResolution.width)
            let sy = Float(height)/Float(frame.camera.imageResolution.height)
            let fx = intrinsics.columns.0.x*sx, fy = intrinsics.columns.1.y*sy
            let cx = intrinsics.columns.2.x*sx, cy = intrinsics.columns.2.y*sy
            let display = frame.displayTransform(for: .portrait, viewportSize: viewport)
            var samples: [DepthSample] = []
            var attempted = 0
            for y in stride(from: 0, to: height, by: 4) {
                let depths = base.advanced(by: y*rowBytes).assumingMemoryBound(to: Float32.self)
                let confidences = confBase.advanced(by: y*confRowBytes).assumingMemoryBound(to: UInt8.self)
                for x in stride(from: 0, to: width, by: 4) {
                    attempted += 1
                    let d = depths[x], c = confidences[x]
                    guard c >= 1, d.isFinite, d >= 0.15, d <= 5 else { continue }
                    let cameraPoint = SIMD4<Float>((Float(x)-cx)/fx*d, -(Float(y)-cy)/fy*d, -d, 1)
                    let world = transform*cameraPoint
                    let point = SIMD3<Float>(world.x, world.y, world.z)
                    samples.append(DepthSample(world: point, confidence: c))
                    let uv = CGPoint(x: CGFloat(x)/CGFloat(width), y: CGFloat(y)/CGFloat(height)).applying(display)
                    if uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 {
                        result.dots.append(DepthDot(point: uv, depth: d, floor: floorY.map { abs(point.y-$0) <= 0.06 } ?? false))
                    }
                }
            }
            result.depthCoverage = attempted > 0 ? Float(samples.count)/Float(attempted) : 0
            if let floorY, case .normal = frame.camera.trackingState {
                result.calibrated = true
                result.corridor = DepthGeometry.estimate(samples: samples, origin: origin, forward: forward, floorY: floorY, width: corridorWidth)
                if simd_length(forward) > 0.1 {
                    let heading = simd_normalize(forward), right = simd_cross(heading, SIMD3<Float>(0,1,0))
                    for corner in [SIMD2<Float>(-1,0.15),SIMD2<Float>(-1,3),SIMD2<Float>(1,3),SIMD2<Float>(1,0.15)] {
                        let p = SIMD3<Float>(origin.x, floorY, origin.z)+heading*corner.y+right*(corner.x*corridorWidth/2)
                        let projected = frame.camera.projectPoint(p, orientation: .portrait, viewportSize: viewport)
                        if projected.x.isFinite && projected.y.isFinite && abs(projected.x) < viewport.width*20 && abs(projected.y) < viewport.height*20 { result.polygon.append(projected) }
                    }
                }
            } else {
                result.corridor.message = floorY == nil ? "Unknown · waiting for normal tracking" : "Unknown · tracking is limited"
            }
            result.message = "Depth processed on this iPhone · 5 Hz"
        } else { result.message = "Waiting for LiDAR depth and confidence" }
        DispatchQueue.main.async { [result] in
            guard self.previewRequested else { return }
            // The serial queue bounds depth work to one frame; no frame backlog is created.
            self.snapshot = result
        }
    }
}
