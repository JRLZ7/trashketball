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

Actions: `forward`, `reverse`, `left`, `right`, `summon`, `stop`. Speed is percent of the driver's command scale (1–100 allowed); the driver further applies its existing 130/255 PWM duty cap. App manual range is 20–100, default 80; Summon caps forward output at 80 and pivot output at 70. `targetMeters` is 1, 2 or 3. `sent_at` is Unix seconds. For motion it must be within [-250 ms future, 300 ms old] of the Pi clock. Keep network time enabled.

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
