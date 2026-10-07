# Disclaimer
Generated with AI assist
GitHub Copilot

> **Not the firmware on the board.** This document describes changes to the `app/mqtt` sample of the ThreadX repository; that code is not in this repository. The board is flashed with the application `FEVengersApp`, kept as a patch in [`az3166-firmware/`](../az3166-firmware/), whose buttons and message differ from what is described below. How to build and flash it, and a table of the differences: [`az3166-firmware.md`](az3166-firmware.md).

## Eclipse SDV Hackathon: FEVengers MQTT Demo

This section documents the FEVengers hackathon changes to the original MXChip AZ3166 MQTT sample in this repository. The `mqtt` build configuration remains based on Eclipse ThreadX and NetX Duo; the additions provide local-broker telemetry, an OLED status display, and button-driven fault injection.

### Changes from the original sample

- Configured the MQTT application for the hackathon Wi-Fi network and a local MQTT broker. The board still obtains its own IP address from the access point using DHCP.
- Set the MQTT client ID to `FEVengers_MQTT`; telemetry is published to `FEVengers_MQTT/telemetry`.
- Changed telemetry publishing to run once per second, whether or not the sensor readings changed.
- Changed the published payload from formatted text to a JSON object containing pressure, temperature, humidity, three-axis acceleration, three-axis magnetic field, and the rolling counter.
- Added a display thread. The monochrome 128×64 OLED shows the FEVengers title, Wi-Fi and MQTT connection states, the displayed temperature, and the rolling counter.
- Added button-driven fault injection and RGB LED status indication (details below).

### MQTT connection and telemetry

The MQTT settings are in `app/mqtt/cloud_config.h`. Set `WIFI_SSID`, `WIFI_PASSWORD`, `WIFI_MODE`, and `MQTT_LOCAL_BROKER_IP` for the target environment before building. The broker address is an example environment-specific setting, not the board's address. Do not commit real Wi-Fi credentials or broker secrets to a shared repository.

The MQTT client uses the non-TLS MQTT port `1883` and currently connects without MQTT username/password. Configure the broker to allow the intended client connection, or extend the client and configuration with credentials and TLS as required by the deployment. Do not expose an anonymous, non-TLS broker to untrusted networks or the public Internet.

For a Mosquitto broker running inside a QEMU user-networked VM, the host can forward TCP port `1883` to the VM. Configure Mosquitto in the VM to listen on a network interface (not only `127.0.0.1`), and set `MQTT_LOCAL_BROKER_IP` to the host's reachable LAN address. The VM's private QEMU address is not normally reachable directly from the board.

Subscribe to the telemetry topic with MQTT Explorer or the command-line client:

```sh
mosquitto_sub -h <broker-host> -p 1883 -t 'FEVengers_MQTT/telemetry' -v
```

Each published payload is a single-line JSON object with this schema:

```json
{
  "pressure_hPa": 1013.25,
  "temperature_degC": 23.40,
  "humidity_perc": 45.60,
  "acceleration_mg": [0.10, 0.20, 0.30],
  "magnetic_mG": [1.00, 2.00, 3.00],
  "counter": 12
}
```

The numbers above are illustrative. `counter` is an unsigned 8-bit rolling value (`0`–`255`) that wraps back to `0`. The temperature field contains the active fault-injection value when a button fault is active; the other fields continue to report sensor readings.

### OLED, buttons, and fault injection

The AZ3166 OLED is monochrome, so the title is displayed in white rather than orange. The RGB LED provides the colored indication:

| Button state | RGB LED | Displayed and published temperature | Rolling counter |
| --- | --- | --- | --- |
| Neither button pressed | Green, blinking with a one-second on/off cadence | Live LPS22HB sensor reading | Increments once per second |
| Button A only | Solid green | Fixed test value of `85 °C` until A is released | Continues incrementing |
| Button B only | Solid red | Holds the measured temperature from when B was pressed | Paused until B is released |
| A and B together | Orange | Jumps to the measured temperature plus `20 °C`, then holds that value until both buttons are released | Continues incrementing while both are pressed |

When both buttons are held and only one is released, the injected temperature remains held until both are released. If B remains pressed by itself after A is released, the counter then pauses according to the Button B-only behavior.

### Build, flash, and verify

From the AZ3166 project directory, build the MQTT configuration:

```sh
./scripts/build.sh mqtt
```

The firmware image is generated at `build/app/mxchip_threadx.bin`. Connect the AZ3166 over USB and copy the image to its mounted bootloader drive. On Linux, for example:

```sh
./scripts/deploy.sh /run/media/$USER/AZ3166
```

The deployment script only copies the firmware; it does not build it. Reset the board if it does not restart automatically after the copy. The serial console uses `115200` baud. Its startup log reports the DHCP-assigned board IP and MQTT connection/publish results. The board IP is distinct from the MQTT broker IP.

Relevant implementation files:

- `app/mqtt/cloud_config.h` — Wi-Fi and broker configuration, MQTT client ID and topics.
- `app/mqtt/main.c` — ThreadX application and telemetry, MQTT, and display thread startup.
- `app/mqtt/telemetry.c` / `app/mqtt/telemetry.h` — sensor sampling and JSON payload construction.
- `app/mqtt/mqtt_client.c` / `app/mqtt/mqtt_client.h` — MQTT session, display refresh, button fault behavior, counter, and RGB LED indication.
