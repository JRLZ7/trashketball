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
        // Reject raised surfaces while the known floor is still reliable. Once it
        // has expired, allow a supported observation to repair a bad old reference.
        if let y, isReliable(at:timestamp), candidate.y > y+0.12 {
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
    // A tracked anchor must be corroborated by actual horizontal depth samples.
    // Prefer an already-confirmed ground patch over an unrelated lower anchor.
    static func select(samples: [DepthSample], origin: SIMD3<Float>, previousY: Float?, anchor: FloorCandidate?) -> FloorCandidate? {
        func supported(near y: Float) -> FloorCandidate? {
            guard y.isFinite else { return nil }
            return candidate(samples:samples.filter { abs($0.world.y-y) <= 0.06 },origin:origin)
        }
        if let previousY, var previous = supported(near:previousY) {
            previous.source = "Depth-confirmed floor"
            return previous
        }
        if let anchor, var confirmed = supported(near:anchor.y) {
            confirmed.source = "ARKit + depth-confirmed floor"
            return confirmed
        }
        return candidate(samples:samples,origin:origin)
    }
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

struct ApproachDecision: Codable, Equatable {
    var recoverableSensorWait = false
    var recoveryTimeout: TimeInterval = 2
    var leftPercent: Int?
    var rightPercent: Int?
    var action: String = "stop"
    var speed: Int = 0
    var message: String = "Waiting for live UWB and LiDAR"
    var turnDegrees: Float?
    var selectedLaneDegrees: Float?
    var avoiding = false
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
            return ApproachDecision(action: angle > 0 ? "right" : "left", speed: 100,
                                    message: angle > 0 ? "Turn right toward player" : "Turn left toward player")
        }
        return ApproachDecision(action: "forward", speed: 100, message: "Forward · observed lane clear")
    }
}

struct AvoidanceLane {
    var angle: Float // radians; positive is robot-right
    var corridor: CorridorEstimate
    var isOpen: Bool {
        corridor.observedFreeDistance.isFinite && corridor.observedFreeDistance >= 0.9 &&
        (corridor.nearestObstacle.map { $0.isFinite && $0 >= 0.9 } ?? true)
    }
}
struct AvoidanceScan {
    var lanes: [AvoidanceLane] = []
    var nearestRadialObstacle: Float?
    func nearestLane(to angle: Float) -> AvoidanceLane? {
        lanes.min { abs($0.angle-angle) < abs($1.angle-angle) }
    }
}

enum AvoidanceGeometry {
    static func scan(samples: [DepthSample], origin: SIMD3<Float>, forward: SIMD3<Float>, floorY: Float,
                     width: Float = AssumedRobotDimensions.width+2*AssumedRobotDimensions.sideClearance,
                     target: SIMD2<Float>? = nil) -> AvoidanceScan {
        var h = SIMD3(forward.x,0,forward.z)
        guard simd_length(h) > 0.1 else { return AvoidanceScan() }
        h = simd_normalize(h)
        let right = simd_cross(h,SIMD3<Float>(0,1,0))
        var angles = stride(from:-60,through:60,by:15).map { Float($0)*Float.pi/180 }
        // Recheck the exact committed route as the camera turns, avoiding gaps caused
        // by rounding the same world heading to different fixed fan bins.
        if let target {
            let delta = target-SIMD2(origin.x,origin.z)
            let angle = atan2(simd_dot(delta,SIMD2(right.x,right.z)),simd_dot(delta,SIMD2(h.x,h.z)))
            if simd_length(delta) > 0.05, abs(angle) <= Float.pi/3,
               !angles.contains(where: { abs($0-angle) < 0.001 }) { angles.append(angle) }
        }
        let obstacles = samples.filter { sample in
            let height = sample.world.y-floorY
            return sample.confidence >= 1 && height >= 0.08 && height <= 1.5
        }
        let lanes = angles.map { angle -> AvoidanceLane in
            let heading = h*cos(angle)+right*sin(angle)
            var corridor = DepthGeometry.estimate(samples:samples,origin:origin,
                forward:heading,floorY:floorY,width:width,lookahead:1.4)
            // Keep the existing observed-floor core, but reject known obstacles within
            // 35 cm of a candidate centerline, matching the near-body stop radius.
            let inflated = DepthGeometry.estimate(samples:obstacles,origin:origin,
                forward:heading,floorY:floorY,width:max(width,0.70),lookahead:1.4)
            corridor.nearestObstacle = inflated.nearestObstacle
            return AvoidanceLane(angle:angle,corridor:corridor)
        }
        // Independent near-body check across all visible depth, not just the chosen lane.
        var hits: [MapCellKey:(count:Int, distance:Float)] = [:]
        for s in obstacles {
            let p = s.world, height = p.y-floorY
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, height >= 0.08, height <= 1.5 else { continue }
            let d = simd_distance(SIMD2(p.x,p.z),SIMD2(origin.x,origin.z))
            guard d < 1.5 else { continue }
            let key = MapCellKey(x:Int((p.x/0.1).rounded(.down)),z:Int((p.z/0.1).rounded(.down)))
            let old = hits[key] ?? (0,d)
            hits[key] = (old.count+1,min(old.distance,d))
        }
        return AvoidanceScan(lanes:lanes,nearestRadialObstacle:hits.values.filter { $0.count >= 3 }.map(\.distance).min())
    }
}

