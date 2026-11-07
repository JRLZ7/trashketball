#include <Arduino.h>

// Left motor (L298N channel A)
const int leftMotorControl1Pin = 26;
const int leftMotorControl2Pin = 27;
const int leftMotorSpeedPin = 25;
// Right motor (L298N channel B)
const int rightMotorControl1Pin = 33;
const int rightMotorControl2Pin = 19;
const int rightMotorSpeedPin = 32;

// PWM duty cap (0-255). Driver supply is 12V, motors are rated 6V.
const int maxSpeed = 130; // CAREFULL!! INCREASING COULD BURN MOTOR. 130 = 6.2V

// Speed is a percent (0-100). Direction: true = forward.
void setMotorControl(bool leftForward = true, int leftSpeed = 0,
                     bool rightForward = true, int rightSpeed = 0);

void setup() {
  pinMode(leftMotorControl1Pin, OUTPUT);
  pinMode(leftMotorControl2Pin, OUTPUT);
  pinMode(leftMotorSpeedPin, OUTPUT);
  pinMode(rightMotorControl1Pin, OUTPUT);
  pinMode(rightMotorControl2Pin, OUTPUT);
  pinMode(rightMotorSpeedPin, OUTPUT);

  // Start with everything off
  digitalWrite(leftMotorControl1Pin, LOW);
  digitalWrite(leftMotorControl2Pin, LOW);
  analogWrite(leftMotorSpeedPin, 0);
  digitalWrite(rightMotorControl1Pin, LOW);
  digitalWrite(rightMotorControl2Pin, LOW);
  analogWrite(rightMotorSpeedPin, 0);
}

void loop() {
  setMotorControl(true, 70, true, 70);     // forward
  delay(2000);
  setMotorControl();
  delay(100);
  setMotorControl(true, 100, false, 100);  // spin in place
  delay(1000);
  setMotorControl();                       // stop
  delay(1000);
  setMotorControl(false, 100, true, 100);  // spin other way
  delay(1000);
  setMotorControl();
  delay(100);
  setMotorControl(false, 70, false, 70);   // reverse
  delay(2000);
  setMotorControl();                       // stop
  delay(1000);
}

void setMotorControl(bool leftForward, int leftSpeed, bool rightForward,
                     int rightSpeed) {
  // Map percent (0-100) to duty (0-maxSpeed)
  leftSpeed = constrain(map(leftSpeed, 0, 100, 0, maxSpeed), 0, maxSpeed);
  rightSpeed = constrain(map(rightSpeed, 0, 100, 0, maxSpeed), 0, maxSpeed);

  digitalWrite(leftMotorControl1Pin, leftForward);
  digitalWrite(leftMotorControl2Pin, !leftForward);
  analogWrite(leftMotorSpeedPin, leftSpeed);

  digitalWrite(rightMotorControl1Pin, rightForward);
  digitalWrite(rightMotorControl2Pin, !rightForward);
  analogWrite(rightMotorSpeedPin, rightSpeed);
}