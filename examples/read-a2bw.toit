// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import log
import tlv493d show *

sda-pin-number := 21    // Set these to match the board in use.
scl-pin-number := 20    // Set these to match the board in use.

// EXPERIMENTAL: the A2BW support has not been tested on hardware.
main:
  bus := i2c.Bus
      --sda=sda-pin-number   // (gpio.Pin sda-pin-number)
      --scl=scl-pin-number   // (gpio.Pin scl-pin-number)
      --frequency=400_000

  if not bus.test Tlv493d-a2bw.I2C-ADDRESS:
    print "No TLV493D-A2BW found at 0x$(%02x Tlv493d-a2bw.I2C-ADDRESS)"
    return

  // A shorter range gives more resolution but saturates at a lower field.
  sensor := Tlv493d-a2bw (bus.device Tlv493d-a2bw.I2C-ADDRESS)
      --range=Tlv493d-a2bw.RANGE-SHORT
  print "$sensor.chip-name, range +/-$sensor.range-mt mT"

  100.repeat:
    print sensor.read
    sleep --ms=(max 100 sensor.sample-period-ms)
