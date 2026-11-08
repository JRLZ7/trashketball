# Pi motor bridge

`pi/server.py` wraps `Firmware/PI/trashketball/drive.py`. Run `python3 pi/server.py` with no flags. Motors, beam scoring and Summon are enabled by default. Edit startup constants at the top of the Python file for wiring/mounting changes: `ENABLE_MOTORS`, `ENABLE_BEAM`, `ENABLE_SUMMON`, `BEARING_SIGN`, `BEARING_OFFSET_DEG`, `INVERT_LEFT`, `INVERT_RIGHT`, `BEAM_ACTIVE_HIGH`. The token is `12345` in both server and app; no environment variable is required.

## HTTP

Trusted LAN, port 5001. All routes except `/health` require `Authorization: Bearer 12345`. Request size limit: 64 KiB.

- `GET /health`: connectivity and `motors_enabled`.
- `GET /status`: current `drive` state.
- `POST /measurements`: robot/player telemetry; returns current `drive` state.
- `GET /latest`: latest telemetry keyed by `robot` and `user`. This diagnostic snapshot uses its original one-second display expiry; navigation uses the stricter controller thresholds below.
- `POST /control`: a movement command/lease renewal; returns current `drive` state. HTTP 409 rejects unsafe, stale, out-of-order or unavailable commands. HTTP 503 reports a motor fault.

Example control packet:

```json
{
  "client_id": "player-app-session-UUID",
  "id": "command-UUID",
  "sequence": 12,
  "sent_at": 1794099600.123,
  "action": "forward",
  "speed": 50,
  "targetMeters": 2
}
```

Actions: `forward`, `reverse`, `left`, `right`, `summon`, `stop`, `drive`. Speed is percent of the driver's command scale (1–100 allowed); the driver further applies its existing 150/255 PWM duty cap. App manual speed is fixed at 100; all manual and guided movement requests now use 100%, including pivots. Legacy Summon uses its requested speed without the former 80/70 reductions. At 100%, each active channel reaches the 150/255 driver cap multiplied by its motor gain; stops remain zero. `targetMeters` is 1, 2 or 3. `sent_at` is Unix seconds. For motion it must be within [-250 ms future, 300 ms old] of the Pi clock. The app now automatically estimates Pi time from authenticated replies; matching phone/Pi wall clocks is no longer required.

A hold/Summon uses one UUID and renews it every 100 ms, with increasing sequence and a new timestamp. The Pi expires the lease after 300 ms. The app uses a separate HTTP task for control, independent of telemetry; only one renewal is outstanding. New actions get new IDs. Release/Stop uses a new ID. Any authenticated valid Stop takes precedence, including with skewed clocks or an older sequence. Completed, stopped, tracking-lost or timed-out command IDs cannot restart (bounded recent-ID cache, plus sequence ordering for the active owner). Another client cannot take over active motion; it may Stop, then issue a new command.

Every reply carries `drive`:

```json
{"enabled":true,"state":"manual","message":"Manual: forward","summonReady":false,"left":50,"right":50,"commandID":"command-UUID"}
```

`left`/`right` are requested robot-relative signed percentages before optional motor inversion. States include `disabled`, `stopped`, `manual`, `turning`, `approaching`, `arrived`, `tracking_lost`, `timed_out`, `fault`. These are commanded states, not encoder-confirmed movement. A successful motor write cannot verify that wheels physically turned.

## Robot tracking

Both phones upload at up to 20 Hz. Only `role=robot` is used for steering:

```json
{
  "device_id":"phone-session-UUID",
  "tracking_session_id":"ranging-session-UUID",
  "peer_connected":true,
  "role":"robot",
  "fresh":true,
  "age_s":0.02,
  "distance_m":3.1,
  "horizontal_angle_rad":0.15,
  "direction":null
}
```

