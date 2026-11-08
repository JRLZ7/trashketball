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
assert(guidance().action == "forward" && guidance().speed == 50)
assert(guidance(angle: 0.5).action == "right" && guidance(angle: -0.5).action == "left")
assert(guidance(angle: 0.5).speed == 45)
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
func syntheticFloor(height: Float, pitch: Float, floorY: Float = -0.25) -> (samples:[DepthSample], camera:simd_float4x4) {
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
    for y in stride(from:0,to:186,by:2) {
        for x in stride(from:0,to:250,by:2) {
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
