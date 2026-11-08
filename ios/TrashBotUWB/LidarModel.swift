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
    var avoidance = AvoidanceScan()
    var worldID = UUID()
    var dots: [DepthDot] = []
    var polygon: [CGPoint] = []
    var yawDegrees: Float?
    var calibrated = false
    var floorStatus = "Looking for an actual floor surface"
    var measuredCameraHeight: Float?
    var floorPointFraction: Float?
    var processingMilliseconds: Double = 0
    var mapCells: [MapCell] = []
    var robotPosition: SIMD2<Float>?
    var robotForward: SIMD2<Float>?
    var playerTarget: MapPlayerTarget?
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
    private var avoidanceEnabled = false
    private var viewport = CGSize(width: 350, height: 420)
    private var lastTimestamp: TimeInterval = -1
    private var floor = FloorReference()
    private var worldID = UUID()
    private var avoidanceTarget: SIMD2<Float>?
    private var localMap = LocalDepthMap()
    private var playerTarget: MapPlayerTarget?
    private var minimumFrameTimestamp: TimeInterval = 0
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
    func startPreview(avoidance: Bool = false) {
        guard supportsDepth else { error = "LiDAR scene depth is unavailable on this device. Use the can’s Pro iPhone."; return }
        previewRequested = true
        previewRunning = true
        error = nil
        queue.async {
            self.sampling = true; self.avoidanceEnabled = avoidance; self.lastTimestamp = -1; self.localMap.reset()
            DispatchQueue.main.async { self.snapshot = LidarSnapshot() }
        }
        runIfNeeded()
    }
    func stopPreview() {
        previewRequested = false
        previewRunning = false
        queue.async { self.sampling = false; self.avoidanceEnabled = false }
        pauseIfUnused()
    }
    // Called by the NI delegate on the main queue; capture pose at the UWB update, not later at draw time.
    func updatePlayer(distance: Float?, horizontalAngle: Float?, direction: SIMD3<Float>?) {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              ProcessInfo.processInfo.systemUptime-frame.timestamp >= 0,
              ProcessInfo.processInfo.systemUptime-frame.timestamp < 0.25 else {
            clearPlayer(); return
        }
        let target = PlayerMapGeometry.target(distance: distance, horizontalAngle: horizontalAngle,
                                             direction: direction, camera: frame.camera.transform,
                                             timestamp: Date().timeIntervalSince1970)
        let frameTimestamp = frame.timestamp
        queue.async {
            guard frameTimestamp >= self.minimumFrameTimestamp else { return }
            self.playerTarget = target
        }
    }
    func updateAvoidanceTarget(_ target: SIMD2<Float>?) { queue.async { self.avoidanceTarget = target } }
    func clearPlayer() { queue.async { self.playerTarget = nil } }
    func clearMap() {
        queue.async {
            self.localMap.reset()
            DispatchQueue.main.async { self.snapshot.mapCells = [] }
        }
    }
    private func resetGeometry() {
        floor.reset(); localMap.reset(); playerTarget = nil; worldID = UUID(); avoidanceTarget = nil
        minimumFrameTimestamp = ProcessInfo.processInfo.systemUptime
    }
    func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        queue.async { self.viewport = size }
    }
    private func configuration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal]
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
        queue.async { self.resetGeometry() }
        session.run(configuration(), options: [.resetTracking, .removeExistingAnchors])
    }
    private func pauseIfUnused() {
        guard !uwbRequested, !previewRequested else { return }
        session.pause()
        sessionRunning = false
        queue.async {
            self.resetGeometry()
            DispatchQueue.main.async { self.snapshot = LidarSnapshot() }
        }
    }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }
    func session(_ session: ARSession, didFailWithError error: Error) {
        resetGeometry()
        DispatchQueue.main.async {
            self.error = error.localizedDescription
            self.sessionRunning = false; self.previewRunning = false
            self.snapshot = LidarSnapshot(message: "Unknown · camera session failed")
        }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        resetGeometry()
        DispatchQueue.main.async { self.snapshot = LidarSnapshot(message: "Unknown · camera interrupted; floor will reinitialize") }
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        resetGeometry()
        DispatchQueue.main.async {
            self.sessionRunning = false
            if self.uwbRequested || self.previewRequested { self.runIfNeeded() }
        }
    }
    func session(_ session: ARSession, didUpdate incoming: ARFrame) {
        // Delegate callbacks can queue behind depth work. Consume the newest frame,
        // rather than processing each old capture and building a perception backlog.
        guard sampling else { return }
        let frame = session.currentFrame ?? incoming
        let started = ProcessInfo.processInfo.systemUptime
        guard let capturedAt = DepthFrameTiming.captureDate(frameUptime:frame.timestamp,nowUptime:started,now:.now) else { return }
        guard sampling, frame.timestamp >= minimumFrameTimestamp, frame.timestamp-lastTimestamp >= 0.2 else { return }
        lastTimestamp = frame.timestamp
        var result = LidarSnapshot(timestamp: capturedAt)
        result.worldID = worldID
        switch frame.camera.trackingState {
        case .normal: result.tracking = "Normal"
        case .notAvailable: result.tracking = "Unavailable"
        case .limited(let reason): result.tracking = "Limited · \(reason)"
        }
        let transform = frame.camera.transform
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }
        let forward = SIMD3<Float>(-transform.columns.2.x, 0, -transform.columns.2.z)
        if trackingNormal {
            result.robotPosition = SIMD2(origin.x,origin.z)
            let flatForward = SIMD2(forward.x,forward.z)
            if simd_length(flatForward) > 0.1 { result.robotForward = simd_normalize(flatForward) }
            if let target = playerTarget, target.isFresh(at: Date().timeIntervalSince1970) {
                result.playerTarget = target
            }
        }
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
            var avoidanceSamples: [DepthSample] = []
            var overlay: [(point: CGPoint, depth: Float, world: SIMD3<Float>)] = []
            var attempted = 0
            func pointAt(_ x: Int, _ y: Int) -> SIMD3<Float>? {
                guard x < width, y < height else { return nil }
                let d = base.advanced(by:y*rowBytes).assumingMemoryBound(to:Float32.self)[x]
                let c = confBase.advanced(by:y*confRowBytes).assumingMemoryBound(to:UInt8.self)[x]
                guard c >= 1, d.isFinite, d >= 0.15, d <= 5 else { return nil }
                return DepthProjection.worldPoint(x:Float(x),y:Float(y),depth:d,fx:fx,fy:fy,cx:cx,cy:cy,camera:transform)
            }
            for y in stride(from: 0, to: height, by: 2) {
                let depths = base.advanced(by: y*rowBytes).assumingMemoryBound(to: Float32.self)
                let confidences = confBase.advanced(by: y*confRowBytes).assumingMemoryBound(to: UInt8.self)
                for x in stride(from: 0, to: width, by: 2) {
                    attempted += 1
                    let d = depths[x], c = confidences[x]
                    guard c >= 1, d.isFinite, d >= 0.15, d <= 5 else { continue }
                    let point = DepthProjection.worldPoint(x:Float(x),y:Float(y),depth:d,fx:fx,fy:fy,cx:cx,cy:cy,camera:transform)
                    let horizontal: Bool
                    if let right = pointAt(x+6,y), let down = pointAt(x,y+6) {
                        horizontal = DepthProjection.horizontal(point,right,down)
                    } else { horizontal = false }
                    let sample = DepthSample(world: point, confidence: c, horizontal: horizontal)
                    samples.append(sample)
                    // Keep camera overlay lightweight; use the denser cloud for map and detection.
                    if x % 4 == 0 && y % 4 == 0 {
                        if avoidanceEnabled { avoidanceSamples.append(sample) }
                        let uv = CGPoint(x: CGFloat(x)/CGFloat(width), y: CGFloat(y)/CGFloat(height)).applying(display)
                        if uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 {
                            overlay.append((uv,d,point))
                        }
                    }
                }
            }
            result.depthCoverage = attempted > 0 ? Float(samples.count)/Float(attempted) : 0
            let planeFloor = frame.anchors.compactMap { anchor -> FloorCandidate? in
                guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal,
                      plane.classification == .floor, plane.planeExtent.width >= 0.4,
                      plane.planeExtent.height >= 0.4 else { return nil }
                let p = plane.transform*SIMD4(plane.center.x,plane.center.y,plane.center.z,1)
                guard origin.y-p.y > 0.15, origin.y-p.y < 2.3,
                      simd_distance(SIMD2(origin.x,origin.z),SIMD2(p.x,p.z)) < 4 else { return nil }
                return FloorCandidate(y:p.y,source:"ARKit detected floor")
            }.min(by: { $0.y < $1.y })
            floor.initializeFromMount(cameraY:origin.y,trackingNormal:trackingNormal,timestamp:frame.timestamp)
            let candidate = DepthFloorDetection.select(samples:samples,origin:origin,previousY:floor.y,anchor:planeFloor)
            let oldFloor = floor.y
            let floorY = floor.update(candidate:candidate,trackingNormal:trackingNormal,timestamp:frame.timestamp)
            result.floorStatus = floorY == nil ? "Looking for a stable floor · point camera down" : floor.source
            if let floorY {
                result.measuredCameraHeight = origin.y-floorY
                result.floorPointFraction = samples.isEmpty ? 0 : Float(samples.filter { abs($0.world.y-floorY) <= 0.06 }.count)/Float(samples.count)
                // A corrected reference invalidates earlier floor/obstacle labels.
                if oldFloor == nil || abs(floorY-oldFloor!) > 0.02 { localMap.reset() }
            }
            result.dots = overlay.map { item in DepthDot(point:item.point,depth:item.depth,floor:floorY.map { y in abs(item.world.y-y) <= 0.06 } ?? false) }
            if let floorY, case .normal = frame.camera.trackingState {
                result.calibrated = true
                localMap.update(samples: samples, floorY: floorY, origin: SIMD2(origin.x,origin.z), now: result.timestamp.timeIntervalSince1970)
                result.mapCells = Array(localMap.cells.values)
                result.corridor = DepthGeometry.estimate(samples: samples, origin: origin, forward: forward, floorY: floorY, width: corridorWidth)
                if avoidanceEnabled {
                    result.avoidance = AvoidanceGeometry.scan(samples:avoidanceSamples,origin:origin,forward:forward,floorY:floorY,width:corridorWidth,target:avoidanceTarget)
                }
                if simd_length(forward) > 0.1 {
                    let heading = simd_normalize(forward), right = simd_cross(heading, SIMD3<Float>(0,1,0))
                    for corner in [SIMD2<Float>(-1,0.15),SIMD2<Float>(-1,3),SIMD2<Float>(1,3),SIMD2<Float>(1,0.15)] {
                        let p = SIMD3<Float>(origin.x, floorY, origin.z)+heading*corner.y+right*(corner.x*corridorWidth/2)
                        let projected = frame.camera.projectPoint(p, orientation: .portrait, viewportSize: viewport)
                        if projected.x.isFinite && projected.y.isFinite && abs(projected.x) < viewport.width*20 && abs(projected.y) < viewport.height*20 { result.polygon.append(projected) }
                    }
                }
            } else {
                result.corridor.message = floorY == nil ? "Unknown · detecting actual floor; point camera down" : "Unknown · tracking is limited"
            }
            result.message = "Depth processed on this iPhone · 5 Hz"
        } else { result.message = "Waiting for LiDAR depth and confidence" }
        result.processingMilliseconds = (ProcessInfo.processInfo.systemUptime-started)*1000
        DispatchQueue.main.async { [result] in
            guard self.previewRequested else { return }
            if Date().timeIntervalSince(result.timestamp) >= 0.4 {
                self.snapshot = LidarSnapshot(timestamp:result.timestamp,message:"Depth processing delayed; readings unavailable",
                                              floorStatus:"Camera frame delayed; waiting for fresh depth",processingMilliseconds:result.processingMilliseconds)
            } else { self.snapshot = result }
        }
    }
}
