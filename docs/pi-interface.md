# Pi integration contract · telemetry adapter

The teammate's driver lives on a separate branch. This receiver is a test adapter, not its replacement. Keep motor output disabled until mounting calibration and command/watchdog semantics are agreed. No GPIO pins or driver API are assumed.

## Transport

Both phones POST to `/measurements` at up to 5 Hz, using `Authorization: Bearer TOKEN` and JSON. At most one upload is outstanding per phone; failed requests time out and retry on a later tick. There is no background delivery. Payload is capped at 64 KiB by the receiver. `GET /health` is public; `GET /latest` requires the same token. Data is in memory; the receiver prints packets as JSON.

Minimal example:

```json
{
  "device_id": "session-generated-UUID",
  "role": "robot",
  "fresh": true,
  "age_s": 0.05,
  "distance_m": 2.4,
  "horizontal_angle_rad": 0.15,
  "direction": null,
  "intent": {
    "id": "UUID",
    "action": "summon",
    "targetMeters": 2
  },
  "game": {
    "id": "UUID",
    "targetMeters": 2,
    "durationSeconds": 30,
    "finished": false,
    "startedAt": 815000000,
    "endsAt": 815000030,
    "shots": [{"id": "UUID", "made": true, "points": 2}]
  }
}
```

`game` and `intent` are optional. Swift JSONEncoder dates are seconds since **2001-01-01 UTC**, not Unix epoch. Convert with `unix_seconds = encoded_date + 978307200`. Shots are capped at 256 per round. Score is the sum of shot points; baskets count `made == true`. Player is the game authority; Robot only mirrors the state.

`/latest` returns an object keyed by `robot` and `user`. Each entry includes `received_age_s` calculated with the receiver's monotonic clock. Only one pair is supported per receiver; later packets overwrite their role slot. This is not a public multi-user matchmaking service.

## Coordinate and freshness semantics

- Use **robot-role** measurements for robot steering. Player-phone bearings use another reference frame and cannot be substituted or averaged directly.
- Distance is phone-to-phone slant range, not automatically horizontal ground distance. Different mounting heights change that relationship.
- `horizontal_angle_rad` comes from Apple's `horizontalAngle`, in radians in the measuring phone's frame. Calibrate sign/forward offset in the actual mount before steering. The radar uses positive angles to the display's right and zero toward the rear-camera forward ray as a visualization convention; this is not a calibrated wheel command.
- `direction` is optional x/y/z unit-vector data, not meters or a shared world position. It may always be null on the tested newer devices.
- `fresh` means a measurement update was received locally within one second. Individual optional fields can still be null. The receiver additionally expires fields after reported sample age plus receiver elapsed time reaches one second. Transmission delay is not included in that estimate. This display freshness window is **not** a motor watchdog.
- On stale snapshots, the receiver clears distance, direction, bearing and intent. Missing bearing must not be interpreted as zero/straight ahead.

## Request lifecycle

Player → encrypted peer message → Robot phone → receipt to Player. The latest intent is then included in periodic telemetry from both phones, not a dedicated motor endpoint. UUID stays constant across repeats. Receipt only confirms phone delivery. Current UI always labels driving offline.

A future adapter must deduplicate request UUIDs, reject stale sessions and unsafe measurement states, and define arrival/stop/execution acknowledgements. Do not execute the same summon on every telemetry packet. Do not replay a stored summon after a restart or tracking recovery. Stop should take precedence. The native app's Request stop depends on a live peer connection and is not an emergency stop.

Once the teammate's API is available, connect it through a dedicated adapter rather than mixing GPIO into the app or replacing their driver. Decide control update rate, timeout, motor polarity, bearing calibration, range/arrival tolerance and physical stop handling together. The app does not yet consume driver state or claim that the robot has arrived.
