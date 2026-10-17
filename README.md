# toit-tlv493d

Toit driver for the Infineon TLV493D 3D magnetic sensor (X, Y, Z field and
temperature over I2C), plus an optional joystick layer for building a
magnet-in-a-stick input device.

| Variant | Range | I2C address | Status |
|---|---|---|---|
| TLV493D-A1B6 (Adafruit TLV493 breakout) | +/-130 mT | 0x5E (ADDR high), 0x1F (ADDR low) | Written for this chip; see "Status" |
| TLV493D-A2BW | +/-160 mT, selectable shorter ranges | 0x35 (derived, unverified) | **Experimental, untested** |

## Status

- The code was written without access to a Toit compiler or the hardware.
  Run `toit analyze` and expect to fix small things before the first run.
- The A2BW backend has never talked to a real sensor.
- No chip-ID register exists on the A1B6, so the variant is chosen by the class
  you instantiate (`Tlv493dA1b6` or `Tlv493dA2bw`), not detected.
- Reset after power-up: the A1B6 datasheet says the host should issue an I2C
  reset. The procedure is not in the documents used here, so it is not
  implemented. If the sensor misbehaves after a brown-out, power-cycle it.

## Quick start

```toit
import gpio
import i2c
import tlv493d show *

main:
  bus := i2c.Bus --sda=(gpio.Pin 19) --scl=(gpio.Pin 20) --frequency=400_000
  sensor := Tlv493dA1b6 (bus.device Tlv493dA1b6.I2C-ADDRESS)
  while true:
    print sensor.read  // x=0.10 y=-0.20 z=1.30 mT, T=24.5 C
    sleep --ms=100
```

Use `examples/i2c-scan.toit` first if you are unsure of the address.

## Power modes and rate

| Constant | A1B6 | A2BW | Note |
|---|---|---|---|
| `MODE-LOW-POWER` (default) | ~100 Hz | ~97 Hz | |
| `MODE-ULTRA-LOW-POWER` | ~10 Hz | ~6 Hz | Logs a warning: a joystick lags by up to ~100 ms |
| `MODE-MASTER-CONTROLLED` | host-driven | host-driven | Logs a warning; see the datasheet |
| `MODE-POWER-DOWN` | yes | not supported | |

The fast (kHz) mode is deliberately not offered: it needs strict I2C timing
and the /INT line, which most breakout boards do not expose.

Pass the mode to the constructor, or call `set-mode` later:

```toit
sensor := Tlv493dA1b6 device --mode=Tlv493d.MODE-ULTRA-LOW-POWER
```

`sample-period-ms` tells you how often new data appears. Polling faster is
harmless, it just returns the same sample again.

The /INT output shares the SCL pin on the A1B6, so the driver keeps it
disabled. Polling is the intended way to use this driver.

## The joystick layer

`import tlv493d.joystick show *` gives you a `Joystick` that works with either
variant, because it only uses the field in mT.

Like the sensor drivers, it starts **no tasks**. You call `joystick.update`
from your own loop (or one shared housekeeping task). Each call reads the sensor,
updates the state and calls any registered lambdas.

There are three ways to consume the input, because buttons and sticks are
different kinds of signal:

- **State.** `joystick.state` (or the return value of `update`) is the current
  position: `x`, `y` in -1.0..1.0, `magnitude`, `angle`, a 4-way `direction`,
  and `pressed`. Best for continuous things such as steering or a cursor, where
  you want the value *now* and an old value is worthless.
- **Change callback.** `joystick.on-change (:: |state| ...)` runs when the stick
  moved by at least `--min-delta`, and once more on returning to centre. It
  always receives the latest state, never a queue of old ones.
- **Event callbacks.** `joystick.add Joystick.UP (:: ...)` fires once per
  transition: `UP DOWN LEFT RIGHT CENTER PRESS RELEASE`. Direction events use
  hysteresis (enter at 60% deflection, leave at 40%) so a stick hovering at
  the threshold does not chatter.

```toit
joystick := Joystick sensor
joystick.calibrate               // Stick at rest.
joystick.learn-travel            // Push to all limits for 5 s.
joystick.add Joystick.PRESS (:: print "click")
joystick.on-change (:: |state| print state)
while true:
  joystick.update
  sleep --ms=10
```

### Tuning

Defaults for `--travel-mt`, `--press-on-mt` and `--press-off-mt` are guesses.
They depend on your magnet and mechanics. Tilting the stick also disturbs
the Z axis, so push detection usually needs tuning. Use `--swap-xy` and the
`--invert-*` switches to match how the sensor is mounted.

## Sources and attribution

Register layouts, bit positions and conversion factors come from the Infineon
C library [xensiv-3d-magnetic-sensor-tlx493d](https://github.com/Infineon/xensiv-3d-magnetic-sensor-tlx493d)
and the Infineon TLV493D-A1B6 and TLV493D-A2BW datasheets. This is an
independent Toit implementation; no Infineon source code is copied. Where
behaviour is inferred rather than documented, a comment in the source says so.

## License

MIT, see `LICENSE`. Examples are Zero-Clause BSD, see `examples/EXAMPLES_LICENSE`.
