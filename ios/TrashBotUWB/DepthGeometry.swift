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

struct MapCellKey: Hashable {
    var x: Int
    var z: Int
}
struct MapCell {
    var key: MapCellKey
    var obstacle: Bool
    var timestamp: TimeInterval
    var center: SIMD2<Float> {
        SIMD2((Float(key.x)+0.5)*LocalDepthMap.cellSize, (Float(key.z)+0.5)*LocalDepthMap.cellSize)
    }
}

// A short-lived observation map, not a navigable/free-space guarantee.
struct LocalDepthMap {
    static let cellSize: Float = 0.15
    static let lifetime: TimeInterval = 4
    private(set) var cells: [MapCellKey: MapCell] = [:]
    mutating func reset() { cells.removeAll() }
    mutating func update(samples: [DepthSample], floorY: Float, origin: SIMD2<Float>, now: TimeInterval) {
        cells = cells.filter { now-$0.value.timestamp <= Self.lifetime && simd_distance($0.value.center, origin) <= 6 }
        var floorKeys = Set<MapCellKey>()
        var hits: [MapCellKey: Int] = [:]
        for sample in samples where sample.confidence >= 1 {
            let p = sample.world
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, simd_distance(SIMD2(p.x,p.z), origin) <= 5 else { continue }
            let key = MapCellKey(x: Int((p.x/Self.cellSize).rounded(.down)), z: Int((p.z/Self.cellSize).rounded(.down)))
            let height = p.y-floorY
            if abs(height) <= 0.06 { floorKeys.insert(key) }
            if height >= 0.08 && height <= 1.5 { hits[key, default: 0] += 1 }
        }
        // Seeing floor does not prove that an older obstacle has disappeared: retain it until expiry.
        for key in floorKeys where cells[key]?.obstacle != true {
            cells[key] = MapCell(key: key, obstacle: false, timestamp: now)
        }
        for (key, count) in hits where count >= 3 {
            cells[key] = MapCell(key: key, obstacle: true, timestamp: now)
        }
    }
}

struct MapPlayerTarget {
    var position: SIMD2<Float>
    var timestamp: TimeInterval
    var approximate: Bool
    func isFresh(at time: TimeInterval) -> Bool { time-timestamp >= 0 && time-timestamp < 1 }
}

enum PlayerMapGeometry {
    // ARKit camera coordinates: +X right, +Y up, -Z out of the rear camera.
    // A bearing-only reading uses slant range as horizontal range and is explicitly approximate.
    static func target(distance: Float?, horizontalAngle: Float?, direction: SIMD3<Float>?,
                       camera: simd_float4x4, timestamp: TimeInterval) -> MapPlayerTarget? {
        guard let distance, distance.isFinite, distance > 0, distance <= 30 else { return nil }
        let origin = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite else { return nil }
        if let direction, direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
           simd_length(direction) > 0.1 {
            let d = simd_normalize(direction)*distance
            let world = camera*SIMD4(d.x,d.y,d.z,0)
            let p = origin+SIMD3(world.x,world.y,world.z)
            guard p.x.isFinite, p.z.isFinite else { return nil }
            return MapPlayerTarget(position: SIMD2(p.x,p.z), timestamp: timestamp, approximate: false)
        }
        guard let angle = horizontalAngle, angle.isFinite, abs(angle) <= .pi else { return nil }
        var forward = SIMD2(-camera.columns.2.x, -camera.columns.2.z)
        guard simd_length(forward) > 0.1 else { return nil }
        forward = simd_normalize(forward)
        let right = SIMD2(-forward.y, forward.x)
        let p = SIMD2(origin.x,origin.z) + distance*(cos(angle)*forward + sin(angle)*right)
        return MapPlayerTarget(position: p, timestamp: timestamp, approximate: true)
    }
}
