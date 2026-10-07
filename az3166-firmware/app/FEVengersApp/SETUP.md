# FEVengersApp - Setup Notes

> Generated with AI assistance (Claude Sonnet 5, model id: `claude-sonnet-5`).

This folder hosts the team's own application for the MXChip AZ3166 board.
It follows the same convention as `starter`/`telemetry`/`mqtt`/`arcade`: every
app lives in its own folder under `app/`, with shared code coming from
`app/common/`.

## a) Change made outside this folder

The following `elseif` block was added to `MXChip/AZ3166/app/CMakeLists.txt`,
between the `mqtt` block and the `else()` (starter) block:

```cmake
elseif(APP_CONFIG STREQUAL "FEVengersApp")
    list(APPEND SOURCES
        ${COMMON_DIR}/board_init.c
        ${COMMON_DIR}/screen.c
        ${CONFIG_DIR}/main.c
        ${CONFIG_DIR}/cloud_config.h
    )
```

Without this registration, `APP_CONFIG=FEVengersApp` wouldn't be recognized
and the build would silently fall through to the `starter` branch. Board
init (`board_init.c`) and the screen (`screen.c`) reuse the shared
`app/common/` files as-is — nothing was copied.

**This is no longer the only change outside this folder.** Diagnosing a
screen/sensor freeze (see the bug log further down) led to two real,
confirmed bugs in `lib/mxchip_bsp/` (the OLED and HTS221 sensor drivers,
shared by every `app/` config). With explicit go-ahead, those were fixed
directly rather than only worked around - see
**[OUTSIDE_FOLDER_CHANGES.md](OUTSIDE_FOLDER_CHANGES.md)** for exactly what
and why.

## b) Compile

```bash
# Linux/macOS
./scripts/build.sh FEVengersApp

# Windows
.\scripts\build.ps1 -Config FEVengersApp
```

Under the hood, the script runs, from the `build/` directory:
`cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DAPP_CONFIG=FEVengersApp -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..`
followed by `ninja`. Output binary:
`MXChip/AZ3166/build/app/mxchip_threadx.bin`.

Pass `clean`/`rebuild` as a second argument for a clean build
(`./scripts/build.sh FEVengersApp clean`).

**Gotcha:** `build.sh`/`build.ps1` only re-run CMake configure when
`build/CMakeCache.txt` doesn't exist yet. If you already built another config
(e.g. `starter`) in the same `build/` folder, switching to
`./scripts/build.sh FEVengersApp` alone will **silently keep building the old
config** (CMake prints `Building application with configuration: starter`
even though you asked for `FEVengersApp`). Always pass `clean` the first time
you switch `APP_CONFIG`: `./scripts/build.sh FEVengersApp clean`. Verified
locally — this build was confirmed to actually compile `FEVengersApp/main.c`
(with Wi-Fi, OLED, fault modes, RGB LED, and MQTT with its own dedicated
internal-client stack: RAM 71.5%, FLASH 32.7% used) and produced
`mxchip_threadx.bin`/`.hex`.

## c) Flash

The AZ3166 doesn't use ST-Link/OpenOCD/DFU; it's programmed via USB
mass-storage drag-and-drop. When plugged into USB, the board mounts as a
disk drive.

```bash
# Linux/macOS - <mount-path> is where the board is mounted
./scripts/deploy.sh <mount-path>

# Windows - <drive-letter> is the board's drive letter
.\scripts\deploy.ps1 -Destination <drive-letter>
```

Copying the `.bin` file onto the board triggers the bootloader; the board
automatically resets and runs the new code. Monitor the serial output at
**115200 baud** (Tera Term / SerialTools, etc.).

## Note: main.c / cloud_config.h

`main.c` and `cloud_config.h` were copied from `app/starter` as the starting
point and carry a header noting they were generated with AI assistance
(Claude Sonnet 5, model id `claude-sonnet-5`). In this repository `cloud_config.h`
has an empty `WIFI_SSID` and `WIFI_PASSWORD`: fill them in before building.

