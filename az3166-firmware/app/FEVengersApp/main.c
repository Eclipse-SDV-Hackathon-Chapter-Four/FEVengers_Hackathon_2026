/*
 * Generated with AI assistance (Claude Sonnet 5, model id: claude-sonnet-5).
 * Copied from app/starter/main.c as the starting point for FEVengersApp.
 */

/*
 * Copyright (c) Microsoft
 * Copyright (c) 2024 Eclipse Foundation
 *
 *  This program and the accompanying materials are made available
 *  under the terms of the MIT license which is available at
 *  https://opensource.org/license/mit.
 *
 *  SPDX-License-Identifier: MIT
 *
 *  Contributors:
 *     Microsoft         - Initial version
 *     Frédéric Desbiens - 2024 version.
 */

#include <stdio.h>
#include <string.h>

#include "tx_api.h"

#include "board_init.h"
#include "cmsis_utils.h"
#include "nanoprintf.h"
#include "screen.h"
#include "sensor.h"
#include "ssd1306.h"
#include "sntp_client.h"
#include "wwd_networking.h"

#include "cloud_config.h"

// NetX Duo MQTT's defaults (12/32 bytes) are too small for our topic names
// and JSON payloads - override before pulling in the addon header, same
// approach as app/mqtt/mqtt_client.h.
#define NXD_MQTT_MAX_TOPIC_NAME_LENGTH 40
#define NXD_MQTT_MAX_MESSAGE_LENGTH    200
#include "nxd_mqtt_client.h"

#define ECLIPSETX_THREAD_STACK_SIZE 4096
#define ECLIPSETX_THREAD_PRIORITY   4

#define MQTT_THREAD_STACK_SIZE 5120
#define MQTT_KEEP_ALIVE_TIMER  300
#define QOS0                   0
#define QOS1                   1

// The single MQTT message's "counter" field rolls over at this value
// instead of growing forever. 256 -> counter cycles 0-255 (fits a byte).
#define SEQUENCE_WRAP 256

// Bounded waits for the MQTT connect/publish calls. The placeholder broker
// may be unreachable - these must NOT be NX_WAIT_FOREVER, otherwise a dead
// broker freezes this thread forever and the button/fault-mode loop below
// (which lives in the same thread) never runs, even though the buttons
// themselves are fine.
#define MQTT_CONNECT_TIMEOUT_TICKS (TX_TIMER_TICKS_PER_SECOND * 5)
#define MQTT_PUBLISH_TIMEOUT_TICKS (TX_TIMER_TICKS_PER_SECOND * 2)

// Protects every I2C bus access: the OLED (ssd1306_*, used by
// display_thread_entry) and the HTS221 temperature sensor
// (hts221_data_read(), used by mqtt_thread_entry) share the same physical
// I2C1 bus/HAL handle. Without this mutex, two threads could call into the
// HAL I2C driver at the same time, corrupting its internal state and
// potentially wedging the bus at the hardware level (SCL/SDA stuck) -
// which a soft reset doesn't clear, only a full power cycle does. This was
// a real, reported bug: screen not coming up after flashing/reset, only
// after unplugging/replugging USB.
TX_MUTEX i2c_mutex;

// Defined in app/common/board_init.c (I2C1_Init), not declared in
// board_init.h. ssd1306_WriteCommand()/ssd1306_WriteData() are void and
// never check HAL_I2C_Mem_Write()'s return status - if the HAL peripheral
// ever lands in a non-READY state (e.g. a transient bus glitch), those
// calls silently become no-ops: draw_screen() still runs and releases
// i2c_mutex normally (so buttons/fault_mode/LED/sensor keep working, as
// reported), but nothing new actually reaches the physical screen. See
// recover_i2c_if_stuck() below.
extern I2C_HandleTypeDef I2cHandle;

// Crude busy-wait, good for a handful of microseconds - good enough for
// bit-banged I2C recovery timing below, where exact timing doesn't matter
// (this is a rare recovery path, not normal-operation I2C). Not using
// HAL_Delay(): this project reconfigures SysTick for the ThreadX tick rate
// (see systick_interval_set in tx_application_define), so HAL_Delay's
// usual 1ms-SysTick assumption doesn't hold here.
static void busy_wait_short(void)
{
    for (volatile int i = 0; i < 400; i++)
    {
    }
}

// I2C1 SCL=PB8/SDA=PB9, AF4_I2C1, open-drain with internal pull-up - must
// match app/common/stm32cubef4/stm32f4xx_hal_msp.c's HAL_I2C_MspInit()
// exactly (read-only reference, not edited).
#define I2C_SCL_PIN GPIO_PIN_8
#define I2C_SDA_PIN GPIO_PIN_9

