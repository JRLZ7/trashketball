# Trashketball

Two iPhones provide UWB distance and camera-assisted bearing. A native SwiftUI app runs the game and sends movement commands over Wi-Fi to a Raspberry Pi, which drives the L298N through the teammate's Python `Drive` class.

## App

Open `ios/TrashBotUWB.xcodeproj`, select your signing team, and install on **both phones** (iOS 17+).

- **Play:** 30/60/90-second rounds, 1/2/3 m positioning, automatic beam-break baskets on BCM GPIO 24 and personal best. Each detected basket adds one make/point, regardless of distance; misses do not change the count. The player app merges sensor events without double counting. Score syncs to the can phone.
- **Locate:** live relative radar, distance, bearing and calibration guidance. Hold an arrow to drive; release to stop. Speed defaults to 80% and adjusts from 20–100% of the driver's already duty-capped scale. Summon turns toward the player and approaches the selected throwing distance.
- **Connect:** Player/On the can roles, camera assistance, Pi URL and diagnostics. The API token is preset to `12345` in the app and server. Use the same Pi URL on both phones. Keep both apps foregrounded.

3D direction can report unsupported on newer iPhones while camera-assisted horizontal angle works. For calibration, translate and sweep the phones in a textured, well-lit room, initially facing their rear cameras toward one another. Test the mounted phone's bearing, not just a handheld phone. The radar is relative to the phone, not a room map.

## Start on the Pi

Run from the repository root. Do not run `test_drive.py` at the same time: only one process should own the motor GPIO.

```sh
sudo apt install python3-gpiozero python3-lgpio
python3 pi/server.py
```

This enables **motors, beam scoring and Summon** by default. No flags or environment-token setup are required. Startup settings are constants at the top of `pi/server.py`. See `Firmware/PI/trashketball/drive.py` for the authoritative BCM pin defaults and PWM cap; the bridge does not change them. Current defaults are left IN1/IN2/ENA = 17/27/18 and right IN3/IN4/ENB = 22/23/19. Motor power remains separate from Pi power, with common ground.

Find the Pi's address with `hostname -I`. On both phones, enter `http://PI_IP:5001` in Connect, then reconnect. The API token `12345` is configured automatically. `/health` is a Safari connectivity check; `/status`, `/latest` and all POST routes require the bearer token. Use a trusted LAN/hotspot; HTTP tokens are unencrypted in transit.

## First movement and Summon

1. Lift the driven wheels off the ground. Start the server normally, connect the Player app to the Pi, and hold Forward. Both wheels should rotate forward. Release and verify stopping; test reverse and each turn. Adjust `INVERT_LEFT` / `INVERT_RIGHT` in `pi/server.py` if physical motor polarity differs.
2. Put the can phone in its final mount. Check the player is straight ahead at angle near zero; move the player right and verify the reported bearing sign against the steering convention. Set `BEARING_SIGN = -1` or adjust `BEARING_OFFSET_DEG` in `pi/server.py` and restart if needed. The sign is applied before the offset. Zero is the robot-forward direction after calibration.
3. Summon is enabled at startup. After verifying steering sign and mount, run:

```sh
python3 pi/server.py
```

Inversion/sign/offset settings live in `pi/server.py`. Set `ENABLE_SUMMON = False` there if you need to temporarily disable autonomous approach. Both phones must be paired, and the **robot phone** must supply fresh distance and bearing. Test in a clear arena at a low speed with a spotter and physical kill switch. There is no obstacle detection.

Summon pivots toward the player, drives forward, and stops when the measured phone-to-phone range is within 15 cm above the selected distance. It never reverses if already too close. Slant range and mounting height affect the relationship to floor distance. Summon caps forward drive at 80% and pivots at up to 70%; hardware tuning is still required.

The Pi has a **300 ms command watchdog**, independent of the HTTP upload task. Summon also stops if robot tracking is older than 250 ms, loses bearing/peer connection, or changes tracking session. A stopped/expired request cannot resume itself: press Summon or a direction again. Leaving Locate, backgrounding/disconnecting the app, and releasing a manual arrow request Stop; if that request fails, the Pi watchdog expires. This is not a substitute for the physical kill switch. Stop is coast/enable-off using the existing driver.

Phone and Pi clocks must agree closely: the server rejects movement packets older than 300 ms or more than 250 ms in the future. Stop is accepted despite clock skew. Keep system network time enabled.

## Beam-break scoring · BCM GPIO 24

The sensor is enabled automatically. For scoring-only testing, set `ENABLE_MOTORS = False` in `pi/server.py`. Set `ENABLE_BEAM = False` there for motor-only testing. In Play, check that automatic scoring is ready, then pass a ball through the opening during a round. The input uses a pull-up and defaults to **LOW = broken**. If your sensor has opposite polarity, set `BEAM_ACTIVE_HIGH = True` in `pi/server.py`. Sensor signal must be suitable for the Pi's 3.3 V GPIO.

Start a round on the player phone. The Pi tags each beam event with a unique ID, round ID, timestamp and one point. It ignores initial blocked state, requires a clear interval before rearming, and has a 300 ms repeat cooldown. A continuously blocked opening scores once; clear it before the next throw. No Made it/Miss buttons are used. A single beam cannot distinguish a paper ball from a hand, or count misses.

Scoring is enabled only during the round window. Sensor events are retained in memory (up to 256) and included in authenticated replies so short polling interruptions do not double count or lose already recorded events. Events for another round or after the deadline are ignored. Game controls require a live sensor connection to start; sensor setup errors leave driving available but scoring offline. Rebuild the app and restart the Pi server after updating.

The motor speed increase uses more of the existing driver's duty range: the underlying `MAX_DUTY = 130/255` is unchanged for the documented 6 V motors on a 12 V supply. This does not change battery voltage.

[Sensor polarity reference](https://learn.adafruit.com/ir-breakbeam-sensors/circuitpython)

## Tests

```sh
python3 -m unittest discover -s pi -p 'test_*.py' -v
swiftc -module-cache-path /tmp/trashketball-swift-cache ios/TrashBotUWB/GameState.swift tests/main.swift -o /tmp/trashketball-game-tests
/tmp/trashketball-game-tests
```

Controller/HTTP tests use injected fake motors, including watchdog, tracking loss, arrival, stale/replayed commands and authenticated motor calls. The actual teammate `Drive` class has also been checked with gpiozero mock PWM pins. iOS builds are checked unsigned; radio performance, mounting calibration, motor force and stopping distance require real hardware tests.

[Pi HTTP contract](docs/pi-interface.md) · [Teammate motor-driver guide](Firmware/PI/README.md)

## Experimental LiDAR Lab

On the can phone, open **Lab** for a camera/depth overlay, AR tracking, automatic floor initialization using the provisional 30 cm width / 44 cm camera-height assumptions, and a forward-corridor obstacle estimate. Processing runs on the iPhone. The Pi receives an inspection hold that stops and blocks motors while the screen is open; restart the updated Pi server before testing. Without a confirmed hold, disconnect motor power before using the standalone preview option. This milestone does not steer or plan a path.

See [LiDAR Lab setup, box test and limitations](docs/lidar-lab.md). The phone shares one ARKit session between depth, preview and UWB camera assistance. Physical-device testing is required for sensor accuracy and UWB coexistence; Simulator only verifies unavailable states and navigation.
