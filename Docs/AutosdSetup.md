# AutoSD image: setup and start

> Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: `claude-opus-5-5`, Anthropic).

Put your copy of the Eclipse AutoSD QEMU image into the `autosd/` folder of the repository and start it with `autosd/autosd.sh`. The image is not in git (3.6 GB); everyone brings their own. The script only starts the image, it does not download or copy one.

## What you need

### 1. The image

| | |
|---|---|
| File to put into this folder | `eclipse-autosd-bootc-qemu-x86_64.qcow2` (3.6 GB, exactly this name) |
| Project | [eclipse-autosd](https://github.com/eclipse-autosd/eclipse-autosd), release `dev` ("Rolling Builds") |
| Published as | `eclipse-autosd-bootc-qemu-x86_64.qcow2.xz`, 424,103,948 bytes |
| Build we use | 2026-10-02 |
| SHA-256 of the `.xz` | `ebf8c0316a573d3aaba6730043aeb800d4bf550aa06f5ce2dd8220277b933cfa` |

The release is rolling: the file behind the same name is replaced by newer builds. Check the checksum before unpacking, so everyone runs the same image:

```bash
sha256sum eclipse-autosd-bootc-qemu-x86_64.qcow2.xz
xz --decompress --keep eclipse-autosd-bootc-qemu-x86_64.qcow2.xz
```

Other AutoSD images (the aarch64 build, the CentOS nightly `developer` image) are not what the scripts in `deploy/` were written and tested for.

What this build contains, to compare with a running image (`./autosd/autosd.sh ssh`):

| Inside the image | Version | Check with |
|---|---|---|
| OS | Automotive Stream Distribution 10 | `cat /etc/os-release` |
| Image build time | 2026-10-02T15:59:54Z | `bootc status` |
| Kernel | 6.12.0-270.el10iv.x86_64 | `uname -r` |
| Podman | 6.1.0 | `podman --version` |
| Python | 3.12.14 | `python3 --version` |

### 2. Programs on your machine

Versions are the ones this was tested with (Ubuntu 22.04, x86_64). Only OpenSSH has a known minimum.

| Program | Tested version | Needed for | Ubuntu package |
|---|---|---|---|
| QEMU (`qemu-system-x86_64`) | 6.2.0 | Running the image | `qemu-system-x86` |
| OVMF (UEFI firmware) | 2022.02 | Booting the image | `ovmf` |
| KVM (`/dev/kvm`) | – | Speed; without it AutoSD runs emulated and very slowly | part of the kernel; your user must be in the `kvm` group |
| OpenSSH client | 8.9 (minimum 8.4) | Shell and all `deploy/` scripts; 8.4 added the password helper they use | `openssh-client` |
| Python 3 | 3.10 | Clean shutdown of AutoSD | `python3` |
| iproute2 (`ss`, `ip`) | 5.15 | Finding busy ports and this machine's address | `iproute2` |
| Bash | 5.1 | The scripts | `bash` |
| Podman, or Docker | Podman 3.4.4 | Building the service images (`deploy/build-images.sh`) | `./deploy/install-build-deps.sh` installs Podman |

```bash
sudo apt install qemu-system-x86 ovmf openssh-client python3 iproute2
./autosd/autosd.sh check     # reports what is still missing
```

Optional, for testing the MQTT path by hand: `mosquitto-clients` (2.0.11).

### 3. Installed into the image by our scripts

Not part of the stock image; added once per image by `./deploy/setup-autosd.sh`.

| Program | Version | Check with |
|---|---|---|
| Eclipse Ankaios (`ank`, `ank-server`, `ank-agent`) | v1.0.4 | `ank --version` inside AutoSD, or `./deploy/setup-autosd.sh --check` |

The MQTT broker (`docker.io/library/eclipse-mosquitto:2`) and our services are containers; `./deploy/deploy-to-autosd.sh` loads them.

## Start

```bash
./autosd/autosd.sh          # (re)start AutoSD and open a shell inside it
./autosd/autosd.sh check    # can this machine start it? changes nothing
./autosd/autosd.sh ssh      # shell inside the running AutoSD, without restarting it
./autosd/autosd.sh status
./autosd/autosd.sh stop
```

Starting always gives a fresh instance:

| Situation | What the script does |
|---|---|
| AutoSD is already running | Shuts it down cleanly, then boots it again |
| Another program holds a needed port (2222, 1883, 7690) | Stops it: another QEMU is asked to shut its guest down first, a systemd service (e.g. Mosquitto) is stopped with `sudo systemctl stop`, anything else is terminated |
| After boot | Opens a root shell inside AutoSD; `exit` leaves it, AutoSD keeps running |

Restarting AutoSD restarts the MQTT broker, so the board must be reset afterwards (see below). To only get a shell, use `ssh`.

## Ports

| Host | AutoSD | Used for |
|---|---|---|
| 2222 (this machine only) | 22 | SSH; `deploy/` scripts connect here |
| 1883 | 1883 | MQTT broker: the AZ3166 board publishes here |
| 7690 | 7690 | OpenSOVD gateway: faults on `http://localhost:7690/sovd/v1/apps/battery/faults`, fault monitor page on `http://localhost:7690/ui/` |

## MQTT data from the board

```
AZ3166 --Wi-Fi--> <this machine>:1883 --QEMU forward--> AutoSD:1883 (mqtt-broker) --> vss-publisher
```

| Requirement | Why |
|---|---|
| Nothing else on host port 1883 | With a local Mosquitto on 1883 the board talks to that one and nothing reaches AutoSD. Starting stops it; to keep it from coming back at boot: `sudo systemctl disable mosquitto` |
| Board and this machine on the same network | The board sends to a fixed address, compiled into the firmware |
| `MQTT_LOCAL_BROKER_IP` in the firmware = this machine's address | The script prints the address to use when it starts, and with `status`. It comes from DHCP: after changing network, or a new lease, the firmware must be rebuilt |
| Topic `FEVengers_MQTT/telemetry` | The firmware's topic; `vss-publisher` subscribes to it |

The firmware connects once and does not reconnect: after restarting AutoSD or the broker, reset the board.

## Next steps

```bash
./deploy/setup-autosd.sh       # once: install Ankaios in the image
./deploy/build-images.sh       # build the service images
./deploy/deploy-to-autosd.sh   # load them, start the workloads, keep them across reboots
```

After that the five workloads start by themselves every time the image boots. When only the configuration changed and the images are already in AutoSD, `./deploy/deploy-to-autosd.sh --no-build` skips loading them again.

Details: [BUILD_IMAGES.md](BUILD_IMAGES.md).

## Status

| Item | State |
|---|---|
| `check`, `status`, missing image | Run |
| Freeing a port: plain program, and a QEMU (shutdown request, then terminated after 30 s) | Run on throwaway processes |
| Freeing a port held by a systemd service or another user's program (needs sudo) | Not tested |
| Boot from this folder, `ssh`, `status`, MQTT round trip through host port 1883 | Run |
| `stop`, `console`, `--snapshot` | Taken over from the script used for the team's image so far; not run from this folder |