## Screen output

`main.c` draws 5 OLED lines, redrawn together whenever any of them changes:
- **Line 0:** `FEVengers` (app name, static)
- **Line 1:** Wi-Fi + MQTT status, compact symbols — `WiFi:- MQTT:-` while
  connecting, `V` once connected, `X` if it failed (e.g. `WiFi:V MQTT:X`)
- **Line 2:** live A/B button state — `A:UP B:UP` / `A:DOWN B:UP` / etc. (raw
  press state, independent of the fault-mode gestures below)
- **Line 3:** current fault mode — `MODE: NORMAL` / `MODE: STUCK` /
  `MODE: DROPOUT` / `MODE: OUT OF RNG`
- **Line 4:** the battery temperature actually being sent — `Temp: 32.4C`
  (frozen during `STUCK`/`DROPOUT`, matching what was last published)

These 5 rows don't fit `screen.h`'s `L0..L3` spacing (18px apart, only 4 slots
in 64px), so rows 1-4 use custom tighter y-coordinates (`ROW_WIFI`=18,
`ROW_BUTTONS`=29, `ROW_MODE`=40, `ROW_TEMP`=51 in `main.c`) instead of the
`L1`/`L2`/`L3` enum.

**Color note:** the board's onboard display is an SSD1306 OLED, which is
monochrome — the driver only knows `Black` (pixel off) and `White` (pixel
on). There is no red, or any other color, option in the hardware or the
`ssd1306` driver, so the text is shown in the display's native color
(white/blue depending on the physical panel), not red.

**Font note:** only `Font_7x10`/`Font_11x18` are compiled into this project's
shared ssd1306 library (`Font_6x8` is commented out in
`lib/mxchip_bsp/ssd1306/ssd1306_conf.h`, outside this folder — not touched).
At `Font_7x10`, the 128px screen fits 18 characters, which is why line 3 says
`MODE: STUCK`/`MODE: DROPOUT` rather than a longer `STUCK SENSOR`/`SENSOR
DROPOUT` label.

## MQTT publishing (Doctor Whodunit)

Once Wi-Fi connects, a third thread (`mqtt_thread_entry`) connects to an MQTT
broker and, **every 1s**, reads the real onboard HTS221 temperature sensor
(`hts221_data_read()` from `sensor.h`/`lib/mxchip_bsp/stm_sensor` — already
initialized by the shared `app/common/board_init.c`, no extra init needed)
and publishes to a **single topic**, `FEVengers_MQTT/telemetry`:
```json
{"temperature_degC": 25.6, "counter": 12}
```
(`counter` is the `sequence` variable in `main.c` - the notes below still
call it `sequence`.)
That's the whole payload - no `timestamp_ms`, no `ecu_id`/`status`, no
`fault_mode`/mode field. There used to be a second, separate heartbeat
topic/message; it was folded into this one on purpose (simpler for the
Guardian side to parse one shape) - **there is no longer an independent
"ECU alive" signal separate from the temperature message**, so `DROPOUT`
(below) now means total silence on this topic, not just the temperature
part of it.

`sequence` is a **rolling counter**, wrapping `0-255` (`SEQUENCE_WRAP` in
`main.c`) instead of growing forever. It:
- advances normally in `NORMAL` and `OUT_OF_RANGE`,
- **freezes (stops incrementing) while `STUCK` is active** - same "frozen"
  signature as `temperature_degC` itself during `STUCK` - and resumes the
  instant `STUCK` ends,
- simply doesn't advance during `DROPOUT` either, since nothing is
  published then at all.

### Fault modes

Button reading lives entirely in `button_thread_entry` (100ms poll, the
sole owner of `BUTTON_A_IS_PRESSED`/`BUTTON_B_IS_PRESSED` and the sole
writer of `fault_mode`). Fault modes are **held-button based, not
click/toggle**: a mode is active only while the triggering button(s) are
physically down, and clears the instant they're released - no delay, no
click-counting ambiguity.