// Short observed detours only. Waypoints use AR coordinates to measure turn/progress;
// player direction still comes directly from Locate, never from the cyan map marker.
struct LocalAvoidanceNavigator {
    private struct Detour {
        var waypoint: SIMD2<Float>
        var origin: SIMD2<Float>
        var started: TimeInterval
    }
    private var detour: Detour?
    private var preferredSide: Float?
    private var referenceWorld: UUID?
    private var clearFrames = 0
    private var lastClearFrame: TimeInterval = -.infinity
    private var lastYaw: Float?
    private var lastYawTime: TimeInterval?
    private var yawRate: Float = 0
    var waypoint: SIMD2<Float>? { detour?.waypoint }
    mutating func reset() { self = LocalAvoidanceNavigator() }

    mutating func evaluate(distance: Float?, angle: Float?, uwbAge: TimeInterval?, connected: Bool,
                           depthAge: TimeInterval, trackingNormal: Bool, floorReady: Bool,
                           scan: AvoidanceScan, fallbackCorridor: CorridorEstimate,
                           yaw: Float?, position: SIMD2<Float>?, world: UUID, frameTime: TimeInterval,
                           now: TimeInterval, targetMeters: Int, previousAction: String?, driving: Bool) -> ApproachDecision {
        func stop(_ text: String, sensorWait: Bool = false, timeout: TimeInterval = 2) -> ApproachDecision { ApproachDecision(recoverableSensorWait:sensorWait,recoveryTimeout:timeout,message:text) }
        guard connected, let age = uwbAge, age.isFinite, age >= 0, age < 0.25,
              let distance, distance.isFinite, distance > 0, distance <= 30,
              let angle, angle.isFinite, abs(angle) <= .pi else {
            detour = nil
            return stop("Stop · UWB distance or bearing unavailable/stale", sensorWait:true)
        }
        guard (1...3).contains(targetMeters) else { return stop("Stop · invalid stopping distance") }
        if distance <= Float(targetMeters)+0.15 { detour = nil; return stop("Arrived · at selected phone-to-phone distance") }
        guard depthAge.isFinite, depthAge >= 0, depthAge < 0.4, trackingNormal, floorReady,
              let yaw, yaw.isFinite, let position, position.x.isFinite, position.y.isFinite else {
            detour = nil
            return stop("Stop · waiting for recent LiDAR and Normal tracking", sensorWait:true)
        }
        if let previousWorld = referenceWorld, previousWorld != world {
            reset(); referenceWorld = world
            return stop("Stop · AR session changed; start again")
        }
        referenceWorld = world
        if frameTime != lastYawTime {
            if let old = lastYaw, let time = lastYawTime, frameTime-time >= 0.02, frameTime-time <= 0.6 {
                let delta = atan2(sin(yaw-old),cos(yaw-old))
                let measured = max(-4,min(4,delta/Float(frameTime-time)))
                yawRate = 0.5*yawRate+0.5*measured
            } else { yawRate = 0 }
            lastYaw = yaw; lastYawTime = frameTime
        }
        if let near = scan.nearestRadialObstacle, !near.isFinite || near < 0.35 {
            return stop("Stop · obstacle within 35 cm; too close to pivot")
        }
        guard !scan.lanes.isEmpty else { return stop("Stop · waiting for left/right clearance scan", sensorWait:true) }
        let forward = SIMD2(sin(yaw),-cos(yaw)), right = SIMD2(cos(yaw),sin(yaw))
        let forwardOpen = scan.nearestLane(to:0)?.isOpen == true
        let goalLane = scan.nearestLane(to:angle)
        let goalOpen = goalLane.map { $0.isOpen && abs($0.angle-angle) <= .pi/12 } ?? false

        if let active = detour {
            if driving && now-active.started >= 8 { return stop("Stop · detour timed out; check wheels and tracking") }
            let delta = active.waypoint-position
            if simd_length(delta) > 0.9 { return stop("Stop · moving away from detour; check motor direction") }
            let moved = simd_distance(active.origin,position)
            if frameTime != lastClearFrame {
                lastClearFrame = frameTime
                clearFrames = goalOpen && moved >= 0.35 ? clearFrames+1 : 0
            }
            if simd_length(delta) <= 0.18 || clearFrames >= 3 {
                detour = nil; clearFrames = 0
            } else {
                let remaining = atan2(simd_dot(delta,right),simd_dot(delta,forward))
                guard let lane = scan.nearestLane(to:remaining), lane.isOpen,
                      abs(lane.angle-remaining) <= .pi/12 else {
                    return stop("Wait · detour blocked or not observed; motors stopped", sensorWait:true, timeout:8)
                }
                return Self.steer(angle:remaining,lane:lane,avoiding:true,previousAction:previousAction,forwardOpen:forwardOpen,yawRate:yawRate)
            }
        }
        if goalOpen, let lane = goalLane {
            preferredSide = nil
            // The lane certifies clearance; its 15° center is not the actual target bearing.
            return Self.steer(angle:angle,lane:lane,avoiding:false,previousAction:previousAction,forwardOpen:forwardOpen,yawRate:yawRate)
        }
        let candidates = scan.lanes.filter { lane in
            lane.isOpen && abs(lane.angle-angle) < .pi/2 &&
            (preferredSide.map { lane.angle*$0 >= -0.05 } ?? true)
        }
        func score(_ lane: AvoidanceLane) -> Float {
            abs(lane.angle-angle)+0.12*abs(lane.angle)-0.08*min(lane.corridor.observedFreeDistance,1.4)
        }
        guard let chosen = candidates.min(by: {
            let a = score($0), b = score($1)
            if abs(a-b) < 0.0001 { return $0.angle < $1.angle }
            return a < b
        }) else {
            if let first = fallbackCorridor.firstObservedFloorDistance, first >= 0.4,
               fallbackCorridor.observedFreeDistance < 0.65 {
                return stop(String(format:"Stop · floor visible only from %.2f m; tilt camera farther down",first))
            }
            let hasObstacle = scan.lanes.contains { $0.corridor.nearestObstacle != nil }
            return stop(hasObstacle ? "Wait · routes blocked or unobserved; motors stopped" :
                "Wait · routes not observed; camera cannot confirm clearance", sensorWait:true, timeout:8)
        }
        if abs(chosen.angle) > 0.05 { preferredSide = chosen.angle > 0 ? 1 : -1 }
        let direction = SIMD2(sin(yaw+chosen.angle),-cos(yaw+chosen.angle))
        detour = Detour(waypoint:position+direction*0.6,origin:position,started:now)
        clearFrames = 0; lastClearFrame = frameTime
        return Self.steer(angle:chosen.angle,lane:chosen,avoiding:true,previousAction:previousAction,forwardOpen:forwardOpen,yawRate:yawRate)
    }
    private static func steer(angle: Float, lane: AvoidanceLane, avoiding: Bool, previousAction: String?, forwardOpen: Bool, yawRate: Float) -> ApproachDecision {
        let turning = (previousAction == "left" && angle < 0) || (previousAction == "right" && angle > 0)
        let degrees = angle*180/Float.pi
        // Account for a short actuation/observation lag when already rotating toward alignment.
        let settleAngle = min(Float(0.25),max(Float(0.10),abs(yawRate)*0.15))
        if abs(angle) > (turning ? settleAngle : 0.22) || (!forwardOpen && abs(angle) > 0.02) {
            let side = angle > 0 ? "right" : "left"
            let text = String(format:"%@turn %@ %.0f°",avoiding ? "Avoid obstacle · " : "",side,abs(degrees))
            // Slow pivots, taper near alignment, and damp rotation already toward the target.
            let toward = max(0,yawRate*(angle > 0 ? 1 : -1))
            let raw = max(35,min(55,35+abs(degrees)*0.4-toward*8))
            let speed = Int((raw/5).rounded())*5
            return ApproachDecision(action:angle > 0 ? "right" : "left",speed:speed,message:text,
                turnDegrees:degrees,selectedLaneDegrees:lane.angle*180/Float.pi,avoiding:avoiding)
        }
        guard forwardOpen else { return ApproachDecision(message:"Stop · current forward lane is not clear") }
        // Gentle PD heading correction while progressing, instead of repeated full-power pivots.
        // Positive error means turn right: slow the right wheel. Never boost above the cap.
        let trim = Int((max(-25,min(25,angle*100-yawRate*8))/5).rounded())*5
        return ApproachDecision(leftPercent:100-max(0,-trim),rightPercent:100-max(0,trim),action:"forward",speed:100,
            message:avoiding ? "Detour forward · rechecking clearance" : "Forward · path toward player clear",
            turnDegrees:0,selectedLaneDegrees:lane.angle*180/Float.pi,avoiding:avoiding)
    }
}


// Camera data must be dated at capture, so queue/processing delay counts toward freshness.
enum DepthFrameTiming {
    static func captureDate(frameUptime: TimeInterval, nowUptime: TimeInterval, now: Date) -> Date? {
        let age = nowUptime-frameUptime
        guard age.isFinite, age >= 0, age <= 0.15 else { return nil }
        return now.addingTimeInterval(-age)
    }
}
