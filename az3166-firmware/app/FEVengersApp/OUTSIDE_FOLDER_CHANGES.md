# Changes Outside app/FEVengersApp/

> Generated with AI assistance (Claude Sonnet 5, model id: `claude-sonnet-5`).

Everything else in this project's history stayed inside `app/FEVengersApp/`
(plus the one, separately-tracked `app/CMakeLists.txt` registration block
from setup - see `SETUP.md`). This file exists specifically because solving
the "screen/sensor freeze" bug (see `SETUP.md`'s bug log) required editing
two vendor driver files under `lib/mxchip_bsp/`, with the user's explicit
go-ahead. Both are real, confirmed bugs - not workarounds - and would
benefit any app in this repo that uses the OLED or the HTS221 sensor, not
just `FEVengersApp`.

## 1. `lib/mxchip_bsp/ssd1306/ssd1306.c` - unbounded I2C timeout

`ssd1306_WriteCommand()` / `ssd1306_WriteData()` called
`HAL_I2C_Mem_Write(..., HAL_MAX_DELAY)` - no timeout at all. If an I2C
transaction ever glitched, these calls could hang forever, freezing
whichever thread called them - and since `FEVengersApp/main.c` wraps OLED
writes in a mutex shared with the HTS221 sensor read, a hang here also
froze MQTT/the RGB LED/the sensor the moment they needed that same mutex.

**Fix:** bounded the timeout to `SSD1306_I2C_TIMEOUT_MS` (100ms) instead of
`HAL_MAX_DELAY`. Function signatures (`void`) are unchanged, so every
existing caller (all four `app/` configs, not just `FEVengersApp`) keeps
working as-is - a failed write now just times out and returns instead of
hanging, rather than every caller needing to change to handle a new return
value.

## 2. `lib/mxchip_bsp/stm_sensor/Src/hts221_read_data_polling.c` - two bugs

**a) `static uint32_t timeout = 5;`** was a function-static variable,
initialized once for the entire program's lifetime and only ever
decremented, never reset. After roughly the first 5 "sensor not ready yet"
waits anywhere in the program's run, the data-ready check
(`while (... && timeout > 0)`) became a permanent no-op for every
subsequent call to `hts221_data_read()`.

**Fix:** moved `timeout` to be a local variable, reset to `5` on every call.

**b) Ignored I2C read error status.** `hts221_data_read()` called
`hts221_humidity_raw_get()` / `hts221_temperature_raw_get()` - both of
which return an I2C error status - without ever checking it. Each call was
preceded by `memset(..., 0x00, ...)` zeroing the raw-value buffer. So a
transient I2C read failure left the buffer at zero, and
`linear_interpolation()` still ran on it, producing a **fixed, deterministic
"phantom" reading** (the calibration curve's value at raw ADC = 0) -
indistinguishable from a real reading except that it never changes. This
exactly matched what was observed: temperature frozen at one exact value
(no sensor noise/drift at all) for many consecutive 0.5s reads, while
everything else (MQTT, buttons, LED) kept working.

**Fix:** check both return statuses. On success, compute and store the
reading as before. On failure, keep the last known-good reading (a new
file-static `last_good_reading`) instead of computing from a zeroed buffer.
`hts221_data_read()`'s return type/signature is unchanged.

## What this means for other app configs

`starter`/`telemetry`/`mqtt`/`arcade` all link against this same
`mxchip_bsp` library and the same sensor driver, so they get both fixes too
- for free, with no code changes needed on their side (same function
signatures, same behavior on success, just more resilient on transient I2C
failures).

## Verification

```bash
./scripts/build.sh FEVengersApp clean
```
Both changed files show up in the ninja build output
(`lib/mxchip_bsp/CMakeFiles/mxchip_bsp.dir/stm_sensor/Src/
hts221_read_data_polling.c.obj` and `.../ssd1306/ssd1306.c.obj`), confirming
they're actually compiled in. Full diff:

```bash
git diff -- MXChip/AZ3166/lib/mxchip_bsp/ssd1306/ssd1306.c \
            MXChip/AZ3166/lib/mxchip_bsp/stm_sensor/Src/hts221_read_data_polling.c
```