// Real I2C bus recovery: if a slave device (the OLED or the HTS221 sensor)
// is stuck mid-byte holding SDA low, HAL_I2C_DeInit()+HAL_I2C_Init() alone
// don't fix it - those only reset the STM32's own (master-side) peripheral
// state, not a slave that's physically holding the bus. The standard fix
// is to take SCL/SDA over as plain GPIO and manually clock SCL (idle SDA
// high) up to 9 times - enough bits for a stuck slave to finish whatever
// byte it's waiting on and release SDA - then issue a manual STOP
// condition, and only then hand the pins back to the I2C peripheral. Must
// be called with i2c_mutex already held.
static void i2c_bus_recover(void)
{
    GPIO_InitTypeDef gpio = {0};
    int i;

    gpio.Mode  = GPIO_MODE_OUTPUT_OD;
    gpio.Pull  = GPIO_PULLUP;
    gpio.Speed = GPIO_SPEED_HIGH;

    gpio.Pin = I2C_SCL_PIN;
    HAL_GPIO_Init(GPIOB, &gpio);
    gpio.Pin = I2C_SDA_PIN;
    HAL_GPIO_Init(GPIOB, &gpio);

    HAL_GPIO_WritePin(GPIOB, I2C_SCL_PIN, GPIO_PIN_SET);
    HAL_GPIO_WritePin(GPIOB, I2C_SDA_PIN, GPIO_PIN_SET);
    busy_wait_short();

    for (i = 0; i < 9; i++)
    {
        if (HAL_GPIO_ReadPin(GPIOB, I2C_SDA_PIN) == GPIO_PIN_SET)
        {
            break; // SDA released - the stuck slave let go, no need to continue.
        }
        HAL_GPIO_WritePin(GPIOB, I2C_SCL_PIN, GPIO_PIN_RESET);
        busy_wait_short();
        HAL_GPIO_WritePin(GPIOB, I2C_SCL_PIN, GPIO_PIN_SET);
        busy_wait_short();
    }

    // Manual STOP condition: SDA low->high while SCL is high.
    HAL_GPIO_WritePin(GPIOB, I2C_SDA_PIN, GPIO_PIN_RESET);
    busy_wait_short();
    HAL_GPIO_WritePin(GPIOB, I2C_SCL_PIN, GPIO_PIN_SET);
    busy_wait_short();
    HAL_GPIO_WritePin(GPIOB, I2C_SDA_PIN, GPIO_PIN_SET);
    busy_wait_short();

    // Hand the pins back to the I2C peripheral - same config as
    // HAL_I2C_MspInit() (AF4_I2C1, open-drain, internal pull-up).
    gpio.Mode      = GPIO_MODE_AF_OD;
    gpio.Pull      = GPIO_PULLUP;
    gpio.Speed     = GPIO_SPEED_HIGH;
    gpio.Alternate = GPIO_AF4_I2C1;
    gpio.Pin       = I2C_SCL_PIN;
    HAL_GPIO_Init(GPIOB, &gpio);
    gpio.Pin       = I2C_SDA_PIN;
    HAL_GPIO_Init(GPIOB, &gpio);

    HAL_I2C_DeInit(&I2cHandle);
    HAL_I2C_Init(&I2cHandle);
}

// Re-initializes the shared I2C peripheral if it's not in a ready state.
// First tries the cheap, software-only fix (HAL_I2C_DeInit()+Init(), which
// HAL_I2C_DeInit() doesn't touch I2cHandle.Init, so HAL_I2C_Init() just
// reapplies app/common/board_init.c's I2C1_Init() settings) - but that
// alone doesn't clear a slave physically holding the bus, so if the
// peripheral is STILL not ready right after, escalates to the real GPIO-
// level bus recovery above. Must be called with i2c_mutex already held.
static void recover_i2c_if_stuck(void)
{
    if (HAL_I2C_GetState(&I2cHandle) != HAL_I2C_STATE_READY)
    {
        HAL_I2C_DeInit(&I2cHandle);
        HAL_I2C_Init(&I2cHandle);

        if (HAL_I2C_GetState(&I2cHandle) != HAL_I2C_STATE_READY)
        {
            i2c_bus_recover();
        }
    }
}

TX_THREAD eclipsetx_thread;
TX_THREAD eclipsetx_thread2;
TX_THREAD mqtt_thread;
TX_THREAD button_thread;
ULONG eclipsetx_thread_stack[ECLIPSETX_THREAD_STACK_SIZE / sizeof(ULONG)];
ULONG eclipsetx_thread_stack2[ECLIPSETX_THREAD_STACK_SIZE / sizeof(ULONG)];
// Button-polling thread's stack - see button_thread_entry for why it's
// separate from display_thread_entry.
ULONG button_thread_stack[ECLIPSETX_THREAD_STACK_SIZE / sizeof(ULONG)];
// Stack for OUR OWN "MQTT Thread" (mqtt_thread_entry below), created via
// tx_thread_create in tx_application_define.
ULONG mqtt_thread_stack[MQTT_THREAD_STACK_SIZE / sizeof(ULONG)];
// SEPARATE stack for NetX Duo's own internal MQTT client processing
// thread, passed to nxd_mqtt_client_create(). Must NOT be the same buffer
// as mqtt_thread_stack above - two ThreadX threads sharing one physical
// stack corrupt each other the moment both run (this was a real bug here:
// temperature/LED silently stopped updating because the outer thread's
// stack frame got stomped by NetX's internal thread using the same
// memory). app/mqtt/mqtt_client.c uses this same two-buffer pattern.
ULONG mqtt_client_internal_stack[MQTT_THREAD_STACK_SIZE / sizeof(ULONG)];

