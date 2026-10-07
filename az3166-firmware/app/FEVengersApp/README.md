# FEVengersApp

> Generated with AI assistance (Claude Sonnet 5, model id: `claude-sonnet-5`).

Team FEVengers' app for the MXChip AZ3166 board. See [SETUP.md](SETUP.md) for
the background (why a new `elseif(APP_CONFIG STREQUAL "FEVengersApp")` block
was added to `app/CMakeLists.txt`, screen/Wi-Fi behavior, color limitation).
This file is just the quick compile/flash cheat-sheet with real example
commands.

## Compile

From `MXChip/AZ3166/`:

```bash
# Linux/macOS
./scripts/build.sh FEVengersApp
```

```powershell
# Windows
.\scripts\build.ps1 -Config FEVengersApp
```

If you (or a teammate) already built another config (e.g. `starter`) in this
same `build/` folder, add `clean` the first time you switch, otherwise the
old config gets silently rebuilt instead:

```bash
./scripts/build.sh FEVengersApp clean
```

Example of a verified successful run:

```
$ ./scripts/build.sh FEVengersApp clean
...
[1144/1144] ... arm-none-eabi-objcopy -Obinary mxchip_threadx.elf mxchip_threadx.bin
==========================================
[OK] Build completed successfully!
Build time: 13s
==========================================
```

Output binary: `MXChip/AZ3166/build/app/mxchip_threadx.bin`.

## Flash

Plug the AZ3166 into USB — it mounts as a removable drive (no ST-Link /
OpenOCD / DFU needed).

Find the mount path:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

Look for the row with `LABEL` = `AZ3166`. On this machine it showed up as:

```
sda   1M  vfat  AZ3166  /media/sinanc/AZ3166
```

Then deploy with that path:

```bash
# Linux/macOS - replace with YOUR mount path from lsblk/df
./scripts/deploy.sh /media/sinanc/AZ3166
```

```powershell
# Windows - replace with the board's drive letter
.\scripts\deploy.ps1 -Destination D:
```

Copying the `.bin` triggers the bootloader; the board resets and runs the
new code automatically.

## Monitor serial output

Connect to the board's serial port at **115200 baud** (Tera Term on Windows,
`screen`/`minicom`/SerialTools on Linux/macOS) to see boot and Wi-Fi
connection logs.
