// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import math
import .tlv493d

/**
The position of a $Joystick at one moment.
*/
class JoystickState:
  /** Horizontal position, -1.0 to 1.0, after the deadzone is removed. */
  x/float
  /** Vertical position, -1.0 to 1.0, after the deadzone is removed. */
  y/float
  /** Distance from the center, 0.0 to 1.0. */
  magnitude/float
  /** Angle in radians (-PI to PI, 0 pointing along +x), 0.0 when centered. */
  angle/float
  /** One of $Joystick.CENTER, $Joystick.UP, $Joystick.DOWN, $Joystick.LEFT or $Joystick.RIGHT. */
  direction/int
  /** Whether the stick is pushed down. */
  pressed/bool
  /** The Z-axis change (in mT) used for the push detection, after inversion. */
  press-depth-mt/float
  /** The sensor reading this state was computed from. */
  reading/Reading

  constructor --.x --.y --.magnitude --.angle --.direction --.pressed --.press-depth-mt --.reading:

  stringify -> string:
    return "x=$(%.2f x) y=$(%.2f y) mag=$(%.2f magnitude) dir=$(Joystick.direction-name direction) pressed=$pressed"

/**
A magnet joystick built on a TLV493D sensor.

The sensor sits under a stick or ball with a magnet in it.  Tilting the stick
  moves the magnet and changes the field on the X and Y axes; pushing it down
  changes the field on the Z axis.  This class turns that into a normalized
  stick position, a 4-way direction with hysteresis, and a push button.

It works with any $Tlv493d: the $Tlv493d-a1b6 and the (experimental)
  $Tlv493d-a2bw look the same to it, because everything is computed in mT.

# Polling, not tasks
Like the sensor drivers, this class starts no tasks.  Call $update from your
  own loop, at least as often as the sensor produces samples (see
  $Tlv493d.sample-period-ms).  Each call reads the sensor, updates the
  $state and calls the registered lambdas before it returns.  Polling
  faster than the sensor's rate is harmless: the same sample is simply seen
  again, and nothing fires twice because the state has not changed.

# Three ways to consume input
- *Read the state:* $state, or the return value of $update, is the latest
  position.  This suits continuous values such as steering or cursor motion.
- *Change callback:* $on-change is called when the stick has moved by a
  noticeable amount.  It always receives the latest state, never a backlog.
- *Event callbacks:* $add registers a lambda for discrete events such as
  $UP or $PRESS.  These fire once per transition.

# Example
```
joystick := Joystick sensor
joystick.calibrate  // Stick at rest.
joystick.add Joystick.PRESS (:: print "click")
joystick.on-change (:: |state| print "x=$state.x y=$state.y")
while true:
  joystick.update
  sleep --ms=10
```
*/
class Joystick:
  /** Event and direction: the stick returned to the center zone. */
  static CENTER ::= 0
  /** Event and direction: the stick moved up (positive y). */
  static UP ::= 1
  /** Event and direction: the stick moved down (negative y). */
  static DOWN ::= 2
  /** Event and direction: the stick moved left (negative x). */
  static LEFT ::= 3
  /** Event and direction: the stick moved right (positive x). */
  static RIGHT ::= 4
  /** Event: the stick was pushed down. */
  static PRESS ::= 5
  /** Event: the stick was released. */
  static RELEASE ::= 6

  sensor_/Tlv493d
  center-x_/float := 0.0
  center-y_/float := 0.0
  center-z_/float := 0.0
  travel-mt_/float := 15.0
  deadzone_/float := 0.1
  // Fractions of full deflection at which a direction is entered or left.
  // Entering at a higher value than leaving gives hysteresis.
  direction-enter_/float := 0.5
  direction-exit_/float := 0.3
  travel-percentile_/float := 0.9
  min-delta_/float := 0.02
  press-on-mt_/float := 8.0
  press-off-mt_/float := 5.0
  swap-xy_/bool := false
  invert-x_/bool := false
  invert-y_/bool := false
  invert-z_/bool := false

  lambdas_/Map := {:}
  change-lambda_/Lambda? := null
  direction_/int := CENTER
  pressed_/bool := false
  last-x_/float := 0.0
  last-y_/float := 0.0
  state_/JoystickState? := null

  /**
  Constructs a joystick on top of the given sensor.

  Call $calibrate before use, with the stick at rest.

  The $travel-mt is the field change, in mT, that corresponds to full
    deflection of the stick.  It depends on your magnet and mechanics.  Use
    $learn-travel to measure it.  The default is a guess.

  The $deadzone is the fraction (0.0 to less than 1.0) of full deflection
    around the center that is reported as no movement.

  The $min-delta is the smallest change in x or y (in normalized units) that
    triggers the $on-change lambda.

  The $direction-enter and $direction-exit are the fractions (0.0 to 1.0) of
    full deflection at which a direction event starts and ends.  The enter
    value must be above the exit value; the gap between them is the hysteresis.

  The $travel-percentile (above 0.0, up to 1.0) is the share of the readings
    that $learn-travel keeps below its result.  The default of 0.9 ignores the
    largest 10% of readings, so a short spike (for example from pushing the
    stick down) does not inflate the travel.  Use 1.0 for the single largest
    reading.

  The $press-on-mt and $press-off-mt are the Z-field changes at which a push
    is detected and released.  Keep $press-off-mt below $press-on-mt for
    hysteresis.  Tilting also disturbs the Z axis, so these usually need tuning.
    The defaults are guesses.

  Use $swap-xy, $invert-x, $invert-y and $invert-z to match the orientation
    in which the sensor is mounted.
  */
  constructor .sensor_
      --travel-mt/float=15.0
      --deadzone/float=0.1
      --min-delta/float=0.02
      --direction-enter/float=0.5
      --direction-exit/float=0.3
      --travel-percentile/float=0.9
      --press-on-mt/float=8.0
      --press-off-mt/float=5.0
      --swap-xy/bool=false
      --invert-x/bool=false
      --invert-y/bool=false
      --invert-z/bool=false:
    if travel-mt <= 0.0: throw "INVALID_ARGUMENT"
    if deadzone < 0.0 or deadzone >= 1.0: throw "INVALID_ARGUMENT"
    if direction-exit < 0.0 or direction-enter > 1.0 or direction-exit >= direction-enter: throw "INVALID_ARGUMENT"
    if travel-percentile <= 0.0 or travel-percentile > 1.0: throw "INVALID_ARGUMENT"
    travel-mt_ = travel-mt
    deadzone_ = deadzone
    min-delta_ = min-delta
    direction-enter_ = direction-enter
    direction-exit_ = direction-exit
    travel-percentile_ = travel-percentile
    press-on-mt_ = press-on-mt
    press-off-mt_ = press-off-mt
    swap-xy_ = swap-xy
    invert-x_ = invert-x
    invert-y_ = invert-y
    invert-z_ = invert-z

  /** Returns a short name for the given direction or event number. */
  static direction-name direction/int -> string:
    if direction == CENTER: return "center"
    if direction == UP: return "up"
    if direction == DOWN: return "down"
    if direction == LEFT: return "left"
    if direction == RIGHT: return "right"
    if direction == PRESS: return "press"
    if direction == RELEASE: return "release"
    return "unknown"

  /**
  Measures the resting position.

  Keep the stick untouched while this runs.  It averages $samples readings.
    The pace follows the sensor's sample rate.
  */
  calibrate --samples/int=32 -> none:
    if samples < 1: throw "INVALID_ARGUMENT"
    sum-x := 0.0
    sum-y := 0.0
    sum-z := 0.0
    delay-ms := max 5 sensor_.sample-period-ms
    samples.repeat:
      reading := sensor_.read
      sum-x += reading.x
      sum-y += reading.y
      sum-z += reading.z
      sleep --ms=delay-ms
    center-x_ = sum-x / samples
    center-y_ = sum-y / samples
    center-z_ = sum-z / samples
    direction_ = CENTER
    pressed_ = false
    last-x_ = 0.0
    last-y_ = 0.0
    state_ = null

  /**
  Measures the field change at full deflection and uses it as the travel.

  Call $calibrate first.  Then, during the $duration, push the stick to its
    limits in all directions.  Returns the new travel in mT.

  The result is not the single largest reading but the one at the constructor's
    travel-percentile, so that short spikes are ignored.
  */
  learn-travel --duration/Duration=(Duration --s=5) -> float:
    deadline := Time.monotonic-us + duration.in-us
    magnitudes := []
    delay-ms := max 5 sensor_.sample-period-ms
    while Time.monotonic-us < deadline:
      reading := sensor_.read
      dx := reading.x - center-x_
      dy := reading.y - center-y_
      magnitudes.add (math.sqrt (dx * dx + dy * dy))
      sleep --ms=delay-ms
    if magnitudes.is-empty: throw "TLV493D: no samples while learning travel"
    sorted := magnitudes.sort
    index := ((sorted.size - 1) * travel-percentile_).round
    value := sorted[index]
    if value < 1.0: throw "TLV493D: no movement detected while learning travel"
    travel-mt_ = value
    return value

  /** The most recent state, or null if $update has not been called yet. */
  state -> JoystickState?:
    return state_

  /**
  Sets the lambda called when the stick moved noticeably.

  The $lambda is called with one argument, the $JoystickState:
  ```
  joystick.on-change (:: |state| print state)
  ```
  It fires when x or y changed by at least the constructor's min-delta since
    the last time it fired, and once more when the stick returns to the center.
    Pass null to remove it.
  */
  on-change lambda/Lambda? -> none:
    change-lambda_ = lambda

  /**
  Registers a $lambda, called without arguments, for the given $event.

  The $event is one of $CENTER, $UP, $DOWN, $LEFT, $RIGHT, $PRESS or $RELEASE.
    Only one lambda is kept per event; adding another replaces it.
  */
  add event/int lambda/Lambda -> none:
    if event < CENTER or event > RELEASE: throw "INVALID_ARGUMENT"
    lambdas_[event] = lambda

  /** Removes the lambda registered for the given $event, if any. */
  remove event/int -> none:
    lambdas_.remove event

  /**
  Reads the sensor, updates the state and calls the registered lambdas.

  Returns the new state.  Throws if the sensor cannot be read.
  */
  update -> JoystickState:
    reading := sensor_.read
    ax := reading.x - center-x_
    ay := reading.y - center-y_
    if swap-xy_:
      tmp := ax
      ax = ay
      ay = tmp
    if invert-x_: ax = -ax
    if invert-y_: ay = -ay
    nx := ax / travel-mt_
    ny := ay / travel-mt_

    // Radial deadzone, then rescale so that the edge of the deadzone is 0.
    magnitude := math.sqrt (nx * nx + ny * ny)
    if magnitude < deadzone_:
      nx = 0.0
      ny = 0.0
      magnitude = 0.0
    else:
      scaled := min 1.0 ((magnitude - deadzone_) / (1.0 - deadzone_))
      factor := scaled / magnitude
      nx *= factor
      ny *= factor
      magnitude = scaled

    // Direction, with hysteresis.
    new-direction := direction_
    if magnitude >= direction-enter_:
      if nx.abs >= ny.abs:
        new-direction = nx > 0.0 ? RIGHT : LEFT
      else:
        new-direction = ny > 0.0 ? UP : DOWN
    else if magnitude < direction-exit_:
      new-direction = CENTER

    // Push, with hysteresis.
    depth := reading.z - center-z_
    if invert-z_: depth = -depth
    new-pressed := pressed_
    if pressed_:
      if depth < press-off-mt_: new-pressed = false
    else:
      if depth > press-on-mt_: new-pressed = true

    angle := magnitude == 0.0 ? 0.0 : (math.atan2 ny nx)
    state := JoystickState
        --x=nx
        --y=ny
        --magnitude=magnitude
        --angle=angle
        --direction=new-direction
        --pressed=new-pressed
        --press-depth-mt=depth
        --reading=reading
    state_ = state

    // Fire events after the state is stored, so lambdas can read it.
    if new-direction != direction_:
      direction_ = new-direction
      lambdas_.get new-direction --if-present=: it.call
    if new-pressed != pressed_:
      pressed_ = new-pressed
      lambdas_.get (new-pressed ? PRESS : RELEASE) --if-present=: it.call
    if change-lambda_ != null:
      moved := (nx - last-x_).abs >= min-delta_ or (ny - last-y_).abs >= min-delta_
      returned-to-center := magnitude == 0.0 and (last-x_ != 0.0 or last-y_ != 0.0)
      if moved or returned-to-center:
        last-x_ = nx
        last-y_ = ny
        change-lambda_.call state
    return state

  stringify -> string:
    current := state_
    if current == null: return "Joystick (no state yet)"
    return "Joystick $current"
