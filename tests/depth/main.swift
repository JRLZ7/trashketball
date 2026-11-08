import Foundation
import simd

let origin = SIMD3<Float>(0,0.8,0)
let forward = SIMD3<Float>(0,0,-1)
func floorSamples() -> [DepthSample] {
    var samples: [DepthSample] = []
    for row in 0..<12 {
        for col in -2...2 {
            samples.append(DepthSample(world: SIMD3(Float(col)*0.12,0,-(0.2+Float(row)*0.25)), confidence: 2))
        }
    }
    return samples
}
func estimate(_ points: [DepthSample]) -> CorridorEstimate {
    DepthGeometry.estimate(samples: points, origin: origin, forward: forward, floorY: 0, width: 0.66)
}
let empty = estimate([])
assert(empty.nearestObstacle == nil && empty.observedFreeDistance == 0 && empty.message.hasPrefix("Unknown"))
let floor = floorSamples()
let clear = estimate(floor)
assert(clear.nearestObstacle == nil && clear.observedFreeDistance >= 2.9, "Floor is not an obstacle")
let box = (0..<4).map { DepthSample(world: SIMD3<Float>(Float($0)*0.005,0.25,-1.2), confidence: 2) }
let blocked = estimate(floor+box)
assert(abs(blocked.nearestObstacle!-1.2) < 0.01, "Metric obstacle distance")
let offSide = box.map { DepthSample(world: $0.world+SIMD3<Float>(1,0,0), confidence: 2) }
assert(estimate(floor+offSide).nearestObstacle == nil, "Outside footprint does not obstruct corridor")
let lowConfidence = box.map { DepthSample(world: $0.world, confidence: 0) }
assert(estimate(floor+lowConfidence).nearestObstacle == nil, "Low-confidence points ignored")
assert(estimate(box).observedFreeDistance == 0, "No visible floor is not free space")
let noise = [DepthSample(world: SIMD3<Float>(0,0.2,-0.8), confidence: 2)]
assert(estimate(floor+noise).nearestObstacle == nil, "One isolated return does not become obstacle")
let rotated = floor.map { DepthSample(world: SIMD3(-$0.world.z,$0.world.y,$0.world.x), confidence: $0.confidence) }
let rotatedResult = DepthGeometry.estimate(samples: rotated, origin: origin, forward: SIMD3<Float>(1,0,0), floorY: 0, width: 0.66)
assert(rotatedResult.nearestObstacle == nil && rotatedResult.observedFreeDistance >= 2.9)
print("Depth geometry: floor, box, footprint, confidence, unknown space and heading checks passed")

var reference = FloorReference()
let measured = FloorCandidate(y: -1.05, source: "test measured floor")
assert(reference.update(candidate: measured, trackingNormal: false, timestamp: 0) == nil)
assert(reference.update(candidate: measured, trackingNormal: true, timestamp: 0.2) == nil)
assert(reference.update(candidate: measured, trackingNormal: true, timestamp: 0.4) == nil)
assert(abs(reference.update(candidate: measured, trackingNormal: true, timestamp: 0.6)! + 1.05) < 0.001)
assert(reference.update(candidate: nil, trackingNormal: true, timestamp: 0.8) != nil, "Brief dropout retained")
assert(reference.update(candidate: nil, trackingNormal: true, timestamp: 2) == nil, "Unconfirmed floor expires")
assert(reference.update(candidate: FloorCandidate(y: -0.5,source: "box top"), trackingNormal: true, timestamp: 2.2) == nil, "Do not move the floor onto a box")
reference.reset()
assert(reference.y == nil)
assert(abs(AssumedRobotDimensions.width + 2*AssumedRobotDimensions.sideClearance - 0.46) < 0.001)
print("Measured floor reference: stability, tracking, expiry, elevated surfaces and resets passed")