typedef enum
{
    WIFI_CONNECTING = 0,
    WIFI_CONNECTED  = 1,
    WIFI_FAILED     = 2
} wifi_state_t;

// Single word, so a plain store/load is atomic on Cortex-M4 - no mutex
// needed between the Wi-Fi thread (writer) and the display thread (reader).
static volatile wifi_state_t wifi_state = WIFI_CONNECTING;

typedef enum
{
    MODE_NORMAL       = 0,
    MODE_STUCK        = 1,
    MODE_DROPOUT      = 2,
    MODE_OUT_OF_RANGE = 3
} fault_mode_t;

// SPIKE (A double-click, one-shot) and click/toggle semantics were both
// removed - the double-click detection window made every A click wait
// ~400ms before committing, which read as the mode getting "stuck". Fault
// modes are now purely HELD-button based (see display_thread_entry): a
// fault is active only while the triggering button(s) are physically held
// down, and clears the instant they're released. No ambiguity, no delay.

// Persistent fault mode: toggled by display_thread_entry (the sole owner of
// button/gesture reading), consumed by mqtt_thread_entry every 1s to
// decide what to publish. Single word, so a plain store/load is atomic on
// Cortex-M4 - no mutex needed.
static volatile fault_mode_t fault_mode = MODE_NORMAL;

// The battery temperature actually being sent right now (frozen during
// MODE_STUCK/MODE_DROPOUT, matching what publish_temperature() last sent).
// float is 32-bit/word-sized, so this is also a safe plain store/load on
// Cortex-M4 with no mutex needed.
static volatile float displayed_temp = 25.0f;

// Written by mqtt_thread_entry (and mqtt_disconnect_func, on a
// broker-initiated disconnect - plausible after a while against a
// flaky/placeholder broker, so publish attempts actually stop instead of
// repeatedly stalling on a dead connection), read by display_thread_entry
// for the OLED's MQTT status symbol. mqtt_setup_attempted distinguishes
// "not attempted yet / still connecting" (both 0) from "attempted and
// failed" (connected==0, attempted==1). Single words, plain store/load is
// atomic on Cortex-M4 - no mutex needed.
static volatile int mqtt_connected       = 0;
static volatile int mqtt_setup_attempted = 0;

// Extra OLED rows beyond the title, all Font_7x10 (10px tall), packed
// tighter than screen.h's L0..L3 spacing so a 5th line still fits in the
// 64px-tall display: title 0-18, then 4 rows of 11px from y=18.
#define ROW_WIFI    18
#define ROW_BUTTONS 29
#define ROW_MODE    40
#define ROW_TEMP    51

// OUT_OF_RANGE no longer jumps straight to a fixed value: starting from the
// real sensor reading at the moment A+B are pressed, the published
// temperature climbs by OUT_OF_RANGE_STEP_C every tick (1s) until it
// reaches OUT_OF_RANGE_MAX_C, then holds there until the buttons are
// released.
#define OUT_OF_RANGE_STEP_C 20.0f
#define OUT_OF_RANGE_MAX_C  160.0f

#define LED_PWM_MAX 2047
#define LED_PWM_OFF 0

// RGB_LED_SET_R/G/B(value) come from board_init.h (already included),
// already initialized by the shared app/common/board_init.c - nothing to
// set up ourselves.
static void set_fault_led(int fault_active)
{
    if (fault_active)
    {
        RGB_LED_SET_R(LED_PWM_MAX);
        RGB_LED_SET_G(LED_PWM_OFF);
        RGB_LED_SET_B(LED_PWM_OFF);
    }
    else
    {
        RGB_LED_SET_R(LED_PWM_OFF);
        RGB_LED_SET_G(LED_PWM_MAX);
        RGB_LED_SET_B(LED_PWM_OFF);
    }
}

// app/common/stm32cubef4/stm32f4xx_hal_msp.c (compiled into every config,
// including this one) enables the A/B button EXTI interrupts at the NVIC
// level. app/common/board_init.c defines __weak button_a_callback()/
// button_b_callback() that fire on every real press and independently
// stomp the RGB LED with their own demo ramp (and toggle the WIFI/CLOUD/
// USER LEDs) - fighting set_fault_led() above. Since those are __weak,
// providing real (non-weak) definitions here overrides them at link time -
// this is the repo's own intended override mechanism (see
// app/arcade/button_handler.c, which does the same). No-op bodies fully
// neutralize the legacy demo behavior; our own button handling is
// poll-based (BUTTON_A_IS_PRESSED/BUTTON_B_IS_PRESSED in
// display_thread_entry) and doesn't depend on these interrupts at all.
void button_a_callback(void)
{
}

void button_b_callback(void)
{
}

static void eclipsetx_thread_entry(ULONG parameter)
{
    UINT status;

    printf("Starting Eclipse ThreadX thread\r\n\r\n");

    // Initialize the network
    if ((status = wwd_network_init(WIFI_SSID, WIFI_PASSWORD, WIFI_MODE)) == 0)
    {
        status = wwd_network_connect();
    }

    if (status == 0)
    {
        printf("SUCCESS: WiFi connected\r\n");
        wifi_state = WIFI_CONNECTED;
    }
    else
    {
        printf("ERROR: Failed to initialize the network (0x%08x)\r\n", status);
        wifi_state = WIFI_FAILED;
    }
}

