"""Two-channel L298N drive using gpiozero software PWM."""

from __future__ import annotations

from dataclasses import dataclass

from gpiozero import DigitalOutputDevice, Motor, PWMOutputDevice
from gpiozero.mixins import SourceMixin

# 12 V supply, motors rated 6 V. 100% command speed is duty 130/255.
MAX_DUTY = 130 / 255
PWM_FREQUENCY_HZ = 1000


@dataclass(frozen=True)
class DrivePins:
    """BCM pin numbers for the two L298N channels."""

    left_forward: int = 17
    left_backward: int = 27
    left_enable: int = 18
    right_forward: int = 22
    right_backward: int = 23
    right_enable: int = 19


class Drive:
    """Owns the left and right motors and maps percent speed onto the duty cap."""

    def __init__(self, pins: DrivePins | None = None) -> None:
        self._pins = pins or DrivePins()
        self._left = _L298NChannel(
            self._pins.left_forward,
            self._pins.left_backward,
            self._pins.left_enable,
        )
        self._right = _L298NChannel(
            self._pins.right_forward,
            self._pins.right_backward,
            self._pins.right_enable,
        )
        self._closed = False

    def set_motor_control(
        self,
        left_forward: bool = True,
        left_speed: int = 0,
        right_forward: bool = True,
        right_speed: int = 0,
    ) -> None:
        """Match setMotorControl: percent 0-100, constrained, then scaled by 130/255.

        A no-arg call coasts both motors (enable off).
        """
        _apply(self._left, left_forward, left_speed)
        _apply(self._right, right_forward, right_speed)

    def close(self) -> None:
        """Release the GPIO pins."""
        if self._closed:
            return
        self._closed = True
        self._left.close()
        self._right.close()

    def __enter__(self) -> Drive:
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


class _L298NChannel(Motor):
    """Digital forward/backward pins and a software-PWM enable.

    gpiozero.Motor PWMs the direction pins and keeps enable digital. This
    channel follows the ESP32 wiring: IN1/IN2 select direction, and the enable
    pin carries the duty cycle so any BCM pin can be used.
    """

    def __init__(self, forward: int, backward: int, enable: int) -> None:
        # Motor.__init__ cannot build a PWM enable, so initialize the mixin
        # chain with the devices this H-bridge actually needs.
        SourceMixin.__init__(
            self,
            forward_device=DigitalOutputDevice(forward),
            backward_device=DigitalOutputDevice(backward),
            enable_device=PWMOutputDevice(enable, frequency=PWM_FREQUENCY_HZ),
            _order=("forward_device", "backward_device", "enable_device"),
        )

    @property
    def value(self) -> float:
        speed = float(self.enable_device.value)
        if self.forward_device.is_active and not self.backward_device.is_active:
            return speed
        if self.backward_device.is_active and not self.forward_device.is_active:
            return -speed
        return 0.0

    @value.setter
    def value(self, value: float) -> None:
        if not -1 <= value <= 1:
            raise ValueError("Motor value must be between -1 and 1")
        if value > 0:
            self.forward(value)
        elif value < 0:
            self.backward(-value)
        else:
            self.stop()

    def forward(self, speed: float = 1) -> None:
        if not 0 <= speed <= 1:
            raise ValueError("forward speed must be between 0 and 1")
        self.backward_device.off()
        self.forward_device.on()
        self.enable_device.value = speed

    def backward(self, speed: float = 1) -> None:
        if not 0 <= speed <= 1:
            raise ValueError("backward speed must be between 0 and 1")
        self.forward_device.off()
        self.backward_device.on()
        self.enable_device.value = speed

    def stop(self) -> None:
        self.enable_device.off()
        self.forward_device.off()
        self.backward_device.off()


def _constrain_percent(speed: float) -> float:
    return max(0.0, min(100.0, float(speed)))


def _apply(motor: Motor, forward: bool, speed: float) -> None:
    percent = _constrain_percent(speed)
    if percent == 0:
        motor.stop()
        return
    duty = (percent / 100.0) * MAX_DUTY
    motor.value = duty if forward else -duty
