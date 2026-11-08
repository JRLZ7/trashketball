import Foundation
import simd

func decision(for action: String) -> ApproachDecision {
    let angle: Float = action == "left" ? -.pi/4 : action == "right" ? .pi/4 : 0
    let scan = action == "stop" ? AvoidanceScan() : AvoidanceScan(lanes:[AvoidanceLane(angle:angle,corridor:CorridorEstimate(observedFreeDistance:1.4))])
    var navigator = LocalAvoidanceNavigator()
    return navigator.evaluate(distance:3,angle:0,uwbAge:0.01,connected:true,depthAge:0.01,
        trackingNormal:true,floorReady:true,scan:scan,fallbackCorridor:CorridorEstimate(),
        yaw:0,position:.zero,world:UUID(),frameTime:0,now:0,targetMeters:1,previousAction:nil,driving:false)
}
let actions = ["forward","left","right","stop"]
let commands = actions.enumerated().map { index, action -> MotionCommand in
    let d = decision(for:action)
    assert(d.action == action)
    if action == "stop" { assert(d.speed == 0) }
    else if action == "forward" { assert(d.speed == 100) }
    else { assert((35...55).contains(d.speed)) }
    var command = MotionCommand(decision:d,clientID:"robot-guidance-swift-fixture",target:1)
    command.sequence = index+1
    return command
}
print(String(data:try JSONEncoder().encode(commands),encoding:.utf8)!)