func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { simd_distance(a,b) < 0.001 }
let camera = matrix_identity_float4x4
let frontTarget = PlayerMapGeometry.target(distance: 2, horizontalAngle: 0, direction: nil, camera: camera, timestamp: 10)!
assert(near(frontTarget.position,SIMD2(0,-2)) && frontTarget.approximate)
let rightTarget = PlayerMapGeometry.target(distance: 2, horizontalAngle: .pi/2, direction: nil, camera: camera, timestamp: 10)!
assert(near(rightTarget.position,SIMD2(2,0)), "Positive bearing must be camera-right")
var movedCamera = matrix_identity_float4x4
movedCamera.columns.3 = SIMD4(1,0.44,2,1)
// Rear camera faces world +X after a right turn.
movedCamera.columns.0 = SIMD4(0,0,1,0)
movedCamera.columns.2 = SIMD4(-1,0,0,0)
let movedTarget = PlayerMapGeometry.target(distance: 2, horizontalAngle: 0, direction: nil, camera: movedCamera, timestamp: 11)!
assert(near(movedTarget.position,SIMD2(3,2)), "Apply translation and world heading")
let fullDirection = PlayerMapGeometry.target(distance: 2, horizontalAngle: 1, direction: SIMD3(0,0.6,-0.8), camera: movedCamera, timestamp: 11)!
assert(near(fullDirection.position,SIMD2(2.6,2)) && !fullDirection.approximate, "3D direction handles vertical separation")
assert(PlayerMapGeometry.target(distance: 2, horizontalAngle: nil, direction: nil, camera: camera, timestamp: 0) == nil)
assert(PlayerMapGeometry.target(distance: .nan, horizontalAngle: 0, direction: nil, camera: camera, timestamp: 0) == nil)
assert(PlayerMapGeometry.target(distance: 2, horizontalAngle: .infinity, direction: nil, camera: camera, timestamp: 0) == nil)
var map = LocalDepthMap()
map.update(samples: floor+box+lowConfidence, floorY: 0, origin: .zero, now: 10)
assert(map.cells.values.contains { $0.obstacle })
assert(map.cells.values.contains { !$0.obstacle })
let occupied = map.cells.values.first { $0.obstacle }!
map.update(samples: [DepthSample(world: SIMD3(occupied.center.x,0,occupied.center.y), confidence: 2)], floorY: 0, origin: .zero, now: 11)
assert(map.cells[occupied.key]?.obstacle == true, "A floor return cannot erase an obstacle")
map.update(samples: [], floorY: 0, origin: .zero, now: 16)
assert(map.cells.isEmpty, "Old observations must expire into unknown")
map.update(samples: box, floorY: 0, origin: .zero, now: 17)
map.update(samples: [], floorY: 0, origin: SIMD2(20,20), now: 18)
assert(map.cells.isEmpty, "Map memory bounded to nearby cells")
map.update(samples: noise, floorY: 0, origin: .zero, now: 19)
assert(map.cells.isEmpty, "Isolated obstacle noise ignored")
map.update(samples: box, floorY: 0, origin: .zero, now: 20)
map.reset(); assert(map.cells.isEmpty)
print("Local map: UWB frame conversion, height projection, invalid readings, occupancy, expiry and resets passed")

assert(frontTarget.isFresh(at: 10.5))
assert(!frontTarget.isFresh(at: 11.1) && !frontTarget.isFresh(at: 9), "Stale and future targets hidden")

func guidance(distance: Float? = 3, angle: Float? = 0, age: Double? = 0.01, connected: Bool = true,
              depthAge: Double = 0.01, normal: Bool = true, floorReady: Bool = true,
              corridor: CorridorEstimate = CorridorEstimate(observedFreeDistance: 1), previous: String? = nil) -> ApproachDecision {
    GuidedApproach.evaluate(distance: distance, angle: angle, uwbAge: age, connected: connected,
        depthAge: depthAge, trackingNormal: normal, floorReady: floorReady, corridor: corridor,
        targetMeters: 1, previousAction: previous)
}
assert(guidance().action == "forward" && guidance().speed == 100)
assert(guidance(angle: 0.5).action == "right" && guidance(angle: -0.5).action == "left")
assert(guidance(angle: 0.5).speed == 100)
assert(guidance(angle: 0.15, previous: "right").action == "right", "Turn hysteresis")
assert(guidance(angle: 0.05, previous: "right").action == "forward")
assert(guidance(angle: 0.15, previous: "forward").action == "forward")
assert(guidance(distance: 1.1).action == "stop" && guidance(distance: 1.1).message.hasPrefix("Arrived"))
assert(guidance(age: 0.25).action == "stop" && guidance(age: -0.1).action == "stop")
assert(guidance(angle: nil).action == "stop" && guidance(distance: nil).action == "stop")
assert(guidance(angle: .nan).action == "stop" && guidance(distance: .infinity).action == "stop")
assert(guidance(connected: false).action == "stop")
assert(guidance(depthAge: 0.4).action == "stop" && guidance(normal: false).action == "stop")
assert(guidance(floorReady: false).action == "stop")
assert(guidance(corridor: CorridorEstimate(nearestObstacle: 0.5, observedFreeDistance: 1)).action == "stop")
assert(guidance(angle: 0.5, corridor: CorridorEstimate(nearestObstacle: 0.5, observedFreeDistance: 1)).action == "stop", "Block turns too when a forward obstacle is close")
assert(guidance(corridor: CorridorEstimate()).action == "stop", "Unknown floor must stop")
assert(guidance(corridor: CorridorEstimate(observedFreeDistance: .nan)).action == "stop")
print("Guided approach: direct bearing, speed caps, hysteresis, arrival, stale/invalid sensors and obstruction checks passed")

