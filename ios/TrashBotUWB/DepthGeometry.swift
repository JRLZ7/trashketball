import Foundation
import simd

struct DepthSample {
    var world: SIMD3<Float>
    var confidence: UInt8
    var horizontal = false
}

struct CorridorEstimate {
    var nearestObstacle: Float?
    var observedFreeDistance: Float = 0
    var firstObservedFloorDistance: Float?
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
        var nearestFloorByRow: [Int: Float] = [:]
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
            if abs(height) <= 0.06 {
                floorCells.insert(key)
                nearestFloorByRow[row] = min(nearestFloorByRow[row] ?? along,along)
            }
            if height >= 0.08 && height <= 1.5 {
                let old = obstacleCells[key] ?? (0, along)
                obstacleCells[key] = (old.count+1, min(old.nearest, along))
            }
        }
        let occupied = obstacleCells.filter { $0.value.count >= 3 }
        let nearest = occupied.values.map(\.nearest).min()
        let firstObserved = (0..<rows).first { row in
            (0..<cols).filter { floorCells.contains(row*cols+$0) }.count >= 3
        }.flatMap { nearestFloorByRow[$0] }
        var free: Float = 0
        for row in 0..<rows {
            let seen = (0..<cols).filter { floorCells.contains(row*cols+$0) }.count
            let blocked = (0..<cols).contains { occupied[row*cols+$0] != nil }
            guard seen >= 3, !blocked else { break }
            free = min(lookahead, offset+Float(row+1)*step)
        }
        return CorridorEstimate(nearestObstacle: nearest, observedFreeDistance: free, firstObservedFloorDistance: firstObserved,
                                floorCoverage: Float(floorCells.count)/Float(rows*cols),
                                message: nearest != nil ? "Obstacle ahead" : free >= 0.65 ? "Observed floor clear" : "Unknown · insufficient floor coverage")
    }
}

// Provisional bucket dimensions; camera height is measured from detected floor.
enum AssumedRobotDimensions {
    static let width: Float = 0.30
    static let bucketHeight: Float = 0.44
    static let cameraHeight: Float = 0.25
    static let sideClearance: Float = 0.08
}

struct FloorCandidate {
    var y: Float
    var source: String
}

struct FloorReference {
    private(set) var y: Float?
    private(set) var source = "Looking for an actual floor surface"
    private var pending: FloorCandidate?
    private var count = 0
    private var lastObserved: TimeInterval = -.infinity
    // The measured mount height seeds the world floor once; camera motion must not drag it along.
    mutating func initializeFromMount(cameraY: Float, trackingNormal: Bool, timestamp: TimeInterval) {
        guard y == nil, trackingNormal, cameraY.isFinite else { return }
        y = cameraY-AssumedRobotDimensions.cameraHeight
        source = "25 cm measured mount · awaiting surface confirmation"
        lastObserved = timestamp
    }
    mutating func update(candidate: FloorCandidate?, trackingNormal: Bool, timestamp: TimeInterval) -> Float? {
        guard trackingNormal, let candidate, candidate.y.isFinite else {
            pending = nil; count = 0
            return isReliable(at: timestamp) ? y : nil
        }
        // Never step up onto a box/table when the real floor is already known.
        if let y, candidate.y > y+0.12 {
            pending = nil; count = 0
            return isReliable(at: timestamp) ? y : nil
        }
        if let pending, abs(pending.y-candidate.y) < 0.03 { count += 1 }
        else { pending = candidate; count = 1 }
        if count >= 3 {
            if let old = y, abs(old-candidate.y) < 0.06 { y = old*0.7+candidate.y*0.3 }
            else { y = candidate.y }
            source = candidate.source
            lastObserved = timestamp
        }
        return isReliable(at: timestamp) ? y : nil
    }
    func isReliable(at time: TimeInterval) -> Bool { y != nil && time-lastObserved >= 0 && time-lastObserved < 1.2 }
    mutating func reset() { self = FloorReference() }
}

// Native depth-image coordinates are unprojected before applying the AR camera pose.
enum DepthProjection {
    static func worldPoint(x: Float, y: Float, depth: Float, fx: Float, fy: Float,
                           cx: Float, cy: Float, camera: simd_float4x4) -> SIMD3<Float> {
        let world = camera*SIMD4((x-cx)/fx*depth, -(y-cy)/fy*depth, -depth, 1)
        return SIMD3(world.x,world.y,world.z)
    }
    static func horizontal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
        let u = b-a, v = c-a
        guard simd_length(u) < 0.3, simd_length(v) < 0.3 else { return false }
        let n = simd_cross(u,v), length = simd_length(n)
        return length > 0.000001 && abs(n.y)/length > 0.94
    }
}

