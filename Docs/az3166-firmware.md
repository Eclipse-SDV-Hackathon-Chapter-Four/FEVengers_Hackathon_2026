# AZ3166 Firmware: build and flash

> Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: `claude-opus-5-5`, Anthropic).

The firmware that runs on the MXChip AZ3166 board: the temperature source of the whole chain. It reads the onboard temperature sensor, publishes it over MQTT once per second, and injects faults while a button is held.

Code: [`az3166-firmware/`](../az3166-firmware/), the application itself in [`az3166-firmware/app/FEVengersApp/`](../az3166-firmware/app/FEVengersApp/)

This is the firmware the board is flashed with. [`Threadx_AZ3166_MQTT_Temp_Source.md`](Threadx_AZ3166_MQTT_Temp_Source.md) describes another variant that is not on the board; see [section 8](#8-not-the-variant-of-threadx_az3166_mqtt_temp_sourcemd).

---

## 1. Where it sits

```
AZ3166 (this firmware) --MQTT over Wi-Fi--> <machine running AutoSD>:1883 --> mqtt-broker --> vss-publisher --> guardian
```

| | |
|---|---|
| RTOS and network stack | Eclipse ThreadX, NetX Duo |
| Sensor | HTS221 (temperature), read once per second |
| MQTT topic | `FEVengers_MQTT/telemetry`, no TLS, no user or password, port 1883 |
| Message | `{"temperature_degC": 25.6, "counter": 12}` |
| `counter` | Rolling counter, 0 to 255, then 0 again |

The [VSS uProtocol Publisher](vss-uprotocol-publisher.md) reads exactly these two fields.

## 2. What you need

| | |
|---|---|
| Board | MXChip AZ3166, connected over USB |
| Wi-Fi | A 2.4 GHz network; the board does not support 5 GHz. The machine that runs AutoSD must be on the same network |
| CMake, Ninja | `sudo apt install cmake ninja-build` |
| Arm GNU Toolchain | 13.3.rel1 (`arm-none-eabi-gcc`), not in the Ubuntu packages in this version |

Toolchain, unpacked to `/opt`:

```bash
wget https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi.tar.xz
sudo tar xJf arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi.tar.xz -C /opt
export PATH=$PATH:/opt/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin   # also into ~/.bashrc
arm-none-eabi-gcc --version
```

These tools are not installed by `deploy/install-host-deps.sh` or `deploy/setup-all.sh`: only the person who flashes the board needs them.

## 3. Get the source

ThreadX and NetX Duo are git submodules of this repository (about 270 MB). They are needed only to build the firmware:

```bash
git submodule update --init
```

| Submodule | Commit |
|---|---|
| `az3166-firmware/deps/lib/threadx` | `af3c1e72` |
| `az3166-firmware/deps/lib/netxduo` | `6c8e9d1c` |

## 4. Configure

Edit [`az3166-firmware/app/FEVengersApp/cloud_config.h`](../az3166-firmware/app/FEVengersApp/cloud_config.h):

| Setting | Value |
|---|---|
| `WIFI_SSID`, `WIFI_PASSWORD` | Your Wi-Fi network. Empty in the repository: without them the board does not connect |
| `WIFI_MODE` | `WPA2_PSK_AES` unless the network differs |
| `MQTT_LOCAL_BROKER_IP` | Address of the machine that runs AutoSD, written as `IP_ADDRESS(192, 168, 88, 248)`. `./autosd/autosd.sh status` prints the address to use |
| `MQTT_TELEMETRY_TOPIC` | `FEVengers_MQTT/telemetry`; leave it, the publisher subscribes to this topic |

The address is compiled into the firmware. It comes from DHCP: after a change of network, or a new lease for the AutoSD machine, set it again, rebuild and flash.

Do not commit the Wi-Fi password. To keep git from offering the file for commit after you filled it in:

```bash
git update-index --skip-worktree az3166-firmware/app/FEVengersApp/cloud_config.h
```

(`--no-skip-worktree` undoes it.)

## 5. Build

```bash
cd az3166-firmware
./scripts/build.sh FEVengersApp clean
```

| | |
|---|---|
| Result | `az3166-firmware/build/app/mxchip_threadx.bin` |
| `clean` | Needed the first time, and whenever `build/` holds another configuration (`starter`, `mqtt`, ...): without it the old one is rebuilt. Later builds: `./scripts/build.sh FEVengersApp` |
| Duration | About 15 seconds |
| End of the output | `[OK] Build completed successfully!` |

## 6. Flash

Connect the board over USB. It appears as a small drive labelled `AZ3166`; no ST-Link or other flashing tool is needed.

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT    # find the row with LABEL AZ3166
./scripts/deploy.sh /media/$USER/AZ3166       # the mount point of that row
```

Copying the file starts the bootloader: the board resets and runs the new firmware. `deploy.sh` only copies, it does not build. If the drive is not mounted, open it once in the file manager.

## 7. Check

| Where | What to see |
|---|---|
| Display, line 2 | `WiFi:V MQTT:V` (`-` while connecting, `X` when it failed) |
| User LED | Blinks every 0.5 s while the firmware runs |
| RGB LED | Green without a fault, red while a fault mode is active |
| Serial port, 115200 baud | Boot log with the board's IP address and the MQTT connection result (`screen /dev/ttyACM0 115200`) |
| On the AutoSD machine | `mosquitto_sub -h 127.0.0.1 -p 1883 -t 'FEVengers_MQTT/telemetry' -v` prints one message per second |
| Evidence collector | `http://localhost:7700/`: the live tiles show the temperature and the counter |

The firmware connects to the broker once and does not reconnect: after a restart of AutoSD or of the broker, reset the board.

| Problem | Cause |
|---|---|
| `WiFi:X` | Wrong SSID or password, or a 5 GHz network |
| `WiFi:V MQTT:X` | Wrong `MQTT_LOCAL_BROKER_IP`, AutoSD not running, another subnet, or a firewall on the AutoSD machine (`sudo ufw allow 1883/tcp`) |
| Messages arrive on another broker | A local Mosquitto on port 1883 of the AutoSD machine; `./autosd/autosd.sh` stops it at start |

### Buttons: fault injection

A fault mode is active only while the button is held, and ends when it is released.

| Held | Mode on the display | Temperature sent | Counter | What the Guardian sees |
|---|---|---|---|---|
| nothing | `MODE: NORMAL` | Sensor reading | +1 per message | Valid stream |
| A | `MODE: STUCK` | Frozen at the reading when A was pressed | Frozen | Same counter again and again: `TransportDuplicate`, after `stuck_window_ms` `TempSignalStuck` |
| B | `MODE: DROPOUT` | Nothing is sent | Does not advance | No message: after `stale_timeout_ms` `TempSourceConnectionLost` |
| A and B | `MODE: OUT OF RNG` | Starts at the sensor reading, +20 °C per message up to 160 °C, then stays there | +1 per message | A fast rise through the warning and critical thresholds, then above `max_c` (150 °C): `TempOutOfRange` |

A and B together take priority over a single button. The Guardian column follows the rules in [`battery-thermal-guardian.md`](battery-thermal-guardian.md), sections State machine and Signal integrity.

More on the display, the LEDs and the threads: [`az3166-firmware/app/FEVengersApp/SETUP.md`](../az3166-firmware/app/FEVengersApp/SETUP.md).

## 8. Not the variant of `Threadx_AZ3166_MQTT_Temp_Source.md`

That document describes changes to the `app/mqtt` sample of the same ThreadX repository. Its code is not in this repository and is not what the board runs. The differences:

| | This firmware (`app/FEVengersApp`) | `Threadx_AZ3166_MQTT_Temp_Source.md` (`app/mqtt`) |
|---|---|---|
| Message | `temperature_degC`, `counter` | Also pressure, humidity, acceleration, magnetic field |
| Button A | STUCK: temperature and counter frozen | Fixed 85 °C, counter continues |
| Button B | DROPOUT: nothing sent | Temperature held, counter paused |
| A and B | Ramp, +20 °C per message up to 160 °C | One jump of +20 °C, then held |
| Temperature sensor | HTS221 | LPS22HB |

Topic, port and the two fields the publisher reads are the same in both.

## 9. Where the code comes from

`az3166-firmware/` is the folder `MXChip/AZ3166/` of [eclipse-threadx/samplex](https://github.com/eclipse-threadx/samplex) at commit `c1adc67`, under the MIT licence (`az3166-firmware/LICENSE`; the ST, CMSIS and SSD1306 parts keep their own licence files), with these changes:

| File | Change |
|---|---|
| `app/FEVengersApp/` | New: the application (`main.c`, `cloud_config.h`) and its notes |
| `app/CMakeLists.txt` | Registers the configuration `FEVengersApp` |
| `lib/mxchip_bsp/ssd1306/ssd1306.c` | I2C writes to the display time out after 100 ms instead of waiting forever |
| `lib/mxchip_bsp/stm_sensor/Src/hts221_read_data_polling.c` | The data-ready timeout is reset on every read; a failed I2C read keeps the last good value instead of producing a fixed wrong one |
| `.gitignore` | New: ignores `build/`, keeps the prebuilt Wi-Fi library `lib/wiced_sdk/lib/libwiced_sdk_bin.a` |

The two driver fixes are explained in [`OUTSIDE_FOLDER_CHANGES.md`](../az3166-firmware/app/FEVengersApp/OUTSIDE_FOLDER_CHANGES.md). The other configurations of the upstream folder (`starter`, `arcade`, `telemetry`, `mqtt`) are unchanged and not used. `az3166-firmware/README.md` is the upstream README.

## 10. Status

| Item | State |
|---|---|
| Build of `FEVengersApp` from the files in this repository (the tracked files and the two submodules, copied to an empty folder) | Run: `[OK] Build completed successfully!`, 14 s, `mxchip_threadx.bin` 343,856 bytes, Arm GNU Toolchain 13.3.rel1, CMake 3.22.1, Ninja 1.10.1, Ubuntu 22.04 |
| Flash, Wi-Fi and MQTT connection, data through to the Guardian, the three fault modes | Run with the board from the working copy this code was taken from (same sources, with the Wi-Fi settings filled in). Not repeated from this repository |
| `git submodule update --init` in a fresh clone | Not run |
| Build on Windows or macOS (`build.ps1`, `deploy.ps1`) | Not run |