// Reproduce real capture geometry, including different lens heights and downward tilt.
func syntheticFloor(height: Float, pitch: Float, floorY: Float = -0.25, pixelStride: Int = 2) -> (samples:[DepthSample], camera:simd_float4x4) {
    var pose = matrix_identity_float4x4
    let c = cos(pitch), s = sin(pitch)
    pose.columns.1 = SIMD4(0,c,-s,0)
    pose.columns.2 = SIMD4(0,s,c,0)
    pose.columns.3 = SIMD4(0,floorY+height,0,1)
    func point(_ x: Int, _ y: Int) -> SIMD3<Float>? {
        let ray = pose*SIMD4((Float(x)-128)/120,-(Float(y)-96)/120,-1,0)
        guard ray.y < -0.01 else { return nil }
        let depth = -height/ray.y
        guard depth >= 0.15, depth <= 5 else { return nil }
        return DepthProjection.worldPoint(x:Float(x),y:Float(y),depth:depth,fx:120,fy:120,cx:128,cy:96,camera:pose)
    }
    var points: [DepthSample] = []
    for y in stride(from:0,to:186,by:pixelStride) {
        for x in stride(from:0,to:250,by:pixelStride) {
            guard let a = point(x,y), let b = point(x+6,y), let c = point(x,y+6) else { continue }
            assert(abs(a.y-floorY) < 0.001, "Depth unprojection must keep a tilted floor horizontal")
            points.append(DepthSample(world:a,confidence:2,horizontal:DepthProjection.horizontal(a,b,c)))
        }
    }
    return (points,pose)
}
for height: Float in [0.44,0.8,1.3] {
    let scene = syntheticFloor(height:height,pitch:0.5)
    let origin = SIMD3(scene.camera.columns.3.x,scene.camera.columns.3.y,scene.camera.columns.3.z)
    let detected = DepthFloorDetection.candidate(samples:scene.samples,origin:origin)!
    assert(abs(detected.y + 0.25) < 0.01, "Detect actual floor regardless of the 44 cm bucket height")
    let result = DepthGeometry.estimate(samples:scene.samples,origin:origin,forward:SIMD3(0,0,-1),floorY:detected.y,width:0.46)
    assert(result.nearestObstacle == nil, "Real floor must not become layers of false obstacles")
    if height == 0.44 { assert(result.observedFreeDistance >= 0.65, "Mounted, downward-facing camera should pass clear-floor check") }
    var floorMap = LocalDepthMap()
    floorMap.update(samples:scene.samples,floorY:detected.y,origin:.zero,now:0)
    assert(floorMap.cells.count > 50 && floorMap.cells.values.allSatisfy { !$0.obstacle }, "Broad floor should create green map cells without false obstacle layers")
}
let horizontalSurface = (0..<12).flatMap { x in (0..<12).map { z in
    DepthSample(world:SIMD3(Float(x)*0.08,Float(0),-0.4-Float(z)*0.08),confidence:2,horizontal:true)
} }
assert(DepthFloorDetection.candidate(samples:horizontalSurface,origin:SIMD3(0,0.9,0)) != nil)
let wall = horizontalSurface.map { DepthSample(world:SIMD3($0.world.x,-$0.world.z,-1),confidence:2,horizontal:false) }
assert(DepthFloorDetection.candidate(samples:wall,origin:SIMD3(0,1.5,0)) == nil, "A height stripe on a wall is not a floor")
let smallBoxTop = horizontalSurface.map { DepthSample(world:SIMD3($0.world.x*0.2,0.3,$0.world.z*0.2),confidence:2,horizontal:true) }
assert(DepthFloorDetection.candidate(samples:smallBoxTop,origin:SIMD3(0,0.9,0)) == nil, "Small box tops cannot initialize the floor")
assert(DepthFloorDetection.candidate(samples:[],origin:SIMD3(0,0.9,0)) == nil)
let farFloor = floor.filter { -$0.world.z > 0.7 }
let unseenNear = estimate(farFloor)
assert(unseenNear.observedFreeDistance == 0 && unseenNear.firstObservedFloorDistance! >= 0.4, "Distant floor must not fill in the blind near band")
assert(guidance(corridor:unseenNear).message.contains("tilt camera"))
print("Capture regressions: varied camera height/pitch, dense green floor map, wall/box rejection and near-floor blind-zone diagnosis passed")
let actualScene = syntheticFloor(height:0.8,pitch:0.7)
let actualOrigin = SIMD3<Float>(0,0.55,0)
let actualFloor = DepthFloorDetection.candidate(samples:actualScene.samples,origin:actualOrigin)!
let actualBox = (0..<4).map { DepthSample(world:SIMD3<Float>(Float($0)*0.005,0.05,-0.5),confidence:2) }
let actualBlocked = DepthGeometry.estimate(samples:actualScene.samples+actualBox,origin:actualOrigin,forward:SIMD3(0,0,-1),floorY:actualFloor.y,width:0.46)
assert(abs(actualBlocked.nearestObstacle!-0.5) < 0.001)
assert(guidance(corridor:actualBlocked).action == "stop", "Correcting floor must not turn a real box green")
print("Measured-floor obstacle preservation passed")