Summon requires fresh connected robot pose with non-null distance and bearing. Sample age plus monotonic time since Pi receipt must be below 250 ms; pose receipt must be within 300 ms. Transmission delay is not in this pose-age estimate; expired control packets are separately rejected. If horizontal angle is null, the bridge can use `atan2(direction.x, -direction.z)` when a 3D vector exists. Missing bearing is never zero. On tracking loss/session change, stop and require a new Summon; do not automatically resume on recovery. Robot-phone disconnect also requests Stop, and loss of its uploads expires pose freshness.

Bearing is relative to the measuring phone. The calibrated controller angle is `wrap(sign * angle + offset)`. Positive means player to robot's right, so the controller pivots with left wheel forward/right reverse. Validate against actual mounting, wheel polarity and Apple horizontal-angle output before a Summon test. Distance is phone-to-phone slant range. Phone motion and mounting height affect it. The relative radar is not a room map.

## Game / compatibility

Optional `game` in telemetry carries the mirrored RoundState: UUID, targetMeters, durationSeconds, finished, startedAt/endsAt and shots (UUID, made, points), capped at 256 shots. Round dates are Swift JSONEncoder seconds since **2001-01-01 UTC** (add 978307200 for Unix time); control timestamps are explicitly Unix seconds. Player is game authority. Legacy `intent` fields are accepted for telemetry compatibility but **never execute motors**. Movement exclusively uses authenticated `/control` with the lease/watchdog logic.

## Runtime

A dedicated 50 Hz watchdog thread owns control decisions under a lock shared with command/pose ingestion. It never waits on network writes while holding that lock. GPIO errors latch a fault, attempt stop, and require a server restart. Ctrl+C attempts stop and closes Drive. A crash/power failure cannot be handled by a Python watchdog: retain the physical motor-power kill switch. Run one GPIO-owning process; do not run the teammate's demo sequence concurrently.

## Beam sensor events

Normal startup also attaches a gpiozero digital input on **BCM GPIO 24**, with pull-up and 5 ms electrical debounce. LOW means beam broken by default; `BEAM_ACTIVE_HIGH = True` reverses it. Set `ENABLE_MOTORS = False` for scoring-only use or `ENABLE_BEAM = False` to disable the sensor. Setup failures return scoring unavailable while leaving the motor bridge running.

Every reply carrying `drive` also carries `beam`:

```json
{"available":true,"pin":24,"blocked":false,"message":"Beam scoring on GPIO 24","breakCount":4,"events":[{"id":"event-UUID","roundID":"round-UUID","timestamp":1794099600.123,"points":1}]}
```

Only the player's `game` telemetry selects the active round; neither uploaded shots nor robot-mirrored game data create sensor events. A break requires at least 50 ms clear time and a 300 ms break-to-break cooldown. Initial blocked state, prolonged blockage, and rapid bounce cannot repeatedly score. `breakCount` includes accepted physical breaks outside rounds for diagnostics; `events` only includes scored events for the current round. Events timestamped outside the game's start/end window or while finished do not score.

Event timestamps are **Unix seconds**, distinct from the game's Swift-epoch dates. IDs are unique UUIDs generated by the Pi. The app retains existing shots and deduplicates by event ID, filters by round ID/time/points, then mirrors its updated score to the other phone. It can apply a pre-deadline event delivered just after expiry. Server events are in-memory only and bounded to 256; restarting the Pi loses undelivered events, but cannot duplicate previously received events. Scoring needs no new dependencies beyond gpiozero. Read sensor GPIO at 3.3 V logic.

Scoring is flat: every detected basket is one point, regardless of target distance. A miss produces no event and no score change. The app displays makes; raw blocked/clear state stays internal for debounce and rearming.

## LiDAR inspection hold

Authenticated `POST /inspection` with `{"enabled":true}` stops motion immediately and latches an inspection interlock. Manual and Summon commands return HTTP 409 while held, including after an ordinary Stop. `{"enabled":false}` releases the hold and leaves motors stopped; a new movement command is required. The hold has no automatic expiry, so a lost phone connection cannot resume a previous command. Closing Lab requests release; if that fails, restore connectivity and reopen/close Lab or restart the Pi. Replies use the existing `drive`/`beam` envelope; `drive.state` is `inspection` while held. No camera frames or depth maps are sent to the Pi.


