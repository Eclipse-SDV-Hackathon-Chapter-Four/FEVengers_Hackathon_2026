# AutoSD image: setup and start

> Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: `claude-opus-5-5`, Anthropic).

On a new machine, one command sets up everything, from a fresh clone to the running system:

```bash
./deploy/setup-all.sh           # do every step that is not done yet
./deploy/setup-all.sh --check   # only report, change nothing
```

| Step | Script (can also be run alone) | What it sets up |
|---|---|---|
| 1 | `./deploy/install-host-deps.sh` | Packages on this machine (section 2): QEMU, OVMF and the other programs the scripts call, and Podman to build the service images |
| 2 | `./autosd/autosd.sh setup` | The AutoSD image (section 1), downloaded into `autosd/` |
| 3 | `./autosd/autosd.sh start` | Boots AutoSD; one that is already running is kept |
| 4 | `./deploy/setup-autosd.sh` | Ankaios inside AutoSD (section 3) |
| 5 | `./deploy/build-images.sh` | The service images (first time about 20 minutes; `--no-build` skips it) |
| 6 | `./deploy/deploy-to-autosd.sh` | Loads the images, starts the six workloads, keeps them across reboots |

Every step leaves alone what is already there, so it can be run again after a failure. It needs internet and may ask for the sudo password (package install).

The image is not in git (3.6 GB). `autosd/autosd.sh` downloads it on the first start, or with `setup`; an image that is already in `autosd/` is never downloaded again or replaced. The rest of this page describes what the scripts do, and how to do it by hand.

## What you need

### 1. The image

| | |
|---|---|
| File to put into this folder | `eclipse-autosd-bootc-qemu-x86_64.qcow2` (3.6 GB, exactly this name) |
| Project | [eclipse-autosd](https://github.com/eclipse-autosd/eclipse-autosd), release `dev` ("Rolling Builds") |
| Published as | `eclipse-autosd-bootc-qemu-x86_64.qcow2.xz`, 424,103,948 bytes |
| Build we use | 2026-10-02 |
| SHA-256 of the `.xz` | `ebf8c0316a573d3aaba6730043aeb800d4bf550aa06f5ce2dd8220277b933cfa` |

The release is rolling: the file behind the same name is replaced by newer builds. The script checks the download against this checksum, so everyone runs the same image; if upstream has replaced the build it stops and says so (`IMAGE_SHA256=<new checksum>` accepts another build, a `.qcow2.xz` copied into `autosd/` from a teammate is used instead of downloading). By hand:

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

`./deploy/install-host-deps.sh` installs all of them:

```bash
./deploy/install-host-deps.sh             # install what is missing; changes nothing if all is there
./deploy/install-host-deps.sh --run-only  # only the group "run"
./deploy/install-host-deps.sh --check     # only report what is missing
```

| Group | Needed by | Commands checked | Ubuntu / Debian packages |
|---|---|---|---|
| run | `autosd/autosd.sh`, `deploy/setup-autosd.sh`, `deploy/deploy-to-autosd.sh` | `qemu-system-x86_64`, OVMF firmware, `ssh`, `python3`, `ss`, `ip`, `curl`, `xz`, `sha256sum`, `tar`, `awk`, `sed`, `grep`, `ps`, `df`, `timeout` | `qemu-system-x86 ovmf openssh-client python3 iproute2 curl xz-utils tar gawk sed grep procps coreutils` |
| tools | Commands used by hand in the documents | `jq`, `column` (`opensovd-gateway-dfm/fault_host.sh`), `mosquitto_pub`, `mosquitto_sub` (test reading without the board) | `jq bsdextrautils mosquitto-clients` |
| build | `deploy/build-images.sh` | a working `podman` or `docker` | installed and tested by `./deploy/install-build-deps.sh`, which this script calls |

| | |
|---|---|
| Package managers | `apt` (Ubuntu, Debian) and `dnf` (Fedora); the package names for each are at the top of the script. The team works on Ubuntu |
| sudo | Asked only when something is missing |
| KVM | If `/dev/kvm` exists but you may not use it, the script adds you to the group `kvm`; log out and in again afterwards |
| Other system | The script stops and names the missing programs; install them by hand, then `--check` |

`./autosd/autosd.sh setup` (and the first start) calls it with `--run-only` when a program is missing, then downloads the image. `./autosd/autosd.sh check` reports what is still missing and changes nothing.

### 3. Installed into the image by our scripts

Not part of the stock image; added once per image by `./deploy/setup-autosd.sh`.

| Program | Version | Check with |
|---|---|---|
| Eclipse Ankaios (`ank`, `ank-server`, `ank-agent`) | v1.0.4 | `ank --version` inside AutoSD, or `./deploy/setup-autosd.sh --check` |

The MQTT broker (`docker.io/library/eclipse-mosquitto:2`) and our services are containers; `./deploy/deploy-to-autosd.sh` loads them.

## Start

```bash
./autosd/autosd.sh          # (re)start AutoSD and open a shell inside it
./autosd/autosd.sh start    # the same, without the shell
./autosd/autosd.sh setup    # programs and image only, starts nothing
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
| 7700 | 7700 | Evidence collector: start and stop an evidence run on `http://localhost:7700/` |

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
| `stop` | Run |
| `console`, `--snapshot` | Taken over from the script used for the team's image so far; not run from this folder |
| `setup`: download of the image into an empty folder, checksum, unpack | Run: 424 MB downloaded, checksum ok, identical to the team's copy |
| `setup` with the image already there | Run: changes nothing |
| `install-host-deps.sh --check`, and a run with nothing missing | Run on Ubuntu 22.04: reports all groups complete, installs nothing, asks no password |
| `install-host-deps.sh`, install with apt | Run in clean Ubuntu 22.04 and 24.04 containers: installs the groups run and tools, `--check` then reports run complete |
| Clean Ubuntu container: `install-host-deps.sh --run-only`, then `autosd.sh start --snapshot`, `ssh`, `stop` | Run on Ubuntu 22.04 (QEMU 6.2.0) and 24.04 (QEMU 8.2.2): AutoSD boots with KVM, answers over SSH, shuts down cleanly |
| `install-host-deps.sh`, install with dnf | Run in a clean Fedora container (QEMU 10.2.2): packages installed, `autosd.sh check` passes. AutoSD not booted there |
| `install-build-deps.sh`, install with apt | Run in a clean, privileged Ubuntu 22.04 container: Podman 3.4.4 installed, test run ok. The first try failed on a system without `ca-certificates` (x509 error on the pull); the package is installed now |
| `install-host-deps.sh`, adding the user to the group of `/dev/kvm` | Run in a container as a user with sudo, with a stand-in file owned by `root:kvm` in place of `/dev/kvm` (a container cannot change the owner of the real one): user added; same session: asks to log in again; new session: `KVM: usable`. Not run against a real `/dev/kvm` |
| `deploy/setup-all.sh`, all six steps, against a freshly unpacked, untouched image (second AutoSD on other ports, own `RUN_DIR`) | Run: boots it, installs Ankaios, builds (cached), loads five images, six workloads `Running(Ok)`, SOVD and both web pages answer; about 80 s. After a restart of that AutoSD the six workloads came back by themselves. Run again: nothing loaded or restarted |
| A step of `setup-all.sh` fails | Happened: the Ankaios download inside AutoSD failed on a name lookup (the network's DNS took 10 to 20 s). The downloads retry now. With a forced failure in step 6: names the step, exits 1; the next run finishes |
| `deploy/setup-all.sh --check` | Run: before (exit 1, AutoSD not running) and after (exit 0) |