var mountedReference = FloorReference()
mountedReference.initializeFromMount(cameraY:0,trackingNormal:false,timestamp:0)
assert(mountedReference.y == nil)
mountedReference.initializeFromMount(cameraY:0,trackingNormal:true,timestamp:0.2)
assert(abs(mountedReference.y! + 0.25) < 0.001)
mountedReference.initializeFromMount(cameraY:0.3,trackingNormal:true,timestamp:0.4)
assert(abs(mountedReference.y! + 0.25) < 0.001, "Camera movement must not move the floor reference")
assert(mountedReference.update(candidate:nil,trackingNormal:true,timestamp:1.5) == nil, "Mount seed expires without observed confirmation")
let confirmedMount = FloorCandidate(y:-0.27,source:"test floor")
for time in [1.6,1.8,2.0] { _ = mountedReference.update(candidate:confirmedMount,trackingNormal:true,timestamp:time) }
assert(mountedReference.isReliable(at:2.0) && mountedReference.source == "test floor")
mountedReference.reset()
mountedReference.initializeFromMount(cameraY:0.1,trackingNormal:true,timestamp:3)
assert(abs(mountedReference.y! + 0.15) < 0.001)
let lowMountedScene = syntheticFloor(height:0.25,pitch:0.3)
let lowOrigin = SIMD3<Float>(0,0,0)
let lowCandidate = DepthFloorDetection.candidate(samples:lowMountedScene.samples,origin:lowOrigin)!
let lowEstimate = DepthGeometry.estimate(samples:lowMountedScene.samples,origin:lowOrigin,forward:SIMD3(0,0,-1),floorY:lowCandidate.y,width:0.46)
assert(lowEstimate.nearestObstacle == nil && lowEstimate.observedFreeDistance >= 0.65)
print("25 cm mount: initialization, fixed world floor, expiry, confirmation, reset and downward-view floor checks passed")

var arena: [DepthSample] = []
for x in stride(from:Float(-2),through:2,by:0.05) {
    for z in stride(from:Float(-2),through:0.5,by:0.05) {
        arena.append(DepthSample(world:SIMD3(x,0,z),confidence:2))
    }
}
let arenaOrigin = SIMD3<Float>(0,0.25,0)
let centerBox = (-4...4).flatMap { x in (0..<4).map { j in
    DepthSample(world:SIMD3(Float(x)*0.025,0.2,-0.6-Float(j)*0.005),confidence:2)
} }
let openScan = AvoidanceGeometry.scan(samples:arena,origin:arenaOrigin,forward:SIMD3(0,0,-1),floorY:0)
let boxScan = AvoidanceGeometry.scan(samples:arena+centerBox,origin:arenaOrigin,forward:SIMD3(0,0,-1),floorY:0)
assert(openScan.lanes.count == 9 && openScan.lanes.allSatisfy(\.isOpen))
assert(boxScan.nearestLane(to:0)?.isOpen == false)
assert(boxScan.lanes.contains { $0.angle < 0 && $0.isOpen } && boxScan.lanes.contains { $0.angle > 0 && $0.isOpen })
let navWorld = UUID()
func navigation(_ navigator: inout LocalAvoidanceNavigator, scan: AvoidanceScan, angle:Float? = 0,
                yaw:Float = 0, position:SIMD2<Float> = .zero, time:Double = 0, age:Double = 0.01,
                depthAge:Double = 0.01, world:UUID = navWorld, driving:Bool = false,
                previous:String? = nil, distance:Float? = 3, connected:Bool = true, normal:Bool = true, ready:Bool = true) -> ApproachDecision {
    navigator.evaluate(distance:distance,angle:angle,uwbAge:age,connected:connected,depthAge:depthAge,
        trackingNormal:normal,floorReady:ready,scan:scan,fallbackCorridor:CorridorEstimate(),
        yaw:yaw,position:position,world:world,frameTime:time,now:time,targetMeters:1,
        previousAction:previous,driving:driving)
}
var navigator = LocalAvoidanceNavigator()
assert(navigation(&navigator,scan:openScan).action == "forward")
navigator.reset()
let detourChoice = navigation(&navigator,scan:boxScan)
assert(detourChoice.avoiding && detourChoice.action == "left" && detourChoice.turnDegrees! < 0)
assert(abs(detourChoice.turnDegrees!) >= 30, "Report a useful turn angle, not just blocked")
let chosenYaw = detourChoice.turnDegrees!*Float.pi/180
let chosenForward = SIMD3<Float>(sin(chosenYaw),0,-cos(chosenYaw))
let turnedScan = AvoidanceGeometry.scan(samples:arena+centerBox,origin:arenaOrigin,forward:chosenForward,floorY:0)
let afterTurn = navigation(&navigator,scan:turnedScan,angle:-chosenYaw,yaw:chosenYaw,time:0.2,previous:"left")
assert(afterTurn.action == "forward" && afterTurn.avoiding && afterTurn.turnDegrees == 0, "Use measured yaw to complete the requested turn")
assert(navigation(&navigator,scan:turnedScan,angle:-chosenYaw,yaw:chosenYaw,time:8.1,driving:true).action == "stop", "Bound an active detour's duration")
navigator.reset()
var onlyRight = boxScan
onlyRight.lanes = onlyRight.lanes.map { lane in
    lane.angle < 0 ? AvoidanceLane(angle:lane.angle,corridor:CorridorEstimate()) : lane
}
assert(navigation(&navigator,scan:onlyRight).action == "right", "Choose the observed open side")
navigator.reset()
var onlyLeft = boxScan
onlyLeft.lanes = onlyLeft.lanes.map { lane in
    lane.angle > 0 ? AvoidanceLane(angle:lane.angle,corridor:CorridorEstimate()) : lane
}
assert(navigation(&navigator,scan:onlyLeft).action == "left")
assert(navigation(&navigator,scan:onlyRight,time:0.2).action == "stop", "Do not flip sides if a committed detour becomes unobserved")
navigator.reset()
let unknownScan = AvoidanceGeometry.scan(samples:[],origin:arenaOrigin,forward:SIMD3(0,0,-1),floorY:0)
assert(navigation(&navigator,scan:unknownScan).action == "stop", "Unknown sides cannot be chosen")
navigator.reset()
var tooClose = openScan; tooClose.nearestRadialObstacle = 0.3
assert(navigation(&navigator,scan:tooClose).action == "forward", "A side object at 30 cm is no longer an instant emergency stop")
navigator.reset()
assert(navigation(&navigator,scan:openScan,age:0.3).action == "stop")
assert(navigation(&navigator,scan:openScan,depthAge:0.5).action == "stop")
assert(navigation(&navigator,scan:openScan,distance:1.1).message.hasPrefix("Arrived"))
navigator.reset()
_ = navigation(&navigator,scan:boxScan)
assert(navigation(&navigator,scan:boxScan,time:0.2,world:UUID()).message.contains("AR session changed"))
navigator.reset()
_ = navigation(&navigator,scan:boxScan)
let blockedWhileTurning = navigation(&navigator,scan:unknownScan,time:0.2)
assert(blockedWhileTurning.action == "stop")
print("Local avoidance: fan geometry, inflated lanes, side choice, measured turn completion, unknown/blocked paths, freshness, arrival, timeout and AR resets passed")

