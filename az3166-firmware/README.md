<!--
  Copyright (c) 2024 Eclipse Foundation
  Copyright (c) 2026 FEVengers contributors

  This program and the accompanying materials are made available
  under the terms of the MIT license which is available at
  https://opensource.org/license/mit.

  SPDX-License-Identifier: MIT

  Contributors:
      Frédéric Desbiens - Initial version.
      Andy Riexinger - Documentation for Mac M1.
      FEVengers - Rewritten for the FEVengersApp configuration.

  Rewritten with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
-->

# AZ3166 Firmware: FEVengersApp

Firmware of the MXChip AZ3166 board, the temperature source of the Doctor Whodunit chain. It reads the onboard temperature sensor, publishes the reading over MQTT once per second, and injects faults while a button is held.

It is built on Eclipse ThreadX and NetX Duo. This folder is `MXChip/AZ3166/` of [eclipse-threadx/samplex](https://github.com/eclipse-threadx/samplex) at commit `c1adc67`, with our application `FEVengersApp` added.

```
AZ3166 (this firmware) --MQTT over Wi-Fi--> <machine running AutoSD>:1883 --> mqtt-broker --> vss-publisher --> guardian
```

| | |
|---|---|
| Application | [`app/FEVengersApp/`](app/FEVengersApp/) (`main.c`, `cloud_config.h`) |
| MQTT topic | `FEVengers_MQTT/telemetry`, port 1883, no TLS, no user or password |
| Message, once per second | `{"temperature_degC": 25.6, "counter": 12}` |
| `counter` | Rolling counter, 0 to 255, then 0 again |
| Sensor | HTS221 |

The full description, with the checks and what differs from upstream: [`Docs/az3166-firmware.md`](../Docs/az3166-firmware.md).

## From a fresh clone to a running board

All commands from the root of the repository unless a `cd` says otherwise.

### 1. Tools

The board supports only 2.4 GHz Wi-Fi. The board and the machine that runs AutoSD must be on the same network.

**Ubuntu**

```bash
sudo apt install cmake ninja-build
wget https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi.tar.xz
sudo tar xJf arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi.tar.xz -C /opt
export PATH=$PATH:/opt/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin   # also into ~/.bashrc
arm-none-eabi-gcc --version
```

**Windows**

```
winget install --id=Arm.GnuArmEmbeddedToolchain  -e
winget install --id=Ninja-build.Ninja  -e
winget install --id=Kitware.CMake  -e
```

**macOS (M1)**: Arm GNU Toolchain 14.2.rel1, [arm-gnu-toolchain-14.2.rel1-darwin-arm64-arm-none-eabi.pkg](https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-darwin-arm64-arm-none-eabi.pkg), plus CMake and Ninja.

We build on Ubuntu 22.04 with Arm GNU Toolchain 13.3.rel1, CMake 3.22.1 and Ninja 1.10.1. Windows and macOS are the upstream instructions and were not run by us.

### 2. Submodules

ThreadX and NetX Duo are git submodules (about 270 MB):

```bash
git submodule update --init
```

### 3. Start AutoSD

The MQTT broker runs inside AutoSD. Without it the board has nothing to connect to.

```bash
./autosd/autosd.sh start
./autosd/autosd.sh status     # prints the address for step 4
```

On a machine that is not set up yet: `./deploy/setup-all.sh` (see [`Docs/AutosdSetup.md`](../Docs/AutosdSetup.md)).

### 4. Wi-Fi and broker address

Edit [`app/FEVengersApp/cloud_config.h`](app/FEVengersApp/cloud_config.h). `WIFI_SSID` and `WIFI_PASSWORD` are empty in the repository: without them the board does not connect.

```c
#define WIFI_SSID     "your network"
#define WIFI_PASSWORD "your password"
#define WIFI_MODE     WPA2_PSK_AES

#define MQTT_LOCAL_BROKER_IP   (IP_ADDRESS(192, 168, 88, 248))
```

| Setting | Value |
|---|---|
| `WIFI_SSID`, `WIFI_PASSWORD` | Your 2.4 GHz network |
| `MQTT_LOCAL_BROKER_IP` | Address of the machine that runs AutoSD, as printed by `./autosd/autosd.sh status`. Written with commas, not dots |
| `MQTT_TELEMETRY_TOPIC` | Leave it: the publisher subscribes to `FEVengers_MQTT/telemetry` |

The address is compiled into the firmware. After a change of network, or a new DHCP lease for the AutoSD machine, set it again, build and flash.

Do not commit the Wi-Fi password. To keep git from offering the file for commit:

```bash
git update-index --skip-worktree az3166-firmware/app/FEVengersApp/cloud_config.h
```

### 5. Build

```bash
cd az3166-firmware
./scripts/build.sh FEVengersApp clean
```

Windows: `.\scripts\build.ps1 -Config FEVengersApp`

The output ends with `[OK] Build completed successfully!` and the firmware is `build/app/mxchip_threadx.bin`. `clean` is needed the first time and whenever `build/` holds another configuration; without it the old one is rebuilt.

### 6. Flash

Connect the board over USB. It appears as a small drive labelled `AZ3166`; no flashing tool is needed.

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT    # the row with LABEL AZ3166
./scripts/deploy.sh /media/$USER/AZ3166       # the mount point of that row
```

Windows: `.\scripts\deploy.ps1 -Destination D:` (the board's drive letter)

Copying the file starts the bootloader: the board resets and runs the new firmware.

### 7. Check

| Where | What to see |
|---|---|
| Display, line 2 | `WiFi:V MQTT:V` (`-` while connecting, `X` when it failed) |
| User LED | Blinks every 0.5 s |
| RGB LED | Green without a fault, red while a fault mode is active |
| On the AutoSD machine | `mosquitto_sub -h 127.0.0.1 -p 1883 -t 'FEVengers_MQTT/telemetry' -v` prints one message per second |
| Evidence collector | `http://localhost:7700/`: the live tiles show temperature and counter |
| Serial port, 115200 baud | Boot log: the board's IP address, the MQTT connection result |

| Problem | Cause |
|---|---|
| `WiFi:X` | Wrong or empty SSID or password, or a 5 GHz network |
| `WiFi:V MQTT:X` | Wrong `MQTT_LOCAL_BROKER_IP`, AutoSD not running, another subnet, or a firewall on the AutoSD machine (`sudo ufw allow 1883/tcp`) |
| It worked, then no data after a restart of AutoSD | The firmware connects once and does not reconnect: reset the board |

## Buttons: fault injection

A fault mode is active only while the button is held, and ends when it is released.

| Held | Display | Temperature sent | Counter |
|---|---|---|---|
| nothing | `MODE: NORMAL` | Sensor reading | +1 per message |
| A | `MODE: STUCK` | Frozen at the reading when A was pressed | Frozen |
| B | `MODE: DROPOUT` | Nothing is sent | Does not advance |
| A and B | `MODE: OUT OF RNG` | Starts at the sensor reading, +20 °C per message up to 160 °C, then stays there | +1 per message |

A and B together take priority over a single button. What the Guardian reports for each mode: [`Docs/az3166-firmware.md`](../Docs/az3166-firmware.md), section 7.

## The board

[MXChip AZ3166](https://docs.mxchip.com/en/nr6ggk/blyezpv6gkqicywi.html) with an STM32F412RG MCU (100 MHz, 1 MB flash, 256 KB SRAM). Of its hardware the firmware uses:

| Hardware | Used for |
|---|---|
| HTS221 temperature and humidity sensor | The temperature that is published |
| 128×64 OLED display (SSD1306, monochrome) | Title, Wi-Fi and MQTT state, buttons, fault mode, temperature |
| Buttons A and B | Fault modes |
| RGB LED, User LED | Fault indication, heartbeat |
| Wi-Fi (2.4 GHz only) | MQTT |

## What is in this folder

| Path | Content |
|---|---|
| `app/FEVengersApp/` | Our application, with its notes: [`README.md`](app/FEVengersApp/README.md) (build and flash in short), [`SETUP.md`](app/FEVengersApp/SETUP.md) (display, threads, fault modes, bug log), [`OUTSIDE_FOLDER_CHANGES.md`](app/FEVengersApp/OUTSIDE_FOLDER_CHANGES.md) (two driver fixes in `lib/mxchip_bsp/`) |
| `app/common/` | Board initialisation and display helpers, shared with the upstream samples |
| `app/starter/`, `app/telemetry/`, `app/mqtt/`, `app/arcade/` | Upstream sample configurations, unchanged and not used by us |
| `lib/` | Board support package, STM32 HAL, Wi-Fi driver |
| `deps/lib/threadx`, `deps/lib/netxduo` | Submodules |
| `scripts/` | `build.sh`, `deploy.sh` and their PowerShell versions |
| `cmake/`, `CMakeLists.txt` | Build configuration and toolchain file |
| `LICENSE` | MIT, from eclipse-threadx/samplex. The ST, CMSIS and SSD1306 parts keep their own licence files |

Eclipse ThreadX documentation: [https://github.com/eclipse-threadx/rtos-docs](https://github.com/eclipse-threadx/rtos-docs)
