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