// Rejoin only after progress and three distinct clear depth frames, not three timer ticks.
navigator.reset()
let rejoinChoice = navigation(&navigator,scan:boxScan)
let rejoinYaw = rejoinChoice.turnDegrees!*Float.pi/180
let progress = SIMD2<Float>(sin(rejoinYaw),-cos(rejoinYaw))*0.36
for time in [0.2,0.2,0.4] {
    let step = navigation(&navigator,scan:openScan,angle:-rejoinYaw,yaw:rejoinYaw,position:progress,time:time)
    assert(step.avoiding, "Repeated timer tick cannot count as another clear sensor frame")
}
let rejoined = navigation(&navigator,scan:openScan,angle:-rejoinYaw,yaw:rejoinYaw,position:progress,time:0.6)
assert(!rejoined.avoiding && rejoined.action != "stop", "Rejoin player after consistent clear observations")
navigator.reset()
let radialWall = stride(from:Float(-80),through:80,by:2).flatMap { deg in (0..<4).map { n in
    let a = deg*Float.pi/180
    return DepthSample(world:SIMD3(sin(a)*0.6,0.2,-cos(a)*0.6-Float(n)*0.001),confidence:2)
} }
let enclosed = AvoidanceGeometry.scan(samples:arena+radialWall,origin:arenaOrigin,forward:SIMD3(0,0,-1),floorY:0)
assert(enclosed.lanes.allSatisfy { !$0.isOpen })
assert(navigation(&navigator,scan:enclosed).action == "stop", "No escape lane must stop")
print("Detour rejoin frame counting and enclosed-path checks passed")