## Phone-side guided approach

The player phone's Locate screen requests experimental Guided approach from the can. It makes decisions on iPhone from the existing relative Locate bearing/range and a live LiDAR left/right clearance fan; it does not use the cyan world-map target for steering. Short local detours use ARKit only to measure waypoint progress and remaining turn angle. It sends `forward`, `left`, `right`, `stop` actions through `/control`, owned by the can app's client ID. Update the Pi server for differential `drive` support. No ML inference, global map planner or new flags are needed. The Pi continues to enforce ownership, sequence/expiry and 300 ms command watchdog.

Guidance ticks every 100 ms; at most one control renewal is outstanding. Action changes use new IDs. The can announces guided activity to the player so manual/legacy Summon starts are disabled while guided driving is active. Player Stop still sends both an HTTP Stop and a peer stop request. Inspection Lab is mutually exclusive; opening it ends guidance before requesting the existing hold. Disconnect, app background, a Pi error/rejected/ended command, prolonged stale UWB/depth or blocked/unknown chosen route, avoidance timeout, AR reset or arrival ends the run. Only bounded sensor/route waits can resume automatically after stable measurements. UI preview can continue updating after a final stop, but only Start guided approach can arm again.

See [the guided approach test](guided-approach.md) for thresholds and physical limitations. Legacy Pi-side Summon is unchanged and still has no LiDAR checks.

Guided output is sent from the can phone by Start guided approach; merely previewing never sends movement commands. The app card shows commanded L/R percentages from Pi replies. PWM is capped at 150/255 in the actual driver, including commands exceeding 100% passed directly to Drive (the API rejects >100).

## Differential wheel commands and trim

`drive` requires both `leftPercent` and `rightPercent`, each finite numeric values in [-100,100]; positive is forward, negative reverse. For example:

```json
{"id":"new-uuid","client_id":"can-phone","sequence":10,"sent_at":1794110000,"action":"drive","targetMeters":1,"speed":100,"leftPercent":100,"rightPercent":85}
```

Use a real current `sent_at`. The `speed` field is still validated; `drive` uses the two wheel percentages directly. Changing either wheel percentage requires a new command UUID; lease renewal cannot mutate outputs. Ownership, expiry, inspection and watchdog checks are unchanged. Stop accepts the existing packet shape. `drive` remains supported for compatibility; current guidance uses full-power forward/left/right requests. Pi performs no navigation work.

`LEFT_MOTOR_GAIN = 0.90`, `RIGHT_MOTOR_GAIN = 1.00` in `pi/server.py` compensate for observed rightward drift. Gains multiply every wheel request before wiring inversion and the 150/255 PWM ceiling. Status `left`/`right` includes gains. Controller construction rejects gains <=0, >1, booleans and non-finite values.

Missing LiDAR/AR gets a stopped recovery window of 2 s; missing UWB heading or a blocked/unobserved route gets up to 8 s. Recovery requires three new clear depth frames, fresh UWB and a confirmed zero-output Stop. Measured obstacles within 5 cm, Pi errors, watchdog timeouts and AR resets remain final stops. Switching tabs alone does not end guidance. The forward ultrasonic sensor provides no rear protection. Automatic reverse is now a bounded 15 cm/0.6 s escape burst, followed by a confirmed Stop and observed side-lane selection.

## Automatic Pi clock synchronization

Drive-containing replies (`/measurements`, `/status`, `/control`, `/inspection`, including command rejections) include `server_time`, sampled in Pi Unix seconds immediately before response serialization. Existing `/health` and `/latest` shapes are unchanged. Rebuild both phone apps and update/restart `pi/server.py` for this addition.

Before motion, iOS estimates Pi time using a request's local monotonic send/receive times and the returned server time, with half the round-trip interval as a transit estimate. Only samples with round trip <=200 ms are accepted; recent lower-latency samples are preferred, refreshed after 2 s, and expire after 5 s. Phone wall-clock offset does not enter command timestamps. A Pi clock jump can replace the current estimate; a rejected run still requires explicit restart.