// Draws the app name, the Wi-Fi/MQTT connection status, the live A/B
// button status, the current fault mode, and the battery temperature being
// sent, all in one screen refresh.
//
// NOTE: the AZ3166's onboard SSD1306 OLED is monochrome - the driver only
// supports Black (pixel off) and White (pixel on), so red (or any other
// color) text is not possible on this display.
static void draw_screen(char* status_line, char* button_line, char* mode_line, char* temp_line)
{
    // Hold the shared I2C bus for the whole sequence - see i2c_mutex's
    // comment for why this matters (concurrent I2C access from this thread
    // and mqtt_thread_entry's sensor reads can wedge the bus at the
    // hardware level).
    tx_mutex_get(&i2c_mutex, TX_WAIT_FOREVER);
    recover_i2c_if_stuck();

    ssd1306_Fill(Black);
    ssd1306_SetCursor(2, L0);
    ssd1306_WriteString("FEVengers", Font_11x18, White);
    ssd1306_SetCursor(2, ROW_WIFI);
    ssd1306_WriteString(status_line, Font_7x10, White);
    ssd1306_SetCursor(2, ROW_BUTTONS);
    ssd1306_WriteString(button_line, Font_7x10, White);
    ssd1306_SetCursor(2, ROW_MODE);
    ssd1306_WriteString(mode_line, Font_7x10, White);
    ssd1306_SetCursor(2, ROW_TEMP);
    ssd1306_WriteString(temp_line, Font_7x10, White);
    ssd1306_UpdateScreen();

    tx_mutex_put(&i2c_mutex);
}

// Sole owner of button reading AND of fault_mode: polls A/B every 100ms
// and derives fault_mode directly from which buttons are currently HELD
// DOWN (not click/toggle gestures) - the fault is active only as long as
// the button is held, and clears the instant it's released:
//   A+B both held -> MODE_OUT_OF_RANGE (highest priority)
//   B held only   -> MODE_DROPOUT
//   A held only   -> MODE_STUCK
//   neither held  -> MODE_NORMAL
//
// Deliberately its own thread, separate from display_thread_entry, and
// touches NO I2C/no mutex at all (BUTTON_A/B_IS_PRESSED are plain GPIO
// register reads). This was a real, reported bug: when
// display_thread_entry's OLED write stalled for an extended stretch (see
// i2c_mutex's comment), fault_mode used to only get recomputed once that
// same thread's loop got back around to it - so a stuck screen also meant
// buttons/the RGB LED responded "çok geç" (very late). Now button->
// fault_mode->LED responsiveness is fully independent of whether the OLED
// is currently stuck.
static void button_thread_entry(ULONG parameter)
{
    for (;;)
    {
        int a = BUTTON_A_IS_PRESSED ? 1 : 0;
        int b = BUTTON_B_IS_PRESSED ? 1 : 0;

        fault_mode = (a && b) ? MODE_OUT_OF_RANGE
                               : (b ? MODE_DROPOUT : (a ? MODE_STUCK : MODE_NORMAL));

        tx_thread_sleep(TX_TIMER_TICKS_PER_SECOND / 10);
    }
}