// End-to-end kinematic exercise: turn, pass a box, rejoin, and stop at the player.
var simulatedFloor: [DepthSample] = []
for x in stride(from:Float(-2),through:2,by:0.075) {
    for z in stride(from:Float(-4),through:0.5,by:0.075) {
        simulatedFloor.append(DepthSample(world:SIMD3(x,0,z),confidence:2))
    }
}
var simulation = LocalAvoidanceNavigator()
var simPosition = SIMD2<Float>.zero, simYaw: Float = 0
var simScan = AvoidanceScan(), simPose = simPosition, simFrameYaw = simYaw
var simFrameTime: Double = 0
var simPrevious: String?
var arrived = false, sawDetour = false
for step in 0..<500 {
    let time = Double(step)*0.1
    if step % 2 == 0 {
        simPose = simPosition; simFrameYaw = simYaw; simFrameTime = time
        simScan = AvoidanceGeometry.scan(samples:simulatedFloor+centerBox,origin:SIMD3(simPosition.x,0.25,simPosition.y),
            forward:SIMD3(sin(simYaw),0,-cos(simYaw)),floorY:0,target:simulation.waypoint)
    }
    let delta = SIMD2<Float>(0,-3)-simPosition
    let f = SIMD2<Float>(sin(simYaw),-cos(simYaw)), r = SIMD2<Float>(cos(simYaw),sin(simYaw))
    let bearing = atan2(simd_dot(delta,r),simd_dot(delta,f))
    let decision = simulation.evaluate(distance:simd_length(delta),angle:bearing,uwbAge:0.01,connected:true,
        depthAge:time-simFrameTime+0.01,trackingNormal:true,floorReady:true,scan:simScan,fallbackCorridor:CorridorEstimate(),
        yaw:simFrameYaw,position:simPose,world:navWorld,frameTime:simFrameTime,now:time,targetMeters:1,
        previousAction:simPrevious,driving:true)
    if decision.message.hasPrefix("Arrived") { arrived = true; break }
    assert(decision.action != "stop", "Unexpected simulated stop: \(decision.message), step \(step)")
    sawDetour = sawDetour || decision.avoiding
    if decision.action == "left" { simYaw -= 0.09 }
    if decision.action == "right" { simYaw += 0.09 }
    if decision.action == "forward" { simPosition += SIMD2(sin(simYaw),-cos(simYaw))*0.02 }
    for point in centerBox {
        assert(simd_distance(simPosition,SIMD2(point.world.x,point.world.z)) > 0.23, "Simulated footprint hits obstacle")
    }
    simPrevious = decision.action
}
assert(arrived && sawDetour, "Must avoid box and reach the selected player distance")
print("Kinematic box-avoidance-to-player simulation passed (synthetic geometry, not hardware validation)")


navigator.reset()
let overshootChoice = navigation(&navigator,scan:boxScan)
let overshootYaw = overshootChoice.turnDegrees!*Float.pi/180-0.12
assert(navigation(&navigator,scan:openScan,angle:-overshootYaw,yaw:overshootYaw,time:0.2,previous:"left").action == "forward", "Small overshoot must not cause left/right oscillation when forward is observed clear")
navigator.reset()
let smallTurnChoice = navigation(&navigator,scan:boxScan)
let smallTurnYaw = smallTurnChoice.turnDegrees!*Float.pi/180-0.08
let blockedStraight = AvoidanceScan(lanes:[AvoidanceLane(angle:0,corridor:CorridorEstimate(nearestObstacle:0.5)),AvoidanceLane(angle:0.08,corridor:CorridorEstimate(observedFreeDistance:1.4))])
assert(navigation(&navigator,scan:blockedStraight,angle:-smallTurnYaw,yaw:smallTurnYaw,time:0.2,previous:"right").action == "right", "Finish a small turn rather than driving along a still-blocked straight lane")
navigator.reset()
assert(navigation(&navigator,scan:openScan,angle:nil).action == "stop")
assert(navigation(&navigator,scan:openScan,distance:nil).action == "stop")
assert(navigation(&navigator,scan:openScan,angle:.nan).action == "stop")
assert(navigation(&navigator,scan:openScan,connected:false).action == "stop")
assert(navigation(&navigator,scan:openScan,normal:false).action == "stop")
assert(navigation(&navigator,scan:openScan,ready:false).action == "stop")
print("Overshoot, blocked-forward turn completion and missing-input regressions passed")


let mountedOrigin = SIMD3<Float>(0,0.25,0)
let falseLowerAnchor = FloorCandidate(y:-0.8,source:"unrelated floor anchor")
let validatedFloor = DepthFloorDetection.select(samples:horizontalSurface,origin:mountedOrigin,previousY:0,anchor:falseLowerAnchor)!
assert(abs(validatedFloor.y) < 0.001, "An unrelated AR plane must not turn real floor into red/orange obstacles")
assert(DepthFloorDetection.select(samples:wall,origin:mountedOrigin,previousY:0,anchor:FloorCandidate(y:0,source:"anchor")) == nil, "Plane anchors alone cannot confirm unobserved floor")
let recoveredFloor = DepthFloorDetection.select(samples:horizontalSurface,origin:mountedOrigin,previousY:-0.8,anchor:FloorCandidate(y:0,source:"floor"))!
assert(abs(recoveredFloor.y) < 0.001, "Bad prior can recover when supported by real depth")
var extraLevel = horizontalSurface
for _ in 0..<4 { extraLevel += horizontalSurface.map { DepthSample(world:$0.world-SIMD3(0,0.6,0),confidence:2,horizontal:true) } }
assert(abs(DepthFloorDetection.select(samples:extraLevel,origin:mountedOrigin,previousY:0,anchor:falseLowerAnchor)!.y) < 0.001, "Visible lower surfaces cannot replace an already-supported ground reference")
let capture = DepthFrameTiming.captureDate(frameUptime:50,nowUptime:50.12,now:Date(timeIntervalSince1970:1000))!
assert(abs(capture.timeIntervalSince1970-999.88) < 0.001)
assert(DepthFrameTiming.captureDate(frameUptime:50,nowUptime:50.2,now:.now) == nil)
assert(DepthFrameTiming.captureDate(frameUptime:51,nowUptime:50,now:.now) == nil)
assert(Date(timeIntervalSince1970:1000.35).timeIntervalSince(capture) > 0.4, "Queue/processing delay must count toward stale-data gating")
let sparseCloud = syntheticFloor(height:0.25,pitch:0.6,pixelStride:4)
let sparseScan = AvoidanceGeometry.scan(samples:sparseCloud.samples,origin:SIMD3(0,0,0),forward:SIMD3(0,0,-1),floorY:-0.25)
assert(sparseScan.nearestLane(to:0)?.isOpen == true, "Lower-cost guidance sampling must retain visible clear-floor evidence")
print("Floor regression: supported reference preference, bad-anchor rejection, recovery, capture-age timing and lower-cost avoidance sampling passed")


