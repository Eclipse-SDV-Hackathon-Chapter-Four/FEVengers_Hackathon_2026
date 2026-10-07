# AutoSD image folder

> Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: `claude-opus-5-5`, Anthropic).

Put your copy of the Eclipse AutoSD QEMU image into this folder and start it with `autosd.sh`. The image is not in git (3.6 GB); everyone brings their own. The script only starts the image, it does not download or copy one.

Image: `eclipse-autosd-bootc-qemu-x86_64.qcow2`, the `dev` rolling release of [eclipse-autosd](https://github.com/eclipse-autosd/eclipse-autosd) (published as `.qcow2.xz`; unpack it first). All scripts in `deploy/` are written for this image.

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

Needs `qemu-system-x86_64` and OVMF (Ubuntu: `sudo apt install qemu-system-x86 ovmf`). With KVM the image boots in about 20 seconds.

## Ports

| Host | AutoSD | Used for |
|---|---|---|
| 2222 (this machine only) | 22 | SSH; `deploy/` scripts connect here |
| 1883 | 1883 | MQTT broker: the AZ3166 board publishes here |
| 7690 | 7690 | SOVD REST: `http://localhost:7690/sovd/v1/components/battery/faults` |

## MQTT data from the board

```
AZ3166 --Wi-Fi--> <this machine>:1883 --QEMU forward--> AutoSD:1883 (mqtt-broker) --> vss-publisher
```

| Requirement | Why |
|---|---|
| Nothing else on host port 1883 | With a local Mosquitto on 1883 the board talks to that one and nothing reaches AutoSD. Starting stops it; to keep it from coming back at boot: `sudo systemctl disable mosquitto` |
| Board and this machine on the same network | The board sends to a fixed address, compiled into the firmware |
| `MQTT_LOCAL_BROKER_IP` in the firmware = this machine's address | The script prints the address to use when it starts, and with `status`. It comes from DHCP: after changing network, or a new lease, the firmware must be rebuilt |
| Topic `az3166/telemetry` | The one `vss-publisher` subscribes to |

The firmware connects once and does not reconnect: after restarting AutoSD or the broker, reset the board.

## Next steps

```bash
./deploy/setup-autosd.sh       # once: install Ankaios in the image
./deploy/build-images.sh       # build the service images
./deploy/deploy-to-autosd.sh   # load them and start the workloads
```

Details: [Docs/BUILD_IMAGES.md](../Docs/BUILD_IMAGES.md).

## Status

| Item | State |
|---|---|
| `check`, `status`, missing image | Run |
| Freeing a port: plain program, and a QEMU (shutdown request, then terminated after 30 s) | Run on throwaway processes |
| Freeing a port held by a systemd service or another user's program (needs sudo) | Not tested |
| Boot from this folder, `ssh`, `status`, MQTT round trip through host port 1883 | Run |
| `stop`, `console`, `--snapshot` | Taken over from the script used for the team's image so far; not run from this folder |