| Buttons held | Mode | Behavior |
|---|---|---|
| A only | `STUCK` | Freezes `temperature_degC` at the real sensor reading from the moment A was pressed, **and freezes `sequence` too** (both stay unchanged, message still sent every tick). Release A to go live again. |
| B only | `DROPOUT` | No message published at all - total silence on the topic (no separate heartbeat channel anymore to show the ECU is still alive). Release B to resume. |
| A + B together | `OUT OF RANGE` | Publishes a synthetic ramp: starts from the real sensor reading at the moment both were pressed and climbs `20°C` per tick (`OUT_OF_RANGE_STEP_C`) until it reaches `160°C` (`OUT_OF_RANGE_MAX_C`), then holds there; `sequence` advancing normally. Release either to clear. |
| neither | `NORMAL` | Publishes the real sensor reading, `sequence` advancing normally. |

A+B held together takes priority over the single-button cases. (An earlier
version also had a `SPIKE` one-shot on an A double-click; it was removed -
the double-click detection window made every A click, including the
intended "release to exit STUCK", wait ~400ms before committing, which felt
like the mode getting stuck.)

### RGB LED

`set_fault_led()` drives the onboard RGB LED via the PWM macros already
exposed by `app/common/board_init.h` (`RGB_LED_SET_R/G/B`, already
initialized - nothing new to set up): **green** while `fault_mode ==
NORMAL`, **red** for any active fault.

### User LED heartbeat

The board's onboard "User" LED (the one printed `USER` on the silkscreen;
`USER_LED_ON()`/`USER_LED_OFF()` in `app/common/board_init.h`, plain GPIOC
digital I/O, not I2C) toggles on/off every 0.5s, first thing in
`mqtt_thread_entry`'s loop. Placed in this specific thread on purpose: its
I2C wait is now bounded (see the next note), so it can't be dragged down by
a `display_thread_entry` hang the way a heartbeat living in
`display_thread_entry` itself could be. A steadily blinking User LED is a
genuine "this thread's loop - sensor read, fault mode, RGB LED, MQTT - is
still alive" signal, independent of whether the OLED is currently
responding - useful for telling apart "the whole board is still running,
just the screen is stuck" from "the board is fully hung" without needing
to reach for a reset button to find out.

**Fixed bug: LED fighting itself / wrong colors.** `app/common/stm32cubef4/
stm32f4xx_hal_msp.c` (compiled into every `APP_CONFIG`, including this one)
enables the A/B button EXTI interrupts at the NVIC level, and `app/common/
board_init.c` defines `__weak button_a_callback()`/`button_b_callback()`
that fire on every real press and independently stomp the RGB LED with
their own demo ramp (plus toggle the WIFI/CLOUD/USER LEDs) - directly
fighting `set_fault_led()`. Fixed, entirely within this folder, by defining
real (non-`__weak`) `button_a_callback()`/`button_b_callback()` in `main.c`
with empty bodies - this overrides the weak ones at link time, the same
mechanism `app/arcade/button_handler.c` already uses. Our own button
handling is poll-based and never depended on these interrupts anyway.

