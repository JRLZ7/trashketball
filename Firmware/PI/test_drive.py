"""Replay the ESP32 motion sequence on the Pi drive."""

import time

from trashketball import Drive


def run_sequence(drive: Drive) -> None:
    drive.set_motor_control(True, 70, True, 70)  # forward
    time.sleep(2)
    drive.set_motor_control()
    time.sleep(0.1)
    drive.set_motor_control(True, 100, False, 100)  # spin in place
    time.sleep(1)
    drive.set_motor_control()  # stop
    time.sleep(1)
    drive.set_motor_control(False, 100, True, 100)  # spin other way
    time.sleep(1)
    drive.set_motor_control()
    time.sleep(0.1)
    drive.set_motor_control(False, 70, False, 70)  # reverse
    time.sleep(2)
    drive.set_motor_control()  # stop
    time.sleep(1)


def main() -> None:
    drive = Drive()
    try:
        while True:
            run_sequence(drive)
    except KeyboardInterrupt:
        pass
    finally:
        drive.set_motor_control()
        drive.close()


if __name__ == "__main__":
    main()
