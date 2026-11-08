import Foundation
import simd

struct DepthSample {
    var world: SIMD3<Float>
    var confidence: UInt8
}

struct CorridorEstimate {
    var nearestObstacle: Float?
    var observedFreeDistance: Float = 0
    var floorCoverage: Float = 0
    var message: String = "Unknown · waiting for automatic floor reference"
}

// Metric geometry only; no camera, networking, or motor dependencies.
enum DepthGeometry {
    static func estimate(samples: [DepthSample], origin: SIMD3<Float>, forward: SIMD3<Float>,
                         floorY: Float, width: Float, lookahead: Float = 3) -> CorridorEstimate {
        guard width.isFinite, width >= 0.2, floorY.isFinite, lookahead.isFinite, lookahead > 0.15,
              forward.x.isFinite, forward.z.isFinite else { return CorridorEstimate() }
        var heading = SIMD3<Float>(forward.x, 0, forward.z)
        guard simd_length(heading) > 0.1 else { return CorridorEstimate(message: "Unknown · point camera forward") }
        heading = simd_normalize(heading)
        let right = simd_cross(heading, SIMD3<Float>(0, 1, 0))
        let offset: Float = 0.15, step: Float = 0.25
        let rows = Int(ceil((lookahead-offset)/step)), cols = 5
        var floorCells = Set<Int>()
        var obstacleCells: [Int: (count: Int, nearest: Float)] = [:]
        for sample in samples where sample.confidence >= 1 {
            let p = sample.world
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            let delta = p-origin
            let along = simd_dot(delta, heading), across = simd_dot(delta, right)
            guard along >= offset, along < lookahead, abs(across) < width/2 else { continue }
            let row = min(rows-1, Int((along-offset)/step))
            let col = min(cols-1, max(0, Int((across/width + 0.5)*Float(cols))))
            let key = row*cols+col, height = p.y-floorY
            if abs(height) <= 0.06 { floorCells.insert(key) }
            if height >= 0.08 && height <= 1.5 {
                let old = obstacleCells[key] ?? (0, along)
                obstacleCells[key] = (old.count+1, min(old.nearest, along))
            }
        }
        let occupied = obstacleCells.filter { $0.value.count >= 3 }
        let nearest = occupied.values.map(\.nearest).min()
        var free: Float = 0
        for row in 0..<rows {
            let seen = (0..<cols).filter { floorCells.contains(row*cols+$0) }.count
            let blocked = (0..<cols).contains { occupied[row*cols+$0] != nil }
            guard seen >= 3, !blocked else { break }
            free = min(lookahead, offset+Float(row+1)*step)
        }
        return CorridorEstimate(nearestObstacle: nearest, observedFreeDistance: free,
                                floorCoverage: Float(floorCells.count)/Float(rows*cols),
                                message: nearest != nil ? "Obstacle ahead" : free >= 0.65 ? "Observed floor clear" : "Unknown · insufficient floor coverage")
    }
}

// Provisional dimensions supplied for the orange bucket. Camera height is an explicit assumption.
enum AssumedRobotDimensions {
    static let width: Float = 0.30
    static let bucketHeight: Float = 0.44
    static let cameraHeight: Float = 0.44
    static let sideClearance: Float = 0.08
}

struct FloorReference {
    private(set) var y: Float?
    let cameraHeight: Float
    init(cameraHeight: Float = AssumedRobotDimensions.cameraHeight) { self.cameraHeight = cameraHeight }
    mutating func update(cameraY: Float, trackingNormal: Bool) -> Float? {
        if y == nil && trackingNormal && cameraY.isFinite { y = cameraY-cameraHeight }
        return y
    }
    mutating func reset() { y = nil }
}