**Fixed bug: screen blank after flash/reset, only came back after
unplugging/replugging USB.** The OLED (`ssd1306_*`, used by
`display_thread_entry`) and the HTS221 temperature sensor
(`hts221_data_read()`, used by `mqtt_thread_entry`) sit on the **same
physical I2C1 bus/HAL handle**. With no synchronization, two threads could
call into the HAL I2C driver at the same time, corrupting its internal
state and potentially wedging the bus at the hardware level (SCL/SDA stuck)
- a soft reset (reset button, or the bootloader's post-flash reset) doesn't
clear that, only removing power does (which is exactly what "unplug and
replug" does). Fixed by adding a `TX_MUTEX i2c_mutex` (created in
`tx_application_define`) around every I2C access: the whole `draw_screen()`
sequence in `display_thread_entry`, and the `hts221_data_read()` call in
`mqtt_thread_entry`. This only became an issue once `mqtt_thread_entry`
started doing real sensor reads concurrently with the OLED thread - the
single-threaded screen-only version never hit it.

**MQTT broker is now real and connect is enabled again.**
`MQTT_LOCAL_BROKER_IP` is set to the team's actual broker, via the new
`MQTT_BROKER_PORT` define (`1883`, used in `nxd_mqtt_client_connect()`
instead of the library's default `NXD_MQTT_PORT`), and
`MQTT_BROKER_CONFIGURED` is back to `1`. The IP went through two values:
`192.168.1.42` first failed to connect because it's on a **different
subnet** than the board's Wi-Fi (`192.168.88.x`, confirmed via the boot
log's `IP address: 192.168.88.247`); updated to `192.168.88.28`, on the
same subnet as the board.

Earlier, a full system hang (not recoverable by the reset button, only by a
power cycle) was observed shortly after an `nxd_mqtt_client_connect()`
attempt against the then-placeholder broker timed out, so
`MQTT_BROKER_CONFIGURED` was temporarily set to `0` to skip the MQTT
connect entirely and isolate it as a suspect. **That test came back
negative: the same hang reproduced even with MQTT connect fully disabled**,
so the placeholder/unreachable broker was ruled out as the (sole) cause -
whatever is actually wedging the system is elsewhere, most likely still
I2C-related (see the OLED-reset notes below), not MQTT/networking. Kept
disabled only long enough to run that test; re-enabled now that a real
broker is configured, since a working broker is also simply needed for the
submission regardless.

**Root cause found AND FIXED for "screen and sensor froze, exact same
temperature value repeated forever": a real bug in
`lib/mxchip_bsp/stm_sensor/Src/hts221_read_data_polling.c` - see
[OUTSIDE_FOLDER_CHANGES.md](OUTSIDE_FOLDER_CHANGES.md) for the actual fix.**
`hts221_data_read()` used to do:
```c
memset(data_raw_temperature.u8bit, 0x00, sizeof(int16_t));
hts221_temperature_raw_get(&dev_ctx, data_raw_temperature.u8bit); // return value ignored!
reading.temperature_degC = linear_interpolation(&lin_temp, data_raw_temperature.i16bit);
```
`hts221_temperature_raw_get()` does return an I2C error status, but it
wasn't checked. If the underlying `HAL_I2C_Mem_Read` silently failed, the
buffer stayed at the `memset`'d zero (not the previous reading), so
`linear_interpolation` computed a **fixed, deterministic "phantom" value**
from the calibration curve at raw=0 - explaining the observed behavior
exactly: a repeating, noise-free temperature (e.g. `20.8` for 8+
consecutive 0.5s reads) instead of the usual small real-sensor drift. The
same file also had the earlier-found `static uint32_t timeout = 5;` that
was never reset. Both are now fixed directly in that file (with explicit
go-ahead to edit outside this folder) - see
[OUTSIDE_FOLDER_CHANGES.md](OUTSIDE_FOLDER_CHANGES.md).

**Also added (within this folder, kept even after the real fix above): a
diagnostic that would have confirmed the bug without needing to touch the
driver file, and still catches anything similar in the future.**
`mqtt_thread_entry` tracks consecutive bit-identical `hts221_data_read()`
results; after 4 in a row (~2s) and then every 10 more, it logs a `WARNING`
(with `HAL_I2C_GetState`) over serial. Also logs when the 0.5s `i2c_mutex`
wait itself times out (distinct from the sensor returning a bad value while
the mutex is fine).

**Fixed bug in that diagnostic itself: the logged temperature showed up
empty (`"(C)"` with nothing before it).** Both `WARNING` messages above used
plain `printf("... %.1fC ...", ...)` directly - but this project's `printf`
(newlib-nano, linked without float-in-printf support) doesn't reliably
format `%f`/`%.1f`. Only `npf_snprintf` (nanoprintf's own formatter)
handles floats correctly here - which is exactly why
`publish_temperature()`/`publish_heartbeat()` already built their JSON into
a buffer with `npf_snprintf` instead of calling `printf` directly. Both
diagnostic messages now do the same (build with `npf_snprintf`, then
`printf("%s", ...)`), so the actual frozen value is visible in the log.

**Added: real I2C bus recovery (GPIO bit-banging), triggered by actual
observed failures, not just HAL state.** Even after the two vendor-driver
fixes above, the same pattern kept recurring (confirmed three times in
testing): MQTT/heartbeat/the User LED kept working, but the OLED and the
sensor reading both froze together. This means the I2C bus can get
genuinely stuck at the **hardware** level (a slave device - the OLED or the
HTS221 - holding SDA low mid-byte), which `HAL_I2C_DeInit()`+`HAL_I2C_Init()`
alone can't fix (they only reset the STM32's own master-side peripheral
state, not a slave physically holding the bus) - and `HAL_I2C_GetState()`
isn't reliable for detecting it either (the master's software state can
still read as "ready" while a slave is stuck). Added `i2c_bus_recover()`:
takes I2C1's SCL/SDA pins (PB8/PB9 - matching
`app/common/stm32cubef4/stm32f4xx_hal_msp.c`'s `HAL_I2C_MspInit()` exactly,
read-only reference, not edited) over as plain GPIO, manually clocks SCL up
to 9 times to let a stuck slave finish whatever byte it's waiting on and
release SDA, issues a manual STOP condition, then hands the pins back to
the I2C peripheral and re-inits it. Triggered from two places: as an
escalation inside `recover_i2c_if_stuck()` when the cheap DeInit/Init fix
doesn't bring the state back to ready, and - the more reliable trigger -
directly from the "same value N times in a row" diagnostic above, since
that's **evidence from actual data** that reads are failing, independent of
what `HAL_I2C_GetState()` reports.

