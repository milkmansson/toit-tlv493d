// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import log
import tlv493d show *

sda-pin-number := 21    // Set these to match the board in use.
scl-pin-number := 20    // Set these to match the board in use.

main:
  bus := i2c.Bus
      --sda=sda-pin-number   // (gpio.Pin sda-pin-number)
      --scl=scl-pin-number   // (gpio.Pin scl-pin-number)
      --frequency=400_000

  if not bus.test Tlv493d-a1b6.I2C-ADDRESS:
    print "No TLV493D-A1B6 found at 0x$(%02x Tlv493d-a1b6.I2C-ADDRESS)"
    return

  // The default is Tlv493d.MODE-LOW-POWER (about 100 Hz).  Pass
  // --mode=Tlv493d.MODE-ULTRA-LOW-POWER for about 10 Hz.  That saves power
  // but a joystick built on it will lag; the driver logs a warning.
  sensor := Tlv493d-a1b6 (bus.device Tlv493d-a1b6.I2C-ADDRESS)
  print "$sensor.chip-name, range +/-$sensor.range-mt mT, new sample every $sensor.sample-period-ms ms"

  100.repeat:
    print sensor.read
    sleep --ms=(max 100 sensor.sample-period-ms)