// Redraws the OLED on any change. Reads (never writes) fault_mode -
// button_thread_entry is the sole writer, see its comment for why. This is
// the only thread that touches the ssd1306 framebuffer, so there's no risk
// of two threads racing on it; it CAN stall for extended periods inside
// the I2C write (see i2c_mutex's comment) without that affecting buttons,
// the RGB LED, the sensor, or MQTT anymore.
static void display_thread_entry(ULONG parameter)
{
    wifi_state_t last_state  = (wifi_state_t)-1;
    fault_mode_t last_mode   = (fault_mode_t)-1;
    int last_a               = -1;
    int last_b               = -1;
    int last_mqtt_connected  = -1;
    int last_mqtt_attempted  = -1;
    // Compared as tenths of a degree to avoid float-equality pitfalls.
    int last_temp_tenths = -1;

    for (;;)
    {
        wifi_state_t state   = wifi_state;
        int a                 = BUTTON_A_IS_PRESSED ? 1 : 0;
        int b                 = BUTTON_B_IS_PRESSED ? 1 : 0;
        fault_mode_t mode     = fault_mode;
        int mqtt_is_connected = mqtt_connected;
        int mqtt_is_attempted = mqtt_setup_attempted;

        int temp_tenths = (int)(displayed_temp * 10.0f);

        if (state != last_state || mode != last_mode || a != last_a || b != last_b ||
            temp_tenths != last_temp_tenths || mqtt_is_connected != last_mqtt_connected ||
            mqtt_is_attempted != last_mqtt_attempted)
        {
            last_state          = state;
            last_mode           = mode;
            last_a              = a;
            last_b              = b;
            last_temp_tenths    = temp_tenths;
            last_mqtt_connected = mqtt_is_connected;
            last_mqtt_attempted = mqtt_is_attempted;

            char* button_line = a ? (b ? "A:DOWN B:DOWN" : "A:DOWN B:UP")
                                   : (b ? "A:UP B:DOWN" : "A:UP B:UP");

            // Only Font_7x10/Font_11x18 are compiled into this project's
            // ssd1306 library (see lib/mxchip_bsp/ssd1306/ssd1306_conf.h,
            // outside FEVengersApp - not touching it). At Font_7x10, 128px
            // / 7px = 18 chars max, so the full "SENSOR DROPOUT" / "OUT OF
            // RANGE" style labels don't fit and are shortened.
            char* mode_line;
            switch (mode)
            {
                case MODE_STUCK:
                    mode_line = "MODE: STUCK";
                    break;
                case MODE_DROPOUT:
                    mode_line = "MODE: DROPOUT";
                    break;
                case MODE_OUT_OF_RANGE:
                    mode_line = "MODE: OUT OF RNG";
                    break;
                default:
                    mode_line = "MODE: NORMAL";
                    break;
            }

            char temp_line[20];
            npf_snprintf(temp_line, sizeof(temp_line), "Temp: %.1fC", (double)displayed_temp);

            // Compact "WiFi:<X/V/-> MQTT:<X/V/->" status line: 'V' =
            // connected, 'X' = failed, '-' = still connecting/not
            // attempted yet. Short symbols because a full "WiFi: Connected
            // / MQTT: Connected" pair of lines doesn't fit two separate
            // rows alongside buttons/mode/temp on a 64px-tall screen.
            char wifi_symbol = (state == WIFI_CONNECTED) ? 'V' : (state == WIFI_FAILED) ? 'X' : '-';
            char mqtt_symbol = mqtt_is_connected ? 'V' : (mqtt_is_attempted ? 'X' : '-');

            char status_line[20];
            npf_snprintf(status_line, sizeof(status_line), "WiFi:%c MQTT:%c", wifi_symbol, mqtt_symbol);

            draw_screen(status_line, button_line, mode_line, temp_line);
        }

        // 0.5s, not 0.1s: fewer checks means fewer chances to redraw (and
        // therefore fewer OLED I2C writes) per second - the temperature
        // itself only changes once a second now anyway (see
        // mqtt_thread_entry), so polling the OLED's inputs 10x/s was more
        // than needed. Buttons/mode still show up within half a second.
        tx_thread_sleep(TX_TIMER_TICKS_PER_SECOND / 2);
    }
}

#define STRLEN(p) (sizeof(p) - 1)

static NXD_MQTT_CLIENT mqtt_client;

#if MQTT_BROKER_CONFIGURED
static VOID mqtt_disconnect_func(NXD_MQTT_CLIENT* client_ptr)
{
    NX_PARAMETER_NOT_USED(client_ptr);
    printf("MQTT client disconnected from broker.\r\n");
    mqtt_connected = 0;
}
#endif

// Single topic, single message shape: just the temperature and a rolling
// sequence counter - no separate heartbeat topic/message anymore. Skipped
// entirely in MODE_DROPOUT (see the call site), so "no message" is itself
// the dropout signal; there's no longer a separate heartbeat channel to
// tell "sensor dropped out" apart from "ECU is dead" - a deliberate
// simplification.
static void publish_temperature(float temperature_c, ULONG sequence)
{
    char buffer[64];
    UINT status;
    int length;

    length = npf_snprintf(buffer, sizeof(buffer),
        "{\"temperature_degC\": %.1f, \"counter\": %lu}",
        (double)temperature_c, sequence);

    // QOS0, not QOS1: with a flaky/placeholder broker, QOS1 messages that
    // never get PUBACK'd queue up for retransmission inside the NetX MQTT
    // client - at a fast publish cadence that queue can grow unbounded over
    // time and was a likely contributor to the reported "freezes after a
    // while". QOS0 is fire-and-forget, nothing to retry/accumulate, and is
    // fine for a telemetry stream where a fresh value follows soon anyway.
    status = nxd_mqtt_client_publish(&mqtt_client, MQTT_TELEMETRY_TOPIC, STRLEN(MQTT_TELEMETRY_TOPIC),
        buffer, (UINT)length, 0, QOS0, MQTT_PUBLISH_TIMEOUT_TICKS);

    if (status != NXD_MQTT_SUCCESS)
    {
        printf("ERROR: Temperature publish failed (0x%02x)\r\n", status);
    }
}

