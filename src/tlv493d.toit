// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import log
import serial.device as serial

/**
Toit driver for the Infineon TLV493D 3D magnetic sensor family.

Two variants are supported through a common interface:
- $Tlv493d-a1b6: TLV493D-A1B6 (+/-130 mT, I2C address 0x5E or 0x1F).  Tested.
- $Tlv493d-a2bw: TLV493D-A2BW (+/-160 mT, selectable ranges, I2C address 0x35).
  EXPERIMENTAL and untested on hardware.

Both return the magnetic flux density in mT on three axes ($Reading), plus an
  optional die temperature.  The driver is stateless with respect to tasks: it
  never starts a task or calls user code.  Poll it with $Tlv493d.read from
  the application's own loop (see $Tlv493d.sample-period-ms for how often).

# Sources
Register layouts, bit positions and conversion factors were taken from the
  Infineon C library "xensiv-3d-magnetic-sensor-tlx493d" (MIT licensed) and the
  Infineon datasheets.  Where something is an inference rather than a
  documented fact, a comment says so.  This is an independent Toit
  implementation; no Infineon code is copied.
*/

/** Returns the parity (0 or 1) of the set bits in the low 8 bits of $value. */
parity_ value/int -> int:
  v := value & 0xff
  v ^= v >> 4
  v ^= v >> 2
  v ^= v >> 1
  return v & 1

/** Converts the unsigned bits-wide $value to a two's complement integer. */
sign-extend_ value/int bits/int -> int:
  if value >= (1 << (bits - 1)): return value - (1 << bits)
  return value

/**
One measurement from a TLV493D.

The field values are in mT.  The $temperature is in degrees Celsius, or null if
  temperature measurement is disabled.  The $frame is the sensor's 2-bit
  conversion counter (0-3).  It is informative only: it wraps after four
  conversions, so it cannot reliably detect repeated samples.
*/
class Reading:
  x/float
  y/float
  z/float
  temperature/float?
  frame/int

  constructor --.x --.y --.z --.temperature --.frame:

  stringify -> string:
    t := temperature == null ? "n/a" : "$(%.1f temperature) C"
    return "x=$(%.2f x) y=$(%.2f y) z=$(%.2f z) mT, T=$t"

/**
Common interface of the supported TLV493D variants.

Instantiate one of the concrete classes, $Tlv493d-a1b6 or $Tlv493d-a2bw.
*/
abstract class Tlv493d:
  /**
  Power-down.  No measurements.  Not supported by $Tlv493d-a2bw.
  */
  static MODE-POWER-DOWN ::= 0
  /**
  Ultra-low-power mode, roughly 10 Hz on the A1B6 (about 6 Hz on the A2BW).

  Lowest power, but a joystick on top of this feels laggy: a movement can take
    up to ~100 ms to show up.  See $Tlv493d.sample-period-ms.
  */
  static MODE-ULTRA-LOW-POWER ::= 1
  /**
  Low-power mode, roughly 100 Hz on the A1B6 (about 97 Hz on the A2BW).

  This is the default.
  */
  static MODE-LOW-POWER ::= 2
  /**
  Master-controlled mode.  A conversion is started by the host.

  Reads return the previous conversion.  The sample rate is whatever the
    application polls at.  See the datasheet for the exact trigger behavior.
  */
  static MODE-MASTER-CONTROLLED ::= 3
  /**
  Fast mode.  The sensor converts continuously, at several kHz.

  Per the datasheets this mode needs strict I2C timing, a high bus speed (up
    to 1 MHz) and the /INT line, because a readout must not happen during a
    conversion.  Whether it works at all depends on the board and the host,
    so it is the application's choice.  A warning is logged when selected.
    Magnetic noise is also higher than in the low-power modes (an assumption
    to verify: the noise figure quoted in the datasheet is 0.1 mT rms).
  */
  static MODE-FAST ::= 4

  dev_/serial.Device
  logger_/log.Logger
  mode_/int := MODE-LOW-POWER

  constructor .dev_ .logger_:

  /** The name of the chip variant, for example "TLV493D-A1B6". */
  abstract chip-name -> string

  /** The nominal linear measuring range, in mT, of each axis (+/-). */
  abstract range-mt -> float

  /**
  Reads one sample.

  Retries a few times if the sensor is in the middle of a conversion.  Throws
    if no consistent sample could be obtained.
  */
  abstract read -> Reading

  /**
  Whether the factory fuse parity flag reports a healthy sensor.

  Reads the sensor to find out.
  */
  abstract is-functional -> bool

  /**
  Switches to the given $mode.

  One of $MODE-POWER-DOWN, $MODE-ULTRA-LOW-POWER, $MODE-LOW-POWER,
    $MODE-MASTER-CONTROLLED or $MODE-FAST.
  */
  abstract set-mode mode/int -> none

  /** The currently selected power mode. */
  mode -> int:
    return mode_

  /**
  The time between two new samples in the current mode, in ms.

  Returns 0 for $MODE-MASTER-CONTROLLED (rate set by the caller), for
    $MODE-FAST (continuous conversion, no fixed period) and for
    $MODE-POWER-DOWN (no samples).  Polling faster than this just returns
    the same sample again.
  */
  sample-period-ms -> int:
    if mode_ == MODE-ULTRA-LOW-POWER: return 100
    if mode_ == MODE-LOW-POWER: return 10
    return 0

  warn-about-mode_ mode/int -> none:
    if mode == MODE-ULTRA-LOW-POWER:
      logger_.warn "ultra-low-power mode (~10 Hz): a joystick built on this will lag by up to ~100 ms"
    else if mode == MODE-MASTER-CONTROLLED:
      logger_.warn "master-controlled mode: regular polling is required, see the datasheet"
    else if mode == MODE-FAST:
      logger_.warn "fast mode: the datasheet calls for strict I2C timing, a high bus speed (up to 1 MHz) and the /INT line; reads may fail or return inconsistent data without them"

