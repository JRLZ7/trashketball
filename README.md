# Trashketball

A moving-basket game for the Duke Cube hackathon. Two iPhones use Nearby Interaction to measure relative distance and camera-assisted bearing; a Raspberry Pi receives the telemetry. Native SwiftUI app, Python receiver, no third-party dependencies.

## What works in this version

- **Play:** 30/60/90-second rounds; 1/2/3 m challenges worth 1/2/3 points per basket; manual basket/miss logging, undo, timer expiry, saved personal best. Points use the selected challenge distance, not an automatically verified floor distance.
- **Locate:** live distance and horizontal bearing, relative radar, missing/stale tracking states, camera-calibration guidance. This is relative phone positioning, not a room map. Display radius is 6 m; farther targets are clamped visually while numeric distance stays unchanged.
- **Connect:** Player/On-the-can roles, encrypted Multipeer Connectivity pairing, optional authenticated Pi telemetry at up to 5 Hz.
- Player round/score sync to the can phone. Summon/stop intents are acknowledged by the can phone and included in telemetry.
- **Driving is offline.** An acknowledgement means the phone received the request, not that motors executed it. No motor commands, obstacle avoidance, automatic scoring, or physical emergency-stop functionality are implemented here. The teammate's Pi controller remains separate.

## Run on your two iPhones

1. Open `ios/TrashBotUWB.xcodeproj` in Xcode. Select the TrashBotUWB target and your team under Signing & Capabilities. If needed, change the bundle identifier to a unique one. App name on the phone is **Trashketball**; target name remains TrashBotUWB.
2. Install on both physical phones (iOS 17+). This replaces the earlier test app if the bundle identifier is unchanged. Simulator is useful for UI only.
3. On **Connect**, choose Player on the handheld phone and On the can on the mounted phone. Leave Pi URL blank for initial phone-only play.
4. Leave camera assistance on; enable Wi-Fi/Bluetooth, grant Nearby Interaction, Local Network and Camera permission. Tap Connect phones on both.
5. Calibrate in a well-lit textured area. Face rear cameras toward one another initially and translate/sweep the phones horizontally and vertically. If calibration reports insufficientMovement, translate the phone through space rather than just rotating it. Keep both apps foregrounded.
6. On Locate, verify live distance and bearing, including after putting the phone in its real mount. On Play, select a challenge and start a round. Log baskets manually. Watch the score sync on the other phone.

Both phones need this version: the peer protocol now carries token, round, intent and receipt messages. Older test builds cannot pair correctly with this protocol. Backgrounding or disconnecting stops ranging; reconnect BOTH phones. A running game continues against its wall-clock deadline and finishes when the player app next updates. Completed best score persists locally; ongoing rounds and peer requests do not survive app termination.

`supportsDirectionMeasurement == false` on the tested 16 Pro/17 Pro does not preclude camera-assisted `horizontalAngle`. The app uses horizontalAngle first, with a 3D-vector fallback when available. Missing bearing remains missing; it is never invented from distance.

## Optional Pi telemetry

Copy `pi/server.py` to the Pi (or run it from a checkout):

```sh
export TRASHBOT_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
python3 pi/server.py
```

The receiver listens on port **5001**. In another terminal, run `hostname -I` to find the LAN address. Enter `http://PI_IP:5001` and the same token in each phone's Connect screen while disconnected, then reconnect. The token stays in phone memory only. Use `printenv TRASHBOT_TOKEN` in the server terminal to see the generated value.

Health check from Safari: `http://PI_IP:5001/health`. If unreachable, check Wi-Fi client isolation, IP, firewall/port, and Local Network permission. Own hotspot/router is preferable to an isolated venue LAN. This HTTP receiver is for a trusted LAN only; bearer tokens are unencrypted in transit. Do not expose it to the internet.

See [the Pi integration contract](docs/pi-interface.md) for payloads and teammate integration. The receiver prints JSON and exposes authenticated latest telemetry; it does not drive motors.

## Validation

```sh
python3 -m unittest discover -s pi -p test_server.py -v
swiftc -module-cache-path /tmp/trashketball-swift-cache ios/TrashBotUWB/GameState.swift tests/main.swift -o /tmp/trashketball-game-tests
/tmp/trashketball-game-tests
xcodebuild -project ios/TrashBotUWB.xcodeproj -scheme TrashBotUWB -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
```

Builds have been checked for physical iOS and Simulator. Tests cover scoring, undo, deadline, best-score persistence, peer payload encoding, authenticated HTTP roundtrips, malformed measurements, optional bearing, game/intent data, and stale telemetry. Two-device game sync and intent acknowledgements still need physical validation; UWB distance/bearing was validated separately on your phones before this integration.

Apple references: [Nearby Interaction](https://developer.apple.com/documentation/nearbyinteraction), [camera assistance and horizontal angle](https://developer.apple.com/videos/play/wwdc2022/10008/), [peer discovery](https://developer.apple.com/documentation/nearbyinteraction/discovering-peers-with-multipeer-connectivity).

## Pi motor driver

The teammate-maintained motor driver and wiring instructions are in [Firmware/PI/README.md](Firmware/PI/README.md). This is separate from the measurement-only receiver in `pi/`.