**Also slowed `display_thread_entry`'s poll/redraw-check interval from
0.1s to 0.5s** - fewer checks per second means fewer chances to redraw (and
therefore fewer OLED I2C writes); the temperature itself only changes once
a second now anyway, so checking 10x/s was more than needed. Buttons/mode
still show up on screen within half a second.

**Also slowed the sensor-read/MQTT-publish cadence from 0.5s to 1s**
(`tx_thread_sleep(TX_TIMER_TICKS_PER_SECOND)` instead of `/ 2`) - halves I2C
bus traffic, on the theory that less-frequent transactions give whatever
causes the lockup fewer chances to trigger. A mitigation on top of the real
fix above, not a fix by itself.

**Fixed: buttons/LED responded very late, and MQTT showed a stale
temperature, whenever the OLED got stuck for an extended stretch.** Button
reading and `fault_mode` used to live in `display_thread_entry` - the same
thread that can stall for a long time inside the OLED's I2C write (see
below). While stuck, that thread couldn't get back around to its loop top
to re-read the buttons, so `fault_mode` (and therefore the RGB LED) only
caught up once the screen un-stuck itself - "ledler çok geç tepki veriyor".
Split button reading out into its own `button_thread_entry` (a 4th thread,
registered in `tx_application_define`): it touches no I2C/no mutex at all
(`BUTTON_A/B_IS_PRESSED` are plain GPIO register reads) and is now the sole
writer of `fault_mode`. `display_thread_entry` only reads `fault_mode` for
display. Buttons -> RGB LED -> MQTT's fault-mode-driven publish decision
are now fully independent of whether the OLED is currently stuck.

