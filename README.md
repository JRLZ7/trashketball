# Trashketball

Two iPhones provide UWB distance and camera-assisted bearing. A native SwiftUI app runs the game and sends movement commands over Wi-Fi to a Raspberry Pi, which drives the L298N through the teammate's Python `Drive` class.

## App

Open `ios/TrashBotUWB.xcodeproj`, select your signing team, and install on **both phones** (iOS 17+).

- **Play:** 30/60/90-second rounds, 1/2/3 m challenges, automatic beam-break baskets on BCM GPIO 24 and personal best. Points follow the selected challenge; each distinct break scores once. The player app merges sensor events without double counting. Score syncs to the can phone.
- **Locate:** live relative radar, distance, bearing and calibration guidance. Hold an arrow to drive; release to stop. Speed defaults to 80% and adjusts from 20–100% of the driver's already duty-capped scale. Summon turns toward the player and approaches the selected throwing distance.
- **Connect:** Player/On the can roles, camera assistance, Pi URL/token and diagnostics. Use the same Pi URL/token on both phones. Keep both apps foregrounded.

3D direction can report unsupported on newer iPhones while camera-assisted horizontal angle works. For calibration, translate and sweep the phones in a textured, well-lit room, initially facing their rear cameras toward one another. Test the mounted phone's bearing, not just a handheld phone. The radar is relative to the phone, not a room map.

## Start on the Pi

Run from the repository root. Do not run `test_drive.py` at the same time: only one process should own the motor GPIO.

```sh
sudo apt install python3-gpiozero python3-lgpio
export TRASHBOT_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
python3 pi/server.py --drive
```

This enables **manual driving**. Without `--drive`, the server runs telemetry only. See `Firmware/PI/trashketball/drive.py` for the authoritative BCM pin defaults and PWM cap; the bridge does not change them. Current defaults are left IN1/IN2/ENA = 17/27/18 and right IN3/IN4/ENB = 22/23/19. Motor power remains separate from Pi power, with common ground.

Find the Pi's address with `hostname -I`. On both phones, enter `http://PI_IP:5001` and the same token in Connect, then reconnect. Use `printenv TRASHBOT_TOKEN` in the server terminal to see the generated token. It stays in phone memory only. `/health` is a Safari connectivity check; `/status`, `/latest` and all POST routes require the bearer token. Use a trusted LAN/hotspot; HTTP tokens are unencrypted in transit.

## First movement and Summon

1. Lift the driven wheels off the ground. Start the server with `--drive`, connect the Player app to the Pi, and hold Forward. Both wheels should rotate forward. Release and verify stopping; test reverse and each turn. Adjust `--invert-left` / `--invert-right` if physical motor polarity differs.
2. Put the can phone in its final mount. Check the player is straight ahead at angle near zero; move the player right and verify the reported bearing sign against the steering convention. Restart the server with `--bearing-sign -1` or `--bearing-offset-deg VALUE` if needed. The sign is applied before the offset. Zero is the robot-forward direction after calibration.
3. After verifying steering sign and mount, enable Summon:

```sh
python3 pi/server.py --drive --bearing-calibrated
```

Add your inversion/sign/offset flags to this command as needed. Summon stays disabled in the UI until the Pi reports calibration enabled. Both phones must be paired, and the **robot phone** must supply fresh distance and bearing. Test in a clear arena at a low speed with a spotter and physical kill switch. There is no obstacle detection.

Summon pivots toward the player, drives forward, and stops when the measured phone-to-phone range is within 15 cm above the selected distance. It never reverses if already too close. Slant range and mounting height affect the relationship to floor distance. Summon caps forward drive at 80% and pivots at up to 70%; hardware tuning is still required.

The Pi has a **300 ms command watchdog**, independent of the HTTP upload task. Summon also stops if robot tracking is older than 250 ms, loses bearing/peer connection, or changes tracking session. A stopped/expired request cannot resume itself: press Summon or a direction again. Leaving Locate, backgrounding/disconnecting the app, and releasing a manual arrow request Stop; if that request fails, the Pi watchdog expires. This is not a substitute for the physical kill switch. Stop is coast/enable-off using the existing driver.

Phone and Pi clocks must agree closely: the server rejects movement packets older than 300 ms or more than 250 ms in the future. Stop is accepted despite clock skew. Keep system network time enabled.

## Beam-break scoring · BCM GPIO 24

The sensor is enabled automatically with `--drive`. For scoring-only testing without motors, use `python3 pi/server.py --beam`. `--no-beam` skips sensor setup when testing motors alone. In Play, verify the live **Beam clear / Beam blocked** indicator by interrupting the beam. The input uses a pull-up and defaults to **LOW = broken**. If your sensor has opposite polarity, add `--beam-active-high` on the Pi. Sensor signal must be suitable for the Pi's 3.3 V GPIO.

Start a round on the player phone. The Pi tags each beam event with a unique ID, round ID, timestamp and selected-distance points. It ignores initial blocked state, requires a clear interval before rearming, and has a 300 ms repeat cooldown. A continuously blocked opening scores once; clear it before the next throw. No Made it/Miss buttons are used. A single beam cannot distinguish a paper ball from a hand, or count misses.

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