// Reads the real battery (board) temperature every 1s and publishes it
// over the single MQTT topic, applying whatever fault mode
// display_thread_entry has set from the live (held) button state:
//   MODE_NORMAL       -> publish the real sensor reading; sequence advances
//   MODE_STUCK        -> publish the real reading frozen at the moment
//                         STUCK was entered (captured here, the first tick
//                         the mode is seen); sequence also freezes; both
//                         resume live the instant A is released
//   MODE_DROPOUT      -> no message published at all (the silence IS the
//                         dropout signal - no separate heartbeat channel
//                         anymore); sequence doesn't advance either
//   MODE_OUT_OF_RANGE -> publish a synthetic ramp: starts at the real
//                         reading when A+B were pressed and climbs 20C
//                         per tick up to 160C, then holds, for as long as
//                         A+B are both held; sequence advances normally
//
// IMPORTANT: this thread does NOT block waiting for Wi-Fi before starting
// the sensor/LED/OLED-temperature loop - only actually publishing over
// MQTT needs a network, so that's the only part gated on Wi-Fi being
// ready. The MQTT client create/connect attempt happens at most once,
// inline in the loop below, the first tick Wi-Fi is seen connected -
// connect/publish all use bounded timeouts (not NX_WAIT_FOREVER), and a
// connect failure never returns out of this thread, so an unreachable
// placeholder broker can only ever cost one ~5s pause, never block the
// sensor/LED/publish-decision logic that follows it forever.
static void mqtt_thread_entry(ULONG parameter)
{
    float stuck_value        = 25.0f;
    float ramp_value         = 25.0f;
    float last_real_temp     = 25.0f;
    fault_mode_t last_mode    = MODE_NORMAL;
    // Single rolling counter for the one merged topic/message (0-255, see
    // SEQUENCE_WRAP). Frozen (not advanced) while MODE_STUCK is
    // active - same "frozen" signature as the temperature reading itself -
    // and simply doesn't advance during MODE_DROPOUT since nothing is
    // published then at all.
    ULONG sequence   = 0;
    int user_led_on  = 0;
    // Diagnostic only (doesn't change behavior): detects and logs when
    // hts221_data_read() returns the exact same value many times in a row.
    // Real sensor noise/drift means that basically never happens on a
    // working read; a long run of bit-for-bit identical readings is the
    // signature of lib/mxchip_bsp/stm_sensor/Src/hts221_read_data_polling.c
    // (outside this folder) silently failing its I2C read - it memsets the
    // raw buffer to 0 and then never checks hts221_temperature_raw_get()'s
    // return status, so a failed read reports a fixed "phantom" value from
    // the calibration curve at raw=0 instead of the real temperature.
    float stuck_sensor_last_value = 0.0f;
    int stuck_sensor_repeat_count  = 0;

    printf("Starting MQTT thread\r\n\r\n");

    for (;;)
    {
        // Heartbeat: toggle the board's onboard "User" LED (GPIOC, plain
        // digital on/off - not an I2C call, no mutex needed) every 1s.
        // Placed first in this loop and in this specific thread on
        // purpose: this is the thread whose I2C wait is now bounded (see
        // the i2c_mutex comment above), so it can't be dragged down by a
        // display_thread_entry hang the way a heartbeat living in
        // display_thread_entry itself could be. A steadily blinking User
        // LED means this thread's loop - sensor read, fault mode, LED,
        // MQTT - is genuinely still alive, independent of whether the
        // OLED is currently responding.
        user_led_on = !user_led_on;
        if (user_led_on)
        {
            USER_LED_ON();
        }
        else
        {
            USER_LED_OFF();
        }

        // Try bringing up the MQTT client exactly once, as soon as Wi-Fi
        // is ready - this does NOT block the sensor/LED/OLED loop below,
        // which already runs from the very first tick regardless of
        // Wi-Fi/MQTT state (it owns Wi-Fi bring-up itself in
        // eclipsetx_thread_entry; we don't call wwd_network_init/connect
        // again here).
        if (!mqtt_setup_attempted && wifi_state != WIFI_CONNECTING)
        {
            mqtt_setup_attempted = 1;

            if (wifi_state == WIFI_FAILED)
            {
                printf("WARNING: No Wi-Fi - MQTT publishing disabled, but buttons/OLED still work\r\n");
            }
#if !MQTT_BROKER_CONFIGURED
            else
            {
                // See the MQTT_BROKER_CONFIGURED comment in cloud_config.h:
                // connecting to the still-placeholder broker was observed
                // to correlate with a full system hang. Skipped until a
                // real broker is confirmed and this is flipped to 1.
                printf("WARNING: MQTT_BROKER_CONFIGURED is 0 (placeholder broker) - "
                       "skipping MQTT connect, publishing disabled, buttons/OLED still work\r\n");
            }
#else
            else
            {
                UINT status;
                NXD_ADDRESS server_ip;

                printf("Creating MQTT client\r\n");
                status = nxd_mqtt_client_create(&mqtt_client, MQTT_CLIENT_NAME, MQTT_CLIENT_NAME,
                    STRLEN(MQTT_CLIENT_NAME), &nx_ip, nx_pool, (VOID*)mqtt_client_internal_stack,
                    sizeof(mqtt_client_internal_stack), ECLIPSETX_THREAD_PRIORITY, NX_NULL, 0);

                if (status)
                {
                    printf("ERROR: MQTT client creation failed (0x%02x) - publishing disabled\r\n", status);
                }
                else
                {
                    nxd_mqtt_client_disconnect_notify_set(&mqtt_client, mqtt_disconnect_func);

                    server_ip.nxd_ip_version    = 4;
                    server_ip.nxd_ip_address.v4 = MQTT_LOCAL_BROKER_IP;

                    status = nxd_mqtt_client_connect(
                        &mqtt_client, &server_ip, MQTT_BROKER_PORT, MQTT_KEEP_ALIVE_TIMER, 0, MQTT_CONNECT_TIMEOUT_TICKS);

                    if (status != NXD_MQTT_SUCCESS)
                    {
                        printf("WARNING: MQTT connect failed/timed out (0x%02x) - publishing disabled, "
                               "buttons/OLED still work (check MQTT_LOCAL_BROKER_IP in cloud_config.h)\r\n",
                            status);
                    }
                    else
                    {
                        printf("SUCCESS: MQTT client connected\r\n");
                        mqtt_connected = 1;
                    }
                }
            }
#endif // MQTT_BROKER_CONFIGURED
        }

        // "Her 1 saniyede sıcaklığı oku" (previously 0.5s - slowed down, see the
        // each tick, regardless of fault mode or Wi-Fi/MQTT state, so a
        // fresh value is ready the instant STUCK captures it or
        // DROPOUT/OUT_OF_RANGE end, and the OLED/LED are live immediately
        // at boot without waiting for Wi-Fi.
        //
        // Mutex-protected: this is an I2C transaction on the same bus/HAL
        // handle display_thread_entry's OLED writes use - see i2c_mutex.
        // BOUNDED wait, not TX_WAIT_FOREVER: ssd1306_WriteCommand/WriteData
        // (lib/mxchip_bsp/ssd1306/ssd1306.c, outside this folder) call
        // HAL_I2C_Mem_Write with HAL_MAX_DELAY (no timeout) - if that ever
        // truly hangs inside display_thread_entry's critical section, it
        // holds i2c_mutex forever. Waiting forever here too would drag MQTT
        // publishing, the sensor read, and the LED down with it the moment
        // that happens (observed: a run where the screen AND MQTT both
        // stopped together). With a bounded wait, if the mutex can't be
        // acquired this tick, we just reuse the last known reading and keep
        // publishing/the LED alive - degraded (stale temperature) but not
        // fully frozen.
        if (tx_mutex_get(&i2c_mutex, TX_TIMER_TICKS_PER_SECOND / 2) == TX_SUCCESS)
        {
            recover_i2c_if_stuck();
            last_real_temp = hts221_data_read().temperature_degC;
            tx_mutex_put(&i2c_mutex);
        }
        else
        {
            // Plain printf's "%f" is unreliable in this project (newlib-nano
            // is linked without float-in-printf support; only npf_snprintf,
            // nanoprintf's own formatter, reliably handles floats here - the
            // same reason publish_temperature() builds
            // into a buffer with npf_snprintf instead of calling printf
            // directly). Build the message with npf_snprintf first.
            char warn_buf[96];
            npf_snprintf(warn_buf, sizeof(warn_buf),
                "WARNING: Could not get i2c_mutex for sensor read within 0.5s "
                "- reusing last reading (%.1fC)",
                (double)last_real_temp);
            printf("%s\r\n", warn_buf);
        }
        float real_temp = last_real_temp;

        // Diagnostic: flag a suspiciously long run of bit-identical sensor
        // readings - see the comment on stuck_sensor_last_value above.
        if (real_temp == stuck_sensor_last_value)
        {
            stuck_sensor_repeat_count++;
            // First flagged at ~2s unchanged, then a reminder every ~5s so
            // it doesn't spam the log but stays visible for as long as it
            // continues.
            if (stuck_sensor_repeat_count == 4 || stuck_sensor_repeat_count % 10 == 0)
            {
                // See the npf_snprintf note above - plain printf's "%f" is
                // unreliable here.
                char warn_buf[160];
                npf_snprintf(warn_buf, sizeof(warn_buf),
                    "WARNING: hts221_data_read() returned the exact same value "
                    "(%.1fC) %d times in a row - likely a silent I2C read failure "
                    "in hts221_read_data_polling.c (outside FEVengersApp), not a "
                    "real stable temperature. HAL_I2C_GetState=%d. Attempting a full "
                    "I2C bus recovery.",
                    (double)real_temp, stuck_sensor_repeat_count, (int)HAL_I2C_GetState(&I2cHandle));
                printf("%s\r\n", warn_buf);

                // This is a stronger, evidence-based trigger than
                // recover_i2c_if_stuck()'s HAL_I2C_GetState() check above -
                // a physically stuck slave (the likely cause of a long run
                // of identical readings) doesn't necessarily show up as a
                // non-READY master state, so that check alone can miss it.
                if (tx_mutex_get(&i2c_mutex, TX_TIMER_TICKS_PER_SECOND / 2) == TX_SUCCESS)
                {
                    i2c_bus_recover();
                    tx_mutex_put(&i2c_mutex);
                }
            }
        }
        else
        {
            stuck_sensor_last_value  = real_temp;
            stuck_sensor_repeat_count = 0;
        }

        fault_mode_t mode = fault_mode;

        // Capture the frozen value on the tick STUCK mode is newly entered.
        if (mode == MODE_STUCK && last_mode != MODE_STUCK)
        {
            stuck_value = real_temp;
        }

        // OUT_OF_RANGE ramp: restart from the real reading on the tick the
        // mode is newly entered, then climb one step per tick up to the cap.
        if (mode == MODE_OUT_OF_RANGE)
        {
            if (last_mode != MODE_OUT_OF_RANGE)
            {
                ramp_value = real_temp;
            }
            ramp_value += OUT_OF_RANGE_STEP_C;
            if (ramp_value > OUT_OF_RANGE_MAX_C)
            {
                ramp_value = OUT_OF_RANGE_MAX_C;
            }
        }
        last_mode = mode;

        int fault_active = (mode != MODE_NORMAL);
        set_fault_led(fault_active);

        if (mode == MODE_DROPOUT)
        {
            // No message published at all - this silence (on the single
            // topic) IS the dropout signal now that there's no separate
            // heartbeat channel. displayed_temp intentionally stays at
            // whatever it last was. sequence intentionally does NOT
            // advance either - it's not being used right now.
        }
        else
        {
            float published_temp;
            switch (mode)
            {
                case MODE_STUCK:
                    published_temp = stuck_value;
                    break;
                case MODE_OUT_OF_RANGE:
                    published_temp = ramp_value;
                    break;
                default: // MODE_NORMAL
                    published_temp = real_temp;
                    break;
            }

            displayed_temp = published_temp;

            if (mqtt_connected)
            {
                publish_temperature(published_temp, sequence);
            }

            // Rolling counter: frozen (not advanced) while MODE_STUCK is
            // active - same "frozen" signature as the temperature value
            // itself - resumes counting the instant STUCK ends. Wraps
            // 0-255 instead of growing forever (SEQUENCE_WRAP).
            if (mode != MODE_STUCK)
            {
                sequence = (sequence + 1) % SEQUENCE_WRAP;
            }
        }

        // 1s, not 0.5s: halves I2C bus traffic (sensor read + 1-2 MQTT
        // publishes per tick), on the theory that less-frequent I2C
        // transactions give whatever causes the occasional bus lockup
        // fewer chances to trigger. A mitigation, not a fix by itself -
        // i2c_bus_recover() above is the real fix once a lockup is
        // detected.
        tx_thread_sleep(TX_TIMER_TICKS_PER_SECOND);
    }
}

