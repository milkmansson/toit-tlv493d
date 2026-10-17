// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import tlv493d show *
import tlv493d.joystick show *

/*
  Please set pins correctly for your device.
  I2C bus speed is 400_000 - slow to 100_000 or less to troubleshoot I2C issues.
*/

sda-pin-number := 21
scl-pin-number := 20
frequency := 100_000

main:
  bus := i2c.Bus
      --sda=sda-pin-number   // (gpio.Pin sda-pin-number)
      --scl=scl-pin-number   // (gpio.Pin scl-pin-number)
      --frequency=frequency

  // Swap in Tlv493dA2bw here and the rest stays the same.
  sensor := Tlv493d-a1b6 (bus.device Tlv493d-a1b6.I2C-ADDRESS)
  joystick := Joystick sensor

  print "Leave the stick at rest..."
  sleep --ms=1000
  joystick.calibrate
  print "Now push the stick to all its limits for 5 seconds."
  print "Learned travel: $(%.1f joystick.learn-travel) mT"

  // Discrete events: fire once per transition.
  joystick.add Joystick.UP (:: print "UP")
  joystick.add Joystick.DOWN (:: print "DOWN")
  joystick.add Joystick.LEFT (:: print "LEFT")
  joystick.add Joystick.RIGHT (:: print "RIGHT")
  joystick.add Joystick.CENTER (:: print "CENTER")
  joystick.add Joystick.PRESS (:: print "PRESS")
  joystick.add Joystick.RELEASE (:: print "RELEASE")

  // Continuous values: fires when the stick moved noticeably.
  joystick.on-change (:: |state| print state)

  // The driver starts no tasks.  Your application polls it, ideally from one
  // shared housekeeping task if you have several drivers.
  while true:
    joystick.update
    sleep --ms=(max 5 sensor.sample-period-ms)