var staleWrongFloor = FloorReference()
for time in [0.0,0.2,0.4] {
    _ = staleWrongFloor.update(candidate:FloorCandidate(y:-0.8,source:"old bad plane"),trackingNormal:true,timestamp:time)
}
let actualGround = FloorCandidate(y:0,source:"depth-confirmed actual floor")
assert(staleWrongFloor.update(candidate:actualGround,trackingNormal:true,timestamp:0.6) == -0.8, "Keep the raised-surface guard while old reference is reliable")
for time in [1.8,2.0,2.2] { _ = staleWrongFloor.update(candidate:actualGround,trackingNormal:true,timestamp:time) }
assert(abs(staleWrongFloor.y!) < 0.001, "An expired wrong plane must not permanently reject the actual higher floor")
print("Expired wrong floor can recover automatically without UWB recalibration")

for decision in [detourChoice,afterTurn,rejoined] {
    assert(decision.speed == 100, "All movement, including pivots, uses 100%")
}

// A bearing near a lane boundary must not become a quantized 15-degree pivot.
navigator.reset()
let slightAngle: Float = 0.14
let slightApproach = navigation(&navigator,scan:openScan,angle:slightAngle)
assert(slightApproach.action == "forward", "An 8-degree player bearing is within forward tolerance even when nearest clearance lane is 15 degrees")
navigator.reset()
let exactApproach = navigation(&navigator,scan:openScan,angle:0.34)
assert(exactApproach.action == "right")
assert(abs(exactApproach.turnDegrees!-0.34*180/Float.pi) < 0.001, "Turn guidance must report the measured bearing rather than the lane center")
navigator.reset()
assert(navigation(&navigator,scan:openScan,angle:nil).recoverableSensorWait)
navigator.reset()
assert(navigation(&navigator,scan:openScan,depthAge:1).recoverableSensorWait)
navigator.reset()
assert(!navigation(&navigator,scan:openScan,distance:1).recoverableSensorWait, "Arrival is final")
navigator.reset()
assert(!navigation(&navigator,scan:AvoidanceScan(lanes:openScan.lanes,nearestRadialObstacle:0.04)).recoverableSensorWait, "A blocked route must not auto-resume")
print("Measured-bearing steering and recoverable sensor-gap classification passed")

// Every valid movement uses full requested output, without hidden per-wheel reductions.
for angle:Float in [-0.9,-0.24,-0.1,0,0.1,0.24,0.9] {
    navigator.reset()
    let decision = navigation(&navigator,scan:openScan,angle:angle)
    assert(decision.action != "stop" && decision.speed == 100)
    assert(decision.leftPercent == nil && decision.rightPercent == nil)
}
navigator.reset()
_ = navigation(&navigator,scan:openScan,angle:0.9,yaw:0,time:0)
let movingPivot = navigation(&navigator,scan:openScan,angle:0.9,yaw:0.4,time:0.2,previous:"right")
assert(movingPivot.speed == 100, "Yaw feedback can end a turn earlier but cannot lower requested power")
navigator.reset()
let unobserved = navigation(&navigator,scan:AvoidanceScan(lanes:openScan.lanes.map { AvoidanceLane(angle:$0.angle,corridor:CorridorEstimate()) }))
assert(unobserved.action == "stop" && unobserved.recoverableSensorWait && unobserved.recoveryTimeout == 8)
assert(unobserved.message.contains("not observed"))
navigator.reset()
let closeObstacle = navigation(&navigator,scan:AvoidanceScan(lanes:openScan.lanes,nearestRadialObstacle:0.04))
assert(closeObstacle.action == "stop" && !closeObstacle.recoverableSensorWait)
print("Full-power forward/pivots, bounded route waits and close-obstacle stops passed")

// Front-hit detection is distinct from a nearby side object.
let frontCluster = (0..<4).map { DepthSample(world:SIMD3(Float($0)*0.002,0.2,-0.25),confidence:2) }
let frontalScan = AvoidanceGeometry.scan(samples:arena+frontCluster,origin:arenaOrigin,forward:SIMD3(0,0,-1),floorY:0)
assert(abs(frontalScan.nearestFrontObstacle!-0.25) < 0.01)
let sideCluster = (0..<4).map { DepthSample(world:SIMD3(0.32,0.2,-0.2-Float($0)*0.001),confidence:2) }
let sideScan = AvoidanceGeometry.scan(samples:arena+sideCluster,origin:arenaOrigin,forward:SIMD3(0,0,-1),floorY:0)
assert(sideScan.nearestFrontObstacle == nil)

