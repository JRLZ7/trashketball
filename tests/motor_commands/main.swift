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
    assert(action == "stop" ? d.speed == 0 : d.speed == 100)
    return MotionCommand(client_id:"robot-guidance-swift-fixture",sequence:index+1,sent_at:0,action:d.action,targetMeters:1,speed:d.speed)
}
print(String(data:try JSONEncoder().encode(commands),encoding:.utf8)!)
