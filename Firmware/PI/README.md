# trashketball on the Pi

This directory is the Raspberry Pi drive library. The importable package is `trashketball`. Run the commands below from `Firmware/PI` so `import trashketball` resolves.

## Install

On the Pi, install gpiozero and the lgpio pin factory. Pi 5 and Raspberry Pi OS Bookworm need `python3-lgpio`.

```
sudo apt install python3-gpiozero python3-lgpio
```

`Firmware/PI/requirements.txt` lists `gpiozero`. Use pip only if you are not installing those apt packages:

```
pip install -r requirements.txt
```

Start the demo from this directory:

```
python test_drive.py
```

`test_drive.py` repeats the motion sequence until you press Ctrl+C. It then coasts both motors and releases the pins.

To dry-run on a machine without GPIO, set both of these environment variables. gpiozero's default mock pin class rejects PWM, so the mock PWM pin class has to be selected too:

```
GPIOZERO_PIN_FACTORY=mock GPIOZERO_MOCK_PIN_CLASS=mockpwmpin python test_drive.py
```

## Wiring

The Pi drives the same L298N as the ESP32 build. The motor supply is 12 V. The TT motors are rated 6 V. Pi GPIO is 3.3 V logic into the L298N inputs. Each enable pin is software PWM at 1000 Hz.

GPIO pinout on the can. Every number below is a BCM GPIO, not a physical header pin. Motor 1 is the left channel and motor 2 is the right channel. The motor GPIOs are the defaults on `DrivePins` in `trashketball/drive.py`. The ESP32 sketch uses different GPIO numbers. The beam break and the ultrasonic trigger/echo are wired. The drive library does not read them; the root `pi/server.py` bridge now reads the beam sensor for scoring.

- GPIO 24: beam break sensor
- GPIO 17: motor 1 forward
- GPIO 27: motor 1 backward
- GPIO 18: motor 1 enable
- GPIO 22: motor 2 forward
- GPIO 23: motor 2 backward
- GPIO 19: motor 2 enable
- GPIO 5: ultrasonic trigger
- GPIO 6: ultrasonic echo

A command speed of 100% is written as duty `130/255` (`MAX_DUTY`). Raising `MAX_DUTY` can overvolt the motors on the 12 V supply.

## API

```python
from trashketball import Drive, DrivePins
```

`Drive` owns both channels. `Drive()` uses the BCM defaults above. Pass a `DrivePins` instance when the header wiring is different.

```python
drive.set_motor_control(left_forward=True, left_speed=0, right_forward=True, right_speed=0)
```

Each side takes a direction bool and a speed as a percent from 0 to 100. Values outside that range are clamped, then scaled by `130/255`. A speed of 0 turns that channel's enable off. A call with no arguments coasts both motors. `close()` releases the pins. A `with Drive() as drive:` block calls `close()` when it exits.

```python
from trashketball import Drive, DrivePins

pins = DrivePins(
    left_forward=17,
    left_backward=27,
    left_enable=18,
    right_forward=22,
    right_backward=23,
    right_enable=19,
)

with Drive(pins) as drive:
    drive.set_motor_control(left_forward=True, left_speed=70, right_forward=True, right_speed=70)
    drive.set_motor_control()
    drive.set_motor_control(left_forward=True, left_speed=100, right_forward=False, right_speed=100)
```

That example builds a `Drive` on the harness pins above (motor 1 on the left channel, motor 2 on the right), drives both sides forward at 70%, coasts, then spins by driving the sides in opposite directions. `Drive()` uses those same motor pins.

`run_sequence` in `test_drive.py` is the full timed demo. It drives forward for 2 seconds, coasts for 0.1 seconds, spins in place for 1 second, coasts for 1 second, spins the other way for 1 second, coasts for 0.1 seconds, reverses for 2 seconds, then coasts for 1 second. Those coasts match the ESP32 `loop()`.

## App scoring and speed

The root app bridge (`python3 pi/server.py --drive` from the repository root) reads BCM GPIO 24 with pull-up, defaults to LOW = broken, and debounces basket events during timed rounds. Use `--beam-active-high` if your module's output is inverted, `--beam` for scoring-only operation, or `--no-beam` for motor-only testing. Check Play's clear/blocked indicator before a round.

The app now defaults to 80% command speed, allows 100% manual command, and caps autonomous forward command at 80%. These percentages are still scaled by this driver's `130/255` PWM cap. No motor pin assignments or MAX_DUTY values were changed.