/**
Driver for the TLV493D-A1B6.

Tested on an Adafruit TLV493 breakout.  The I2C address is selected by the
  state of the ADDR pin at power-up: $I2C-ADDRESS (0x5E) or $I2C-ADDRESS-ALT
  (0x1F).

# Notes
The /INT output shares the SCL pin on this chip.  By default the driver keeps
  the interrupt disabled, which is all that polling needs.  Pass `--interrupt`
  to the constructor to enable it; see there for the caveats.

The datasheet asks the host to issue an I2C reset after power-up.  The
  reset procedure is not documented in the sources used for this driver, and
  the Infineon library does not implement it for this chip either (its
  reference boards are power-cycled instead).  If the sensor behaves oddly
  after a brown-out, power-cycle it.
*/
class Tlv493d-a1b6 extends Tlv493d:
  /** I2C address when the ADDR pin is high at power-up. */
  static I2C-ADDRESS ::= 0x5E
  /** I2C address when the ADDR pin is low at power-up. */
  static I2C-ADDRESS-ALT ::= 0x1F

  // Frame layout (10 bytes, read without a register address).
  static FRAME-SIZE_ ::= 10
  static MT-PER-LSB_ ::= 0.098
  static TEMP-OFFSET_ ::= 340.0
  static TEMP-MULTIPLIER_ ::= 1.10
  static TEMP-REFERENCE_ ::= 25.0

  // Masks in the read frame.
  static CHANNEL-MASK_ ::= 0b00000011  // Byte 3.
  static FRAME-COUNTER-SHIFT_ ::= 2    // Byte 3, bits 3:2.
  static FUSE-PARITY-FLAG_ ::= 0b00100000  // Byte 5, FF.

  // Write frame (4 bytes): [reserved, MOD1, reserved, MOD2].
  static MOD1-PARITY_ ::= 0b10000000
  static MOD1-INT-DISABLE_ ::= 0b00000100
  static MOD1-FAST_ ::= 0b00000010
  static MOD1-LOW-POWER_ ::= 0b00000001
  static MOD2-TEMP-DISABLE_ ::= 0b10000000
  static MOD2-LP-PERIOD_ ::= 0b01000000
  static MOD2-PARITY-TEST_ ::= 0b00100000

  address-select_/int := 0
  temperature-enabled_/bool := true
  interrupt-enabled_/bool := false
  reserved-mod1_/int := 0
  reserved-byte2_/int := 0
  reserved-mod2_/int := 0

  /**
  Constructs the driver for the given I2C $device and configures the sensor.

  The $mode defaults to $Tlv493d.MODE-LOW-POWER (about 100 Hz).  Choose
    $Tlv493d.MODE-ULTRA-LOW-POWER (about 10 Hz) to save power; a warning is
    logged because a joystick then responds slowly.  $Tlv493d.MODE-FAST is
    also available (continuous conversion); a warning is logged, as it needs
    strict I2C timing, a high bus speed and /INT.

  The $address-select is the 2-bit IICADR value (0-3) written to the sensor.
    The default, 0, corresponds to the addresses $I2C-ADDRESS and
    $I2C-ADDRESS-ALT.  Leave it unless the sensor is known to have been reprogrammed.

  If $temperature is false the temperature conversion is skipped, which the
    datasheet says reduces the supply current by about 25%.  The
    $Reading.temperature is then null.

  If $interrupt is true the chip's /INT output is enabled: at the end of each
    conversion it pulls its /INT line low for about 1.5 us.  On the A1B6 that
    line is the SCL pin itself, so enabling it puts these pulses on the I2C
    clock line.  Only enable it with a clear plan for using it, for example
    on a board that routes /INT to its own pin.  The driver only configures the
    chip; connecting a GPIO and reacting to the pulse is up to the
    application.  The default is false.
  */
  constructor device/serial.Device
      --mode/int=Tlv493d.MODE-LOW-POWER
      --address-select/int=0
      --temperature/bool=true
      --interrupt/bool=false
      --logger/log.Logger=log.default:
    address-select_ = address-select
    temperature-enabled_ = temperature
    interrupt-enabled_ = interrupt
    super device (logger.with-name "tlv493d-a1b6")

    if address-select < 0 or address-select > 3: throw "INVALID_ARGUMENT"
    // The write registers have reserved fields that must be written back with
    // the factory values found in the read registers (Infineon library:
    // "set WRITE reserved register values from READ reserved register values").
    frame := read-frame_
    reserved-mod1_ = (frame[7] >> 3) & 0b11
    reserved-byte2_ = frame[8]
    reserved-mod2_ = frame[9] & 0b00011111
    write-config_ mode
    mode_ = mode
    warn-about-mode_ mode
    if interrupt: logger_.info "/INT enabled: the chip pulses the /INT (SCL) line after each conversion"
    if mode != Tlv493d.MODE-POWER-DOWN:
      sleep --ms=(max 20 sample-period-ms)
      if not is-functional:
        logger_.warn "fuse parity flag not set: sensor may not be healthy"

  chip-name -> string:
    return "TLV493D-A1B6"

  range-mt -> float:
    return 130.0

  set-mode mode/int -> none:
    write-config_ mode
    mode_ = mode
    warn-about-mode_ mode

  is-functional -> bool:
    frame := read-frame_
    return (frame[5] & FUSE-PARITY-FLAG_) != 0

  read -> Reading:
    last-error := null
    5.repeat:
      frame/ByteArray? := null
      // An occasional I2C error (for example a NACK) is retried, as it can be a
      // transient bus glitch.  If every attempt fails the last error is thrown.
      last-error = catch: frame = read-frame_
      // A non-zero channel field means a conversion is in progress and the
      // data may be corrupt (the chip has no shadow registers).
      if frame != null and (frame[3] & CHANNEL-MASK_) == 0: return decode_ frame
      if last-error != null: logger_.debug "read failed, retrying: $last-error"
      sleep --ms=2
    if last-error != null: throw last-error
    throw "TLV493D: no consistent sample"

  read-frame_ -> ByteArray:
    frame := dev_.read FRAME-SIZE_
    if frame.size != FRAME-SIZE_: throw "TLV493D: short read"
    return frame

  decode_ frame/ByteArray -> Reading:
    x := sign-extend_ ((frame[0] << 4) | (frame[4] >> 4)) 12
    y := sign-extend_ ((frame[1] << 4) | (frame[4] & 0x0f)) 12
    z := sign-extend_ ((frame[2] << 4) | (frame[5] & 0x0f)) 12
    temperature/float? := null
    if temperature-enabled_:
      raw := sign-extend_ (((frame[3] >> 4) << 8) | frame[6]) 12
      temperature = ((raw.to-float - TEMP-OFFSET_) * TEMP-MULTIPLIER_) + TEMP-REFERENCE_
    return Reading
        --x=(x * MT-PER-LSB_)
        --y=(y * MT-PER-LSB_)
        --z=(z * MT-PER-LSB_)
        --temperature=temperature
        --frame=((frame[3] >> FRAME-COUNTER-SHIFT_) & 0b11)

  write-config_ mode/int -> none:
    fast := 0
    low := 0
    lp-period := 0
    if mode == Tlv493d.MODE-POWER-DOWN:
      // All zero.
    else if mode == Tlv493d.MODE-ULTRA-LOW-POWER:
      low = 1
    else if mode == Tlv493d.MODE-LOW-POWER:
      low = 1
      lp-period = 1
    else if mode == Tlv493d.MODE-MASTER-CONTROLLED:
      fast = 1
      low = 1
      lp-period = 1
    else if mode == Tlv493d.MODE-FAST:
      fast = 1
    else:
      throw "INVALID_ARGUMENT"
    mod1 := (address-select_ << 5) | (reserved-mod1_ << 3) | (fast << 1) | low
    // INT bit: 1 disables the interrupt, 0 enables it (polarity from the
    // Infineon library's INT_ENABLE/INT_DISABLE values).
    if not interrupt-enabled_: mod1 |= MOD1-INT-DISABLE_
    mod2 := (lp-period << 6) | MOD2-PARITY-TEST_ | reserved-mod2_
    if not temperature-enabled_: mod2 |= MOD2-TEMP-DISABLE_
    bytes := ByteArray 4
    bytes[1] = mod1
    bytes[2] = reserved-byte2_
    bytes[3] = mod2
    // The four write bytes, including the parity bit P, must have odd parity
    // (derived from the Infineon library's parity routine).
    if (parity_ (bytes[0] ^ bytes[1] ^ bytes[2] ^ bytes[3])) == 0:
      bytes[1] |= MOD1-PARITY_
    dev_.write bytes