Movement stays disabled until synchronization is available. Motor status displays clock-sync state and sample RTT. A dedicated URLSession keeps telemetry requests out of the motor connection pool. Local movement acknowledgement age uses monotonic request elapsed time, **not** subtraction between phone and Pi wall times.

The Pi still rejects genuinely expired/future commands, checks sequence/ownership and stops after 300 ms without accepted renewals. Stop remains accepted without synchronized clocks. Expiry errors now report the signed packet age in milliseconds, making clock mismatches and large delays easier to diagnose. There is no automatic retry/rearming after a rejected movement command.

## Guided direction handoff and acknowledgement diagnostics

Guidance and manual arrows now call the same iOS motion-dispatch helper. Switching `drive`/forward to left/right cancels the obsolete in-flight request and sends the new direction immediately. Speed/trim-only changes keep waiting for the current response, preventing an acknowledgement starvation loop. Start is disabled until a prior Stop request has finished. Acknowledgement deadlines use monotonic uptime and no longer depend on wall-clock adjustment.

The motor URLSession allows two underlying connections so a canceled request cannot occupy the sole connection needed for a direction change or Stop. The Pi supports HTTP/1.1 persistent connections with Content-Length; error replies close the connection, including cases where a request body may not have been consumed.

A new command ID from the current owner retires the previous ID without forcing both motors through a full stop/start cycle. The driver switches off a channel's PWM enable before reversing direction pins. Explicit Stop, inspection, faults and the 300 ms watchdog still stop outputs; retired IDs cannot restart.

While driving, the player receives “Sending left · waiting for Pi” followed by “Pi confirmed left (N ms).” A stale-ack stop reports the pending action and request age. Pi console logs direction changes on receipt and completion with sequence, HTTP result, elapsed handling time and motor percentages; API tokens are never logged. These traces distinguish app/network delay from a Pi-side motor write delay. No movement acknowledgement is fabricated and the 600 ms app deadline, 300 ms Pi watchdog and clock-expiry checks remain in place.

Update the Pi server/controller/**driver** and rebuild both phones. Test guided forward→left→right and compare the console receipt/completion entries with the player status. Mock tests cover immediate dispatch policy, atomic command replacement, PWM-disable-before-reversal ordering, persistent requests, closed-ID replay rejection, duty caps and watchdog stopping. Hardware timing still requires validation.

## Full-power policy and resilient phone tracking

Manual and guided forward/reverse/left/right requests use speed=100. iOS no longer offers a speed slider or reduces guided pivot/forward wheel requests. The Pi's existing 0.90/1.00 motor balance gains and absolute 150/255 duty cap remain: 100% is the requested command level, not full battery voltage. No Pi deployment change is required for this iOS policy if the preceding clock/driver fixes are already installed.

Heading gaps pause movement without disconnecting NI/MPC/AR. NI timeout/suspension recovery retains sessions when possible; dropped phone links restart discovery without resetting camera geometry. Transient NI invalidations retry separately from Pi control; an explicit Disconnect cancels retries. Recovery never rearms movement after a final stop. Apple can still require camera convergence after a real session interruption; stale or missing heading never authorizes motor commands.

## Bounded automatic obstacle retreat

Guidance now uses the existing `reverse` action when supported front depth points show an obstacle within 45 cm. All movement requests remain speed=100. iOS—not Pi—caps the retreat at about 15 cm AR displacement or 0.6 s monotonic elapsed time from dispatch, with earlier stopping when a clear side is visible after at least 5 cm movement. There is no rear clearance sensing, so repeated reverse bursts are inhibited until the detour completes. Existing command expiry, confirmation and Pi watchdog remain unchanged.

After retreat, iOS sends Stop and requires confirmed zero output plus stable fresh observations before choosing a clear side and returning toward the player's live heading. Emergency proximity is now <=5 cm measured in the camera's ground plane; its exact reason persists in a red player-side label. Depth below 15 cm axial range is still filtered, so this is not guaranteed bumper protection. Unknown floor alone does not authorize reversing. The Pi API already supports these requests; rebuild both phones for the new planning/status payload.