enum DepthFloorDetection {
    // Find broad, gravity-horizontal surfaces, not a thin height band on a wall.
    static func candidate(samples: [DepthSample], origin: SIMD3<Float>) -> FloorCandidate? {
        var bins: [Int: [SIMD3<Float>]] = [:]
        for s in samples where s.confidence >= 1 && s.horizontal {
            let p = s.world, below = origin.y-p.y
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, below > 0.15, below < 2.3,
                  simd_distance(SIMD2(p.x,p.z),SIMD2(origin.x,origin.z)) < 3 else { continue }
            bins[Int((p.y/0.04).rounded()), default: []].append(p)
        }
        var candidates: [(height: Float, count: Int)] = []
        for key in bins.keys {
            let points = ((bins[key-1] ?? [])+(bins[key] ?? [])+(bins[key+1] ?? []))
            guard points.count >= 40 else { continue }
            let xs = points.map(\.x), zs = points.map(\.z)
            guard xs.max()!-xs.min()! >= 0.4, zs.max()!-zs.min()! >= 0.4 else { continue }
            let cells = Set(points.map { MapCellKey(x:Int(($0.x/0.15).rounded(.down)),z:Int(($0.z/0.15).rounded(.down))) })
            guard cells.count >= 12 else { continue }
            let heights = points.map(\.y).sorted()
            candidates.append((heights[heights.count/2], points.count))
        }
        let maxSupport = candidates.map(\.count).max() ?? 0
        guard let best = candidates.filter({ $0.count >= max(40,maxSupport/4) }).min(by: { $0.height < $1.height }) else { return nil }
        return FloorCandidate(y: best.height, source: "Depth floor estimate")
    }
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

struct ApproachDecision: Equatable {
    var action: String = "stop"
    var speed: Int = 0
    var message: String = "Waiting for live UWB and LiDAR"
}

// Reactive steering in the mounted phone's frame; no world-map target conversion.
enum GuidedApproach {
    static func evaluate(distance: Float?, angle: Float?, uwbAge: TimeInterval?, connected: Bool,
                         depthAge: TimeInterval, trackingNormal: Bool, floorReady: Bool,
                         corridor: CorridorEstimate, targetMeters: Int, previousAction: String?) -> ApproachDecision {
        func stop(_ text: String) -> ApproachDecision { ApproachDecision(message: text) }
        guard connected, let age = uwbAge, age.isFinite, age >= 0, age < 0.25,
              let distance, distance.isFinite, distance > 0, distance <= 30,
              let angle, angle.isFinite, abs(angle) <= .pi else { return stop("Stop · UWB distance or bearing unavailable/stale") }
        guard (1...3).contains(targetMeters) else { return stop("Stop · invalid stopping distance") }
        if distance <= Float(targetMeters)+0.15 { return stop("Arrived · at selected phone-to-phone distance") }
        guard depthAge.isFinite, depthAge >= 0, depthAge < 0.4, trackingNormal, floorReady else {
            return stop("Stop · waiting for recent LiDAR and Normal tracking")
        }
        if let obstacle = corridor.nearestObstacle {
            guard obstacle.isFinite, obstacle > 0 else { return stop("Stop · invalid obstacle reading") }
            if obstacle < 0.75 { return stop("Blocked · obstacle within 75 cm") }
        }
        guard corridor.observedFreeDistance.isFinite, corridor.observedFreeDistance >= 0.65 else {
            if let first = corridor.firstObservedFloorDistance, first >= 0.4 {
                return stop(String(format: "Stop · floor visible only from %.2f m; tilt camera farther down", first))
            }
            return stop("Stop · insufficient observed floor ahead")
        }
        // Turn until within ~6°, then allow forward motion until error exceeds ~13°.
        let turning = previousAction == "left" || previousAction == "right"
        if abs(angle) > (turning ? 0.10 : 0.22) {
            return ApproachDecision(action: angle > 0 ? "right" : "left", speed: 45,
                                    message: angle > 0 ? "Turn right toward player" : "Turn left toward player")
        }
        return ApproachDecision(action: "forward", speed: 50, message: "Forward · observed lane clear")
    }
}
