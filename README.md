# Toit driver for the Infineon TLV493D 3D magnetic sensor

Driver for using the Infineon TLV493D 3D magnetic sensor (X, Y, Z field and
temperature over I2C) in Toit, plus an optional joystick layer for building a
magnet-in-a-stick input device.

| Variant | Range | I2C address | Status |
|---|---|---|---|
| TLV493D-A1B6 <br>*(Adafruit TLV493 breakout)* | +/-130 mT | 0x5E (ADDR high),<br> 0x1F (ADDR low) | Written/tested with this chip. |
| TLV493D-A2BW | +/-160 mT, selectable shorter ranges | 0x35 (derived, unverified) | **Experimental, untested** |

## Status

- No chip-ID register exists on the A1B6, so the variant is chosen by the class
  that is instantiated (`Tlv493d-a1b6` or `Tlv493d-a2bw`), not detected.
- Reset after power-up: the A1B6 datasheet says the host should issue an I2C
  reset. The procedure is not in the documents, so it is not implemented. If
  the sensor misbehaves after a brown-out, power-cycle it.
- The A2BW driver has never been tested.

## Quick start

```toit
import gpio
import i2c
import tlv493d show *

main:
  bus := i2c.Bus --sda=19 --scl=20 --frequency=400_000
  sensor := Tlv493d-a1b6 (bus.device Tlv493d-a1b6.I2C-ADDRESS)
  while true:
    reading := sensor.read
    print reading  // x=0.10 y=-0.20 z=1.30 mT, T=24.5 C
    print "x=$(%.2f reading.x) y=$(%.2f reading.y) z=$(%.2f reading.z) mT"
    sleep --ms=100
```

The field values are in mT. `reading.temperature` is in degrees Celsius (null if
temperature measurement is disabled).

Run `examples/i2c-scan.toit` first if the address is uncertain.

## Power modes and rate

| Constant | A1B6 | A2BW | Note |
|---|---|---|---|
| `MODE-LOW-POWER` (default) | ~100 Hz | ~97 Hz | |
| `MODE-ULTRA-LOW-POWER` | ~10 Hz | ~6 Hz | Logs a warning: a joystick lags by up to ~100 ms |
| `MODE-MASTER-CONTROLLED` | host-driven | host-driven | Logs a warning; see the datasheet |
| `MODE-FAST` | continuous, kHz | continuous, kHz | Logs a warning; see below. **Untested, not recommended** |
| `MODE-POWER-DOWN` | yes | not supported | |

Pass the mode to the constructor, or call `set-mode` later:

```toit
sensor := Tlv493d-a1b6 device --mode=Tlv493d.MODE-ULTRA-LOW-POWER
```

`sample-period-ms` is how often new data appears. Polling faster is
harmless, it just returns the same sample again.

> [!WARNING]
> **`MODE-FAST` not recommended**
>
> `MODE-FAST` is available and left to the user to choose. The datasheets call
> for strict I2C timing, a high bus speed (up to 1 MHz) and the /INT line,
> since a readout must not happen during a conversion. The breakout board used
> for testing does not expose /INT, and fast mode has not been tried here. On
> that kind of setup, reads may fail or return inconsistent data (assumption,
> not measured). Boards and hosts with a faster bus and an /INT pin may do
> better. `sample-period-ms` returns 0 in this mode (no fixed period), and the
> joystick layer then paces itself at its 5 ms minimum.

### Interrupt (/INT)

On the tested module, the /INT output is not a separate pin, it shares the SCL
pin. When enabled, the chip pulls SCL low for about 1.5 µs at the end of each
conversion (datasheet: "End-of-Conversion /INT pulse ... 1.5 µs low-active (when
activated)"). The driver keeps it disabled by default. Pass `--interrupt` to the
constructor to enable it:

```toit
sensor := Tlv493d-a1b6 device --interrupt
```

The driver only configures the chip. Wiring a GPIO to the /INT line and
reacting to the pulse is up to the application. This is made available for
boards that route /INT to its own pin, since the pulse signals when a new
sample is ready.  (The bit's polarity comes from Infineon's C library, not the
datasheet.)

Without a dedicated /INT pin, polling is simpler: `read` retries if it collides
with a conversion, and `sample-period-ms` gives the pace. Tapping the pulses
from the SCL line with a spare GPIO is not recommended and untested here: the
line also carries every I2C clock edge, other devices on the bus may see the
pulses, and the Linux kernel driver for this chip advises against the interrupt
on a shared bus ("not recommended, unless timing constraints").

## The joystick layer

`import tlv493d.joystick show *` provides a `Joystick` that works with either
variant, because it only uses the field in mT.

Like the sensor drivers, it starts **no tasks**. The application calls `joystick.update`
from its own loop (or one shared housekeeping task). Each call reads the sensor,
updates the state and calls any registered lambdas.

There are three ways to consume the input, because buttons and sticks are
different kinds of signal:

- **State.** `joystick.state` (or the return value of `update`) is the current
  position: `x`, `y` in -1.0..1.0, `magnitude`, `angle`, a 4-way `direction`,
  and `pressed`. Best for continuous things such as steering or a cursor, where
  the value *now* matters and an old value is worthless.
- **Change callback.** `joystick.on-change (:: |state| ...)` runs when the stick
  moved by at least `--min-delta`, and once more on returning to centre. It
  always receives the latest state, never a queue of old ones.
- **Event callbacks.** `joystick.add Joystick.UP (:: ...)` fires once per
  transition: `UP DOWN LEFT RIGHT CENTER PRESS RELEASE`. Direction events use
  hysteresis (by default enter at 50% deflection, leave at 30%; set with
  `--direction-enter` and `--direction-exit`) so a stick hovering at the
  threshold does not chatter.

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
They depend on the magnet and mechanics. Tilting the stick also disturbs
the Z axis, so push detection usually needs tuning. Use `--swap-xy` and the
`--invert-*` switches to match how the sensor is mounted.

Units: travel and the push thresholds are in mT. The deadzone, `--min-delta` and
the direction thresholds are fractions (0.0 to 1.0) of full deflection.
`learn-travel` takes the reading at `--travel-percentile` (default 0.9) of the
magnitudes seen, not the single largest, so a short spike does not inflate the
travel. Use 1.0 for the largest reading.

## Sources

Register layouts, bit positions and conversion factors come from the Infineon
C library [xensiv-3d-magnetic-sensor-tlx493d](https://github.com/Infineon/xensiv-3d-magnetic-sensor-tlx493d)
and the Infineon TLV493D-A1B6 and TLV493D-A2BW datasheets. This is an
independent Toit implementation; no Infineon source code is copied. Where
behaviour is inferred rather than documented, a comment in the source says so.

## About Toit
One would assume the user knows what Toit is.  If not:
> Toit is a high-level, memory-safe language, with container/VM technology built
> specifically for microcontrollers (not a desktop language port). It gives fast
> iteration (live reloads over Wi-Fi in seconds), robust serviceability, and
> performance that’s far closer to C than typical scripting options on the
> ESP32. [[link](https://toitlang.org/)]
- [Review on Soracom](https://soracom.io/blog/internet-of-microcontrollers-made-easy-with-toit-x-soracom/).
- [Review on eeJournal](https://www.eejournal.com/article/its-time-to-get-toit).
- Toit on [Wikipedia](https://en.wikipedia.org/wiki/Toit).
