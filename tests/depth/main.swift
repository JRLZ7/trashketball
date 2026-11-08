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
assert(reference.update(cameraY: 0, trackingNormal: false) == nil)
assert(abs(reference.update(cameraY: 0, trackingNormal: true)! + 0.44) < 0.001)
assert(abs(reference.update(cameraY: 0.2, trackingNormal: true)! + 0.44) < 0.001, "Do not drag the floor along with the camera")
reference.reset()
assert(reference.update(cameraY: 0.2, trackingNormal: false) == nil)
assert(abs(reference.update(cameraY: 0.2, trackingNormal: true)! + 0.24) < 0.001, "Auto-initialize after reset")
assert(abs(AssumedRobotDimensions.width + 2*AssumedRobotDimensions.sideClearance - 0.46) < 0.001)
print("Automatic floor reference: normal tracking, persistence, reset and dimensions passed")

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