var frontBlockedScan = openScan
frontBlockedScan.nearestFrontObstacle = 0.25
frontBlockedScan.nearestRadialObstacle = 0.25
frontBlockedScan.lanes = openScan.lanes.map { abs($0.angle) < 0.1 ? AvoidanceLane(angle:$0.angle,corridor:CorridorEstimate(nearestObstacle:0.25)) : $0 }
navigator.reset()
assert(navigation(&navigator,scan:frontBlockedScan).action == "reverse")
assert(navigation(&navigator,scan:frontBlockedScan,time:100).action == "reverse", "Preview time cannot consume the motor backup budget")
navigator.beginReverseCommand(now:100,position:.zero)
let backing = navigation(&navigator,scan:frontBlockedScan,position:SIMD2(0,0.02),time:100.1,driving:true)
assert(backing.action == "reverse" && backing.speed == 100)
let backedPosition = SIMD2<Float>(0,0.06)
let lookForSide = navigation(&navigator,scan:frontBlockedScan,position:backedPosition,time:100.2,driving:true)
assert(lookForSide.action == "stop" && lookForSide.recoverableSensorWait, "Stop before switching from reverse to a side turn")
let escape = navigation(&navigator,scan:frontBlockedScan,position:backedPosition,time:100.4,driving:true)
assert(escape.avoiding && escape.action == "left" && escape.speed == 100)
let escapeYaw = escape.turnDegrees!*Float.pi/180
let escapeForward = navigation(&navigator,scan:openScan,angle:-escapeYaw,yaw:escapeYaw,position:backedPosition,time:100.8,driving:true,previous:"left")
assert(escapeForward.action == "forward" && escapeForward.avoiding)
let escapeProgress = backedPosition+SIMD2(sin(escapeYaw),-cos(escapeYaw))*0.36
var towardPlayer = escapeForward
for time in [101.0,101.2,101.4] {
    towardPlayer = navigation(&navigator,scan:openScan,angle:-escapeYaw,yaw:escapeYaw,position:escapeProgress,time:time,driving:true)
}
assert(!towardPlayer.avoiding && towardPlayer.action == "right", "After retreat and detour, pursue the original player's live heading")

var noSide = frontBlockedScan
noSide.lanes = noSide.lanes.map { AvoidanceLane(angle:$0.angle,corridor:CorridorEstimate(nearestObstacle:0.25)) }
navigator.reset()
assert(navigation(&navigator,scan:noSide).action == "reverse")
navigator.beginReverseCommand(now:0,position:.zero)
assert(navigation(&navigator,scan:noSide,time:0.61,driving:true).action == "stop", "Reverse is bounded even if the wheels stall")
for time in [0.8,1.0,2.0,8.0,20.0] {
    assert(navigation(&navigator,scan:noSide,time:time,driving:true).action == "stop", "No repeated blind backups while waiting for a side")
}
navigator.reset()
_ = navigation(&navigator,scan:noSide)
navigator.beginReverseCommand(now:0,position:.zero)
assert(navigation(&navigator,scan:noSide,position:SIMD2(0,0.16),time:0.1,driving:true).action == "stop", "AR distance ends a backup before the time limit")
navigator.reset()
_ = navigation(&navigator,scan:noSide)
navigator.beginReverseCommand(now:0,position:.zero)
assert(navigation(&navigator,scan:noSide,time:0.1,depthAge:1,driving:true).action == "stop")
assert(navigation(&navigator,scan:noSide,time:1,driving:true).action == "stop", "A sensor gap cannot restart an expired backup")
navigator.reset()
var emergency = frontBlockedScan; emergency.nearestRadialObstacle = 0.049
let emergencyDecision = navigation(&navigator,scan:emergency)
assert(emergencyDecision.action == "stop" && !emergencyDecision.recoverableSensorWait)
assert(emergencyDecision.message.contains("EMERGENCY STOP") && emergencyDecision.message.contains("5 cm"))
print("Backup recovery: supported front hits, 5 cm emergency, preview/dispatch timing, reverse limits, no repeated blind backup, safe-side selection and return-to-player passed")

navigator.reset()
assert(navigation(&navigator,scan:sideScan).action != "reverse", "A side-only obstacle must not trigger blind backup through the wider lane-inflation heuristic")

navigator.reset()
assert(navigation(&navigator,scan:emergency,angle:nil).message.contains("EMERGENCY STOP"), "Fresh emergency detection outranks missing heading")
navigator.reset()
assert(navigation(&navigator,scan:emergency,distance:1).message.contains("EMERGENCY STOP"), "Emergency reason outranks arrival")
navigator.reset()
assert(!navigation(&navigator,scan:emergency,depthAge:1).message.contains("EMERGENCY STOP"), "Old depth cannot fabricate a fresh 5 cm measurement")