**Confirmed AND FIXED: MQTT stopped along with the screen in one run,
pointing squarely at `i2c_mutex` being held forever.**
`ssd1306_WriteCommand()`/`ssd1306_WriteData()` (`lib/mxchip_bsp/ssd1306/
ssd1306.c`) used to call `HAL_I2C_Mem_Write(..., HAL_MAX_DELAY)` - an
unbounded wait. If that call ever truly hung inside
`display_thread_entry`'s `draw_screen()` (not just silently no-ops, as the
earlier hypothesis below assumed, but genuinely never returning),
`display_thread_entry` never reached `tx_mutex_put()` and held `i2c_mutex`
forever. Since `mqtt_thread_entry` used to wait `TX_WAIT_FOREVER` for that
same mutex before every sensor read, it would then freeze too - exactly
matching an observed run where both the OLED *and* MQTT publishing stopped
together with no button pressed. **Fixed directly** (with explicit
go-ahead): `HAL_MAX_DELAY` is now a bounded 100ms timeout - see
[OUTSIDE_FOLDER_CHANGES.md](OUTSIDE_FOLDER_CHANGES.md). Kept, as
defense-in-depth, the earlier mitigation in this folder too:
`mqtt_thread_entry`'s mutex wait is bounded
(`TX_TIMER_TICKS_PER_SECOND / 2`, i.e. 0.5s) instead of forever - if the
mutex can't be acquired in time, it reuses the last known temperature
reading and keeps publishing/the LED alive for that tick instead of
blocking.

**Earlier, now-superseded hypothesis (kept for context - screen stops
updating after a while, but buttons/LED/fault_mode keep working; this
matched an earlier, different-looking occurrence before the MQTT-hang
correlation above was found):**
`ssd1306_WriteCommand()`/`ssd1306_WriteData()` (`lib/mxchip_bsp/ssd1306/
ssd1306.c`) are `void` and never check `HAL_I2C_Mem_Write()`'s return
status. If the HAL I2C peripheral ever lands in a non-`HAL_I2C_STATE_READY`
state (a transient bus glitch, for instance), those calls can silently
become no-ops - `draw_screen()` still runs top-to-bottom and releases
`i2c_mutex` normally (so buttons/`fault_mode`/the LED/the sensor read all
keep working, matching what was reported), but nothing new actually reaches
the physical screen. Added `recover_i2c_if_stuck()` in `main.c`: before each
OLED draw and each sensor read (both already inside the `i2c_mutex`
section), it checks `HAL_I2C_GetState(&I2cHandle)` and, if not ready,
re-initializes the peripheral (`HAL_I2C_DeInit` + `HAL_I2C_Init` - safe to
call again since `HAL_I2C_DeInit` doesn't touch `I2cHandle.Init`, so
`HAL_I2C_Init` just reapplies `app/common/board_init.c`'s original I2C
settings). `I2cHandle` is a plain global defined in
`app/common/board_init.c` (not declared in `board_init.h`), referenced here
via `extern I2C_HandleTypeDef I2cHandle;` - no file outside this folder was
touched.

**Sensor/LED/OLED no longer wait for Wi-Fi.** Originally `mqtt_thread_entry`
opened with a blocking `while (wifi_state == WIFI_CONNECTING) { ... }` before
doing anything else, so the OLED's `Temp:` line and the RGB LED stayed
frozen until Wi-Fi finished connecting (plus the MQTT connect attempt) -
even though reading the sensor and deciding the fault mode don't need a
network at all. Restructured so the sensor/LED/OLED-temperature logic runs
from the very first 0.5s tick unconditionally; the one-time MQTT client
create/connect attempt now happens inline inside that same loop, gated on
`wifi_state` itself (fires once, the first tick Wi-Fi is no longer
`WIFI_CONNECTING`), instead of blocking everything ahead of it.

**Broker is a placeholder.** `cloud_config.h`'s `MQTT_LOCAL_BROKER_IP` is the
same placeholder IP used in `app/mqtt/cloud_config.h` — not a real address
for the team's Input Handler. Update that one line once the broker is known.