void tx_application_define(void* first_unused_memory)
{
    systick_interval_set(TX_TIMER_TICKS_PER_SECOND);

    if (tx_mutex_create(&i2c_mutex, "I2C Mutex", TX_NO_INHERIT) != TX_SUCCESS)
    {
        printf("ERROR: I2C mutex creation failed\r\n");
    }

    // Create ThreadX thread
    UINT status = tx_thread_create(&eclipsetx_thread,
        "Eclipse ThreadX Thread",
        eclipsetx_thread_entry,
        0,
        eclipsetx_thread_stack,
        ECLIPSETX_THREAD_STACK_SIZE,
        ECLIPSETX_THREAD_PRIORITY,
        ECLIPSETX_THREAD_PRIORITY,
        TX_NO_TIME_SLICE,
        TX_AUTO_START);

    if (status != TX_SUCCESS)
    {
        printf("ERROR: Eclipse ThreadX thread creation failed\r\n");
    }

    // Create the display/button-polling thread
    UINT status2 = tx_thread_create(&eclipsetx_thread2,
        "Display Thread",
        display_thread_entry,
        0,
        eclipsetx_thread_stack2,
        ECLIPSETX_THREAD_STACK_SIZE,
        ECLIPSETX_THREAD_PRIORITY,
        ECLIPSETX_THREAD_PRIORITY,
        TX_NO_TIME_SLICE,
        TX_AUTO_START);

    if (status2 != TX_SUCCESS)
    {
        printf("ERROR: Display thread creation failed\r\n");
    }

    // Create the MQTT publishing thread
    UINT status3 = tx_thread_create(&mqtt_thread,
        "MQTT Thread",
        mqtt_thread_entry,
        0,
        mqtt_thread_stack,
        MQTT_THREAD_STACK_SIZE,
        ECLIPSETX_THREAD_PRIORITY,
        ECLIPSETX_THREAD_PRIORITY,
        TX_NO_TIME_SLICE,
        TX_AUTO_START);

    if (status3 != TX_SUCCESS)
    {
        printf("ERROR: MQTT thread creation failed\r\n");
    }

    // Create the button-polling thread (see button_thread_entry - kept
    // separate from the OLED-drawing thread so a stuck screen can't delay
    // button/LED responsiveness).
    UINT status4 = tx_thread_create(&button_thread,
        "Button Thread",
        button_thread_entry,
        0,
        button_thread_stack,
        ECLIPSETX_THREAD_STACK_SIZE,
        ECLIPSETX_THREAD_PRIORITY,
        ECLIPSETX_THREAD_PRIORITY,
        TX_NO_TIME_SLICE,
        TX_AUTO_START);

    if (status4 != TX_SUCCESS)
    {
        printf("ERROR: Button thread creation failed\r\n");
    }
}

int main(void)
{
    // Initialize the board
    board_init();

    // Enter the ThreadX kernel
    tx_kernel_enter();

    return 0;
}