/**
Driver for the TLV493D-A2BW.  EXPERIMENTAL: not tested on hardware.

The register layout was transcribed from the Infineon C library.  Treat every
  result with suspicion until it has been checked against a real sensor.
  Findings from real hardware are welcome.

The default I2C address is $I2C-ADDRESS.  The sensor supports four addresses,
  selected through the 2-bit IICADR field; $I2C-ADDRESSES lists them in
  IICADR order.  These values are derived (7-bit form of the 8-bit addresses
  0x6A, 0x44, 0xF0 and 0x88 in the Infineon library) and not verified.
*/
class Tlv493d-a2bw extends Tlv493d:
  /** Default I2C address. */
  static I2C-ADDRESS ::= 0x35
  /** The four possible I2C addresses, indexed by IICADR (derived, unverified). */
  static I2C-ADDRESSES ::= [0x35, 0x22, 0x78, 0x44]

  /** Full range, +/-160 mT, 7.7 LSB/mT. */
  static RANGE-FULL ::= 0
  /** Short range, +/-100 mT, 15.4 LSB/mT. */
  static RANGE-SHORT ::= 1
  /** Extra-short range, +/-50 mT, 30.8 LSB/mT. */
  static RANGE-EXTRA-SHORT ::= 2

  static FRAME-SIZE_ ::= 7
  static ALL-REGISTERS-SIZE_ ::= 23

  static REG-CONFIG_ ::= 0x10
  static REG-MOD1_ ::= 0x11
  static REG-RESERVED_ ::= 0x12
  static REG-MOD2_ ::= 0x13
  static REG-CONFIG2_ ::= 0x14
  static REG-VERSION_ ::= 0x16

  // CONFIG (0x10): DT[7] AM[6] TRIG[5:4] X2[3] TL_mag[2:1] CP[0].
  static CONFIG-DT_ ::= 0b10000000
  static CONFIG-AM_ ::= 0b01000000
  static CONFIG-TRIG-MASK_ ::= 0b00110000
  static CONFIG-X2_ ::= 0b00001000
  static CONFIG-CP_ ::= 0b00000001
  // MOD1 (0x11): FP[7] IICADR[6:5] PR[4] CA[3] INT[2] MODE[1:0].
  static MOD1-FP_ ::= 0b10000000
  static MOD1-PR_ ::= 0b00010000
  static MOD1-CA_ ::= 0b00001000
  static MOD1-INT_ ::= 0b00000100
  static MOD1-MODE-MASK_ ::= 0b00000011
  // MOD2 (0x13): PRD[7].
  static MOD2-PRD_ ::= 0b10000000
  // CONFIG2 (0x14): X4[0].
  static CONFIG2-X4_ ::= 0b00000001

  // MODE field values (from the Infineon library).
  static MODE-BITS-LOW-POWER_ ::= 0b00
  static MODE-BITS-MASTER-CONTROLLED_ ::= 0b01
  static MODE-BITS-FAST_ ::= 0b11

  address-select_/int := 0
  temperature-enabled_/bool := true
  interrupt-enabled_/bool := false
  range_/int := RANGE-FULL
  config_/int := 0
  mod1_/int := 0
  mod2_/int := 0
  config2_/int := 0
  reserved-12_/int := 0

  /**
  Constructs the driver for the given I2C $device and configures the sensor.

  The $mode defaults to $Tlv493d.MODE-LOW-POWER (about 97 Hz).
    $Tlv493d.MODE-POWER-DOWN is not supported on this variant and throws.
    $Tlv493d.MODE-ULTRA-LOW-POWER selects the ~6 Hz low-power rate and logs a
    warning, because a joystick then responds very slowly.
    $Tlv493d.MODE-FAST is available too; it logs a warning (strict I2C
    timing, up to 1 MHz bus and /INT are called for).

  The $range is one of $RANGE-FULL, $RANGE-SHORT or $RANGE-EXTRA-SHORT.  A
    shorter range has a higher resolution but saturates at a lower field.

  The $address-select is the 2-bit IICADR value (0-3) that matches the address
    the sensor responds at; see $I2C-ADDRESSES.

  If $interrupt is true the chip's /INT output is enabled and pulses at the end
    of each conversion.  The driver only configures the chip; connecting a GPIO
    and reacting to the pulse is up to the application.  The default is false.
  */
  constructor device/serial.Device
      --mode/int=Tlv493d.MODE-LOW-POWER
      --range/int=RANGE-FULL
      --address-select/int=0
      --temperature/bool=true
      --interrupt/bool=false
      --logger/log.Logger=log.default:
    address-select_ = address-select
    temperature-enabled_ = temperature
    interrupt-enabled_ = interrupt
    super device (logger.with-name "tlv493d-a2bw")

    if address-select < 0 or address-select > 3: throw "INVALID_ARGUMENT"
    if range < RANGE-FULL or range > RANGE-EXTRA-SHORT: throw "INVALID_ARGUMENT"
    logger_.warn "EXPERIMENTAL: the A2BW support has not been tested on hardware"

    regs := dev_.read ALL-REGISTERS-SIZE_
    if regs.size != ALL-REGISTERS-SIZE_: throw "TLV493D: short read"
    reserved-12_ = regs[REG-RESERVED_]
    config_ = regs[REG-CONFIG_]
    mod1_ = regs[REG-MOD1_]
    mod2_ = regs[REG-MOD2_]
    config2_ = 0  // Write-only register.
    chip-id := (regs[5] >> 4) & 0b11
    if chip-id != address-select:
      logger_.warn "sensor ID field $chip-id does not match address-select $address-select"
    logger_.debug "type/hardware version byte: 0x$(%02x regs[REG-VERSION_])"

    // Follow the Infineon default configuration: collision avoidance on,
    // interrupt as requested (disabled by default), 1-byte read protocol,
    // matching IICADR.
    cleared := mod1_ & ~(MOD1-FP_ | 0b01100000 | MOD1-CA_ | MOD1-INT_)
    mod1_ = cleared | (address-select << 5) | MOD1-PR_
    if not interrupt: mod1_ |= MOD1-INT_
    write-mod1_
    set-measurement_
    set-range range
    set-mode mode

  chip-name -> string:
    return "TLV493D-A2BW"

  range-mt -> float:
    if range_ == RANGE-SHORT: return 100.0
    if range_ == RANGE-EXTRA-SHORT: return 50.0
    return 160.0

  /** The sensitivity of the current range, in LSB per mT. */
  sensitivity_ -> float:
    if range_ == RANGE-SHORT: return 15.4
    if range_ == RANGE-EXTRA-SHORT: return 30.8
    return 7.7

  /**
  Selects the measuring range.

  One of $RANGE-FULL, $RANGE-SHORT or $RANGE-EXTRA-SHORT.
  */
  set-range range/int -> none:
    if range < RANGE-FULL or range > RANGE-EXTRA-SHORT: throw "INVALID_ARGUMENT"
    x2 := range >= RANGE-SHORT
    x4 := range == RANGE-EXTRA-SHORT
    config_ = x2 ? (config_ | CONFIG-X2_) : (config_ & ~CONFIG-X2_)
    config2_ = x4 ? (config2_ | CONFIG2-X4_) : (config2_ & ~CONFIG2-X4_)
    write-config_
    write-config2_
    range_ = range

  set-mode mode/int -> none:
    mode-bits := 0
    prd := 0
    if mode == Tlv493d.MODE-LOW-POWER:
      mode-bits = MODE-BITS-LOW-POWER_
      prd = 0  // 97 Hz.
    else if mode == Tlv493d.MODE-ULTRA-LOW-POWER:
      mode-bits = MODE-BITS-LOW-POWER_
      prd = 1  // 6 Hz.
    else if mode == Tlv493d.MODE-MASTER-CONTROLLED:
      mode-bits = MODE-BITS-MASTER-CONTROLLED_
    else if mode == Tlv493d.MODE-FAST:
      mode-bits = MODE-BITS-FAST_
    else if mode == Tlv493d.MODE-POWER-DOWN:
      throw "UNSUPPORTED: power-down is not implemented for the A2BW"
    else:
      throw "INVALID_ARGUMENT"
    mod1_ = (mod1_ & ~MOD1-MODE-MASK_) | mode-bits
    mod2_ = (mod2_ & ~MOD2-PRD_) | (prd << 7)
    write-mod1_
    mode_ = mode
    warn-about-mode_ mode
    sleep --ms=(max 20 sample-period-ms)

  sample-period-ms -> int:
    if mode_ == Tlv493d.MODE-ULTRA-LOW-POWER: return 170
    if mode_ == Tlv493d.MODE-LOW-POWER: return 11
    return 0

  is-functional -> bool:
    regs := dev_.read ALL-REGISTERS-SIZE_
    fuse-ok := (regs[6] & 0b01000000) != 0
    config-ok := (regs[6] & 0b00100000) != 0
    return fuse-ok and config-ok

  read -> Reading:
    4.repeat:
      frame := dev_.read FRAME-SIZE_
      if frame.size != FRAME-SIZE_: throw "TLV493D: short read"
      // Bus parity: odd parity over bytes 0-5 must match bit P (byte 6, bit 7).
      parity := 0
      6.repeat: parity ^= frame[it]
      expected := (parity_ parity) ^ 1
      if expected == (frame[6] >> 7): return decode_ frame
      sleep --ms=1
    throw "TLV493D: no consistent sample"

  decode_ frame/ByteArray -> Reading:
    x := sign-extend_ ((frame[0] << 4) | (frame[4] >> 4)) 12
    y := sign-extend_ ((frame[1] << 4) | (frame[4] & 0x0f)) 12
    z := sign-extend_ ((frame[2] << 4) | (frame[5] & 0x0f)) 12
    sensitivity := sensitivity_
    temperature/float? := null
    if temperature-enabled_:
      // 10-bit value, two implicit low bits (Infineon library: shift by 2).
      raw := (sign-extend_ ((frame[3] << 2) | (frame[5] >> 6)) 10) * 4
      temperature = ((raw.to-float - 1180.0) * 0.24) + 25.0
    return Reading
        --x=(x.to-float / sensitivity)
        --y=(y.to-float / sensitivity)
        --z=(z.to-float / sensitivity)
        --temperature=temperature
        --frame=(frame[6] & 0b11)

  set-measurement_ -> none:
    // DT = 0: Bx, By, Bz and temperature.  DT = 1: no temperature.  AM = 0.
    config_ &= ~(CONFIG-AM_ | CONFIG-TRIG-MASK_)
    config_ = temperature-enabled_ ? (config_ & ~CONFIG-DT_) : (config_ | CONFIG-DT_)
    write-config_

  write-config_ -> none:
    // CP is the even parity bit over the rest of the CONFIG register.
    config_ = (config_ & ~CONFIG-CP_) | (parity_ (config_ & ~CONFIG-CP_))
    bytes := ByteArray 2
    bytes[0] = REG-CONFIG_
    bytes[1] = config_
    dev_.write bytes

  write-config2_ -> none:
    bytes := ByteArray 2
    bytes[0] = REG-CONFIG2_
    bytes[1] = config2_
    dev_.write bytes

  write-mod1_ -> none:
    // FP is the odd parity bit over MOD1 (without FP) xor the PRD bit of MOD2.
    body := mod1_ & ~MOD1-FP_
    fuse-parity := (parity_ (body ^ (mod2_ & MOD2-PRD_))) ^ 1
    mod1_ = body | (fuse-parity << 7)
    bytes := ByteArray 4
    bytes[0] = REG-MOD1_
    bytes[1] = mod1_
    bytes[2] = reserved-12_
    bytes[3] = mod2_
    dev_.write bytes
