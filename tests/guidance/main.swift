import Foundation

let encoder = JSONEncoder(), decoder = JSONDecoder()
for action in [GuidanceRequest.Action.preview, .start, .stop, .endPreview] {
    let request = GuidanceRequest(action:action,target:2,sentAt:100)
    let restored = try decoder.decode(GuidanceRequest.self,from:encoder.encode(request))
    assert(restored.id == request.id && restored.action == action && restored.target == 2)
    assert(restored.isValid(at:100.5))
    assert(restored.isValid(at:110) == (action == .stop), "Delayed Start must never cause surprise movement; Stop always accepted")
}
assert(!GuidanceRequest(action:.start,target:9,sentAt:100).isValid(at:100))
assert(!GuidanceRequest(action:.start,target:2,sentAt:Double.nan).isValid(at:100))
var hold = GuidanceSensorHold()
hold.pause(at:10)
assert(!hold.ready(depth:9.9,uwb:10.1), "Pre-pause depth cannot authorize recovery")
assert(!hold.ready(depth:10.1,uwb:9.9), "Pre-pause UWB cannot authorize recovery")
assert(!hold.ready(depth:10.1,uwb:10.1))
for _ in 0..<10 { assert(!hold.ready(depth:10.1,uwb:10.1), "Re-evaluating one frame is not recovery") }
assert(!hold.ready(depth:10.2,uwb:10.1), "Repeated UWB update cannot authorize recovery")
assert(!hold.ready(depth:10.2,uwb:10.2))
assert(hold.ready(depth:10.3,uwb:10.3))
hold.pause(at:11)
assert(!hold.ready(depth:11.1,uwb:11.1), "New gap clears stability")
assert(hold.expired(at:12), "Repeated gaps must not extend the two-second deadline")
hold.reset()
assert(hold.began == nil && !hold.expired(at:20))
assert(!hold.ready(depth:20,uwb:20), "Stop clears recovery state")
let decision = ApproachDecision(recoverableSensorWait:true,message:"Stop · waiting for LiDAR")
let state = GuidanceStatus(sequence:42,requestID:UUID(),previewing:true,active:true,paused:true,target:2,
    decision:decision,note:"Paused · waiting for stable readings",canPreview:true,canStart:false,floor:"Confirmed")
let restored = try decoder.decode(GuidanceStatus.self,from:encoder.encode(state))
assert(restored.sequence == 42 && restored.active && restored.decision == decision && restored.note == state.note)
assert(restored.requestID == state.requestID && restored.floor == "Confirmed")
print("Guidance protocol: request/ack/status round trips, delayed Start rejection, unconditional Stop and bounded stable sensor recovery passed")

let command = MotionCommand(client_id:"can",sequence:1,sent_at:100,action:"forward",targetMeters:2,speed:100)
var reply = PiReply(drive:DriveStatus(enabled:true,state:"manual",message:"Moving",summonReady:true,
    left:100,right:100,commandID:command.id),error:nil,beam:nil)
assert(GuidancePiConfirmation.movement(command,reply:reply,httpCode:200,failed:false,now:100.1))
assert(!GuidancePiConfirmation.movement(command,reply:reply,httpCode:200,failed:false,now:100.3), "Late reply cannot revive a watchdog-expired command")
assert(!GuidancePiConfirmation.movement(command,reply:reply,httpCode:500,failed:false,now:100.1))
reply.drive?.commandID = "another-command"
assert(!GuidancePiConfirmation.movement(command,reply:reply,httpCode:200,failed:false,now:100.1))
reply.drive = DriveStatus(enabled:true,state:"stopped",message:"Stopped",summonReady:true,left:0,right:0,commandID:nil)
assert(GuidancePiConfirmation.stopped(reply:reply,httpCode:200,failed:false))
reply.error = "rejected"
assert(!GuidancePiConfirmation.stopped(reply:reply,httpCode:200,failed:false), "Recovery needs an accepted Stop, not just a zero-looking reply")
reply.error = nil; reply.drive?.left = 100
assert(!GuidancePiConfirmation.stopped(reply:reply,httpCode:200,failed:false))
print("Pi confirmation: matching live command, latency, HTTP errors and confirmed zero-output Stop checks passed")