**Fixed bug: temperature/LED stopped updating entirely.** `mqtt_thread_stack`
was being passed as the stack for *two different, concurrently-running*
ThreadX threads at once: our own outer "MQTT Thread" (`mqtt_thread_entry`,
created via `tx_thread_create`) **and** NetX Duo's own internal MQTT
processing thread (via `nxd_mqtt_client_create`'s stack argument). Two
threads sharing one physical stack buffer corrupt each other's stack frames
the moment both are active - this silently broke the outer thread's loop
(the one that reads the sensor, updates `displayed_temp`, and drives
`set_fault_led()`), matching exactly what was reported: temperature frozen,
LED never lighting. `app/mqtt/mqtt_client.c` avoids this with two distinct
buffers (`mqtt_thread_stack` for the outer thread, `mqtt_client_stack` for
NetX's internal one) - this folder now does the same, with a second buffer
`mqtt_client_internal_stack` dedicated solely to `nxd_mqtt_client_create()`.

**Fixed bug: everything worked at first, then froze after running a
while.** Two contributing issues, both inside `mqtt_thread_entry`'s publish
path:
1. Temperature was published at **QOS1**, which requires a broker PUBACK to
   complete. Against a flaky/placeholder broker that never (or
   inconsistently) acks, unacked QOS1 messages queue up for retransmission
   inside the NetX MQTT client - at a 0.5s publish cadence that queue grows
   over time. Switched to **QOS0** (fire-and-forget) - nothing to retry or
   accumulate, acceptable here since a fresh reading follows every 0.5s
   anyway.
2. `nxd_mqtt_client_disconnect_notify_set()`'s callback was wired up but did
   nothing except `printf` - if the broker dropped the connection after a
   while (plausible for a placeholder broker), the `mqtt_connected` flag
   never got cleared, so the loop kept calling `nxd_mqtt_client_publish()`
   against a dead connection, each call burning its full
   `MQTT_PUBLISH_TIMEOUT_TICKS` - the app would still be running, just
   crawling slower and slower, reading as "frozen". Fixed by making
   `mqtt_connected` a shared variable the disconnect callback also writes
   (`mqtt_connected = 0`), so a broker-side disconnect actually stops
   further publish attempts instead of repeatedly stalling on a dead link.

**Fixed bug: buttons appeared to do nothing.** The first version called
`nxd_mqtt_client_connect`/`_publish` with `NX_WAIT_FOREVER`, inside the same
thread that samples the buttons and decides `fault_mode`. Against the
placeholder (likely unreachable) broker, that call either blocked forever or
returned early with `return;` — either way the button-sampling loop never
ran, so the OLED stayed on `MODE: NORMAL` no matter what was pressed. Fixed
by: bounding connect (5s) and publish (2s) with real timeouts, never
`return`-ing out of the thread on a connect failure, and gating only the
`nxd_mqtt_client_publish` calls (not the button/fault-mode/OLED logic) behind
a `mqtt_connected` flag. Buttons and the OLED now work correctly even with
no reachable broker; publishing itself is naturally still a no-op until a
real broker is configured.

**Known pre-existing limitation (not fixed, out of scope - outside this
folder):** `lib/mxchip_bsp/stm_sensor/Src/hts221_read_data_polling.c`'s
`hts221_data_read()` uses a `static uint32_t timeout = 5` as its
data-ready-wait budget - it's initialized once and never reset, so after
roughly the first 5 "not ready yet" waits across the whole program's
lifetime, the data-ready check becomes a permanent no-op and the function
just reads whatever is in the raw registers. In practice this is low-impact
because `hts221_config()` enables Block Data Update (BDU), which makes the
sensor itself hold a coherent MSB/LSB pair until both are read - so readings
still update, just without the extra readiness guard. If temperature still
looks unresponsive on real hardware after this fix, retest with the new
held-button model first (a stuck-in-STUCK display was the likely cause
before); this `timeout` quirk would need a fix in `lib/mxchip_bsp/`, outside
`FEVengersApp/`.
