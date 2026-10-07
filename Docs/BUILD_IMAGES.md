# Building and deploying the container images – Doctor Whodunit (FEVengers)

> Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: `claude-opus-5-5`, Anthropic).

How to build the images of every service that runs on AutoSD, on any developer machine, and start them on a running AutoSD system.

Status: all images build with Podman on Ubuntu 22.04. See [section 5](#7-status) for what has and has not been tested.

---

A new machine, from a fresh clone to the running system in one command (it runs sections 1, 2, 5 and 6 below and starts AutoSD in between; see [`AutosdSetup.md`](AutosdSetup.md)):

```bash
./deploy/setup-all.sh
```

---

## 1. Install the build tools (once)

```bash
./deploy/install-build-deps.sh
```

`./deploy/install-host-deps.sh` installs everything the scripts of this repository need on the machine, not only for building: it installs the packages to run AutoSD and to deploy (QEMU, OVMF, OpenSSH client, ...), the tools used by hand (`jq`, `mosquitto_pub`), and then calls `install-build-deps.sh`. The list is in [`AutosdSetup.md`](AutosdSetup.md), section 2.

All services are compiled inside containers, so the host needs no Rust toolchain. The only requirement is Podman or Docker.

| Situation | What the script does |
|---|---|
| Podman or Docker already works | Nothing; reports it and runs a test container |
| Neither is usable | Installs Podman with `apt`, `dnf` or `brew` (asks for the sudo password) |
| Other system | Stops and says what to install by hand |

`./deploy/install-build-deps.sh --check` only reports, without installing anything.

---

## 2. Build

```bash
./deploy/build-images.sh               # the services that get deployed
./deploy/build-images.sh guardian dfm  # only these (name or unique part of it)
./deploy/build-images.sh --all         # also the services marked optional
./deploy/build-images.sh --list        # show services and image names
./deploy/build-images.sh --no-save     # build without writing the archives
```

| Service | Image | Build context |
|---|---|---|
| VSS uProtocol Publisher | `localhost/vss-uprotocol-publisher:dev` | `vss-uprotocol-publisher/` |
| Battery Thermal Guardian | `localhost/battery-thermal-guardian:dev` | `battery-thermal-guardian/` |
| DFM | `localhost/dfm:dev` | `dfm-container/` |
| OpenSOVD gateway | `localhost/opensovd-gateway-dfm:dev` | `opensovd-gateway-dfm/` |
| Fault campaign runner (skeleton, optional) | `localhost/fault-campaign-runner:dev` | `fault-campaign-runner/` |
| Evidence collector | `localhost/evidence-collector:dev` | `evidence-collector/` |

The fault campaign runner is still an empty Rust program: it builds and prints `not implemented yet`; `src/main.rs` lists what is to be implemented. It is marked `optional` in the table: built only when named (`./deploy/build-images.sh campaign`) or with `--all`, because it is not deployed. The evidence collector is implemented (see [`evidence-collector.md`](evidence-collector.md)); it is built and deployed like the other services. The SOVD fault bridge and the dummy Guardian, which were used before the OpenSOVD gateway and the real Guardian's DFM reporting existed, are no longer in the repository.

The MQTT broker is not built; it is the stock `docker.io/library/eclipse-mosquitto:2`.

### Rust and fault-lib versions

Every service is compiled with the same compiler, and everything that talks to the DFM uses the same fault-lib commit:

| | Version | Where it is set |
|---|---|---|
| Rust compiler | 1.99.0 | `FROM docker.io/library/rust:1.99.0-bookworm` in every `Containerfile` |
| fault-lib (`fault_lib`, `dfm_lib`, `common`) | commit `12dac502` | `Cargo.toml` of the Guardian; `FAULTLIB_REV` in the `Containerfile` of the DFM and of the gateway |

fault-lib and the gateway's sources ask for a nightly compiler in their `rust-toolchain.toml`. They use no nightly-only feature, so the DFM and gateway `Containerfile` override that with `RUSTUP_TOOLCHAIN=1.99.0`. To move to a newer compiler, change the image tag and that variable everywhere at once; to move to a newer fault-lib, change the commit in all three places, because the DFM, the Guardian and the gateway must agree on the message format.

To trigger a fault without the board, publish a reading the Guardian rejects, with a counter that follows the last one:

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -t 'FEVengers_MQTT/telemetry' -m '{"temperature_degC": 500, "counter": 1}'
```

Each image is also saved as `build/images/<name>.tar` (`build/` is git-ignored). These archives are what `deploy-to-autosd.sh` loads on the AutoSD target.

A failed build does not stop the others. The script prints a summary at the end and exits non-zero if any service failed.

Options (environment variables):

| Variable | Default | |
|---|---|---|
| `ENGINE` | `podman` if usable, else `docker` | Container engine |
| `TAG` | `dev` | Image tag |
| `PLATFORM` | `linux/amd64` | Target platform; the AutoSD image we use is x86_64 |
| `OUT_DIR` | `build/images` | Where the archives go |

On a machine with another CPU (for example an ARM laptop) the images are still built for `linux/amd64`, emulated and therefore slow.

---

## 3. Add a service

Add one line to the `SERVICES` table at the top of `deploy/build-images.sh`:

```
<image name>|<folder with the Containerfile, relative to the repo root>
```

Append `|optional` to the line for a service that is not deployed yet.

Then add a workload for it to `deploy/ankaios-manifest.yaml`.

---

## 4. Ankaios manifest

`deploy/ankaios-manifest.yaml` describes the six workloads of the architecture:

| Workload | Image | Role |
|---|---|---|
| `mqtt-broker` | `eclipse-mosquitto:2` | Broker the board publishes to |
| `vss-publisher` | `vss-uprotocol-publisher` | MQTT → VSS → uProtocol |
| `guardian` | `battery-thermal-guardian` | Thermal monitoring; reports its faults to the DFM |
| `dfm` | `dfm` | Stores the faults |
| `opensovd-gateway` | `opensovd-gateway-dfm` | SOVD REST on port 7690 (`/sovd/v1/apps/battery/faults`) and the fault monitor page (`/ui/`) |
| `evidence-collector` | `evidence-collector` | Observes the Guardian's events and the raw samples over uProtocol, checks each fault against its own limits, writes one folder per evidence run; web UI and REST on port 7700 |

The Podman options come from `battery-thermal-guardian.md`, `FAULT_CHAIN.md`, `opensovd-gateway-dfm.md` and `evidence-collector.md`.

The evidence collector runs without a Zenoh configuration file, like the Guardian and the publisher: on the Eclipse AutoSD image IPv6 is enabled and Zenoh's multicast scouting works between the host-network containers. `evidence-collector.md` asks for `--zenoh-config` on AutoSD; that applies to an image with IPv6 disabled. Its evidence folder is `/var/lib/fevengers/evidence` on the target, not `/root/evidence`.

`PODMAN_MIGRATION.md` and `opensovd-gateway-dfm.md` describe the same containers started by hand (`scp`, `podman run`). The scripts here do that automatically; use one way or the other on a given AutoSD system, not both, or two containers end up on port 7690. Differences:

| Item | By hand (those documents) | Scripts here | Why |
|---|---|---|---|
| Catalog and web page on the target | `/root/catalogs`, `/root/webui` | `/var/lib/fevengers/catalogs`, `/var/lib/fevengers/webui` | One folder for everything the deployment puts on the target |
| Reaching ports 7690 and 7700 from the laptop | SSH tunnel | `autosd/autosd.sh` forwards both | No tunnel needed: `http://127.0.0.1:7690/ui/`, `http://127.0.0.1:7700/` |
| Who starts the containers | `podman run`, `--restart=always` | Ankaios workloads | Come back after a reboot, one manifest |
| Fault reporter | `dummy-guardian` (removed from the repository) | The real Guardian | Faults come from real data: the board's buttons, or a test MQTT message |

The publisher subscribes to the MQTT topic `FEVengers_MQTT/telemetry` on `localhost:1883`. That is the topic the board firmware publishes on (`MQTT_TELEMETRY_TOPIC` in the `cloud_config.h` of `FEVengersApp`, see [`az3166-firmware.md`](az3166-firmware.md)).

---

## 5. Prepare the AutoSD system (once)

The target is any running AutoSD system reachable over SSH: the QEMU image on the developer machine, or a device on the network. To run the QEMU image, see [`AutosdSetup.md`](AutosdSetup.md): `./autosd/autosd.sh` downloads the image into `autosd/` if it is not there, and starts it.

```bash
./deploy/setup-autosd.sh           # install and start Ankaios if it is not running
./deploy/setup-autosd.sh --check   # only report
```

The stock AutoSD image has Podman but no Ankaios. The script installs Ankaios v1.0.4 and starts it:

| Program | Role |
|---|---|
| `ank-server` | Holds the desired state: which workloads should run |
| `ank-agent` (`agent_A`) | Starts and stops the containers with Podman |
| `ank` | Command line tool: `ank --insecure get workloads`, `ank --insecure apply <manifest>` |

Server and agent are not workloads themselves. They run as systemd user units of root with lingering, because on AutoSD only `/var` survives a reboot (`/etc` is transient, `/usr` is read-only). The workloads are the containers in `deploy/ankaios-manifest.yaml`; the server reads the manifest and tells the agent to start them.

Connection settings, shared by `setup-autosd.sh` and `deploy-to-autosd.sh`:

| Variable | Default | |
|---|---|---|
| `AUTOSD_HOST` | `127.0.0.1` | The QEMU image on this machine. For a device on the network, its IP address |
| `AUTOSD_PORT` | `2222` | SSH port QEMU forwards. For a device, usually `22` |
| `AUTOSD_USER` | `root` | |
| `AUTOSD_PASSWORD` | `password` | Development password of the AutoSD image; set it empty to use an SSH key |

---

## 6. Deploy

```bash
./deploy/deploy-to-autosd.sh               # load the images that changed, restart their workloads, keep it across reboots
./deploy/deploy-to-autosd.sh --restart     # also restart the workloads whose image did not change
./deploy/deploy-to-autosd.sh --no-build    # never load an image, even if the archive is newer
./deploy/deploy-to-autosd.sh --no-persist  # start the workloads for this boot only
./deploy/deploy-to-autosd.sh status        # show the Ankaios workloads
./deploy/deploy-to-autosd.sh check         # compare the target with the manifest; changes nothing
./deploy/deploy-to-autosd.sh sync          # remove what the manifest does not use, add what is missing
./deploy/deploy-to-autosd.sh clear-faults  # empty the DFM's fault memory (start of a test run)
./deploy/deploy-to-autosd.sh reset         # show what a reset would remove
./deploy/deploy-to-autosd.sh reset --yes   # remove our workloads, images and files from the target
```

Maintenance commands, all run on the laptop:

| Command | What it does |
|---|---|
| `check` | For every workload of the manifest: is it `Running(Ok)`, and is its image `stored`, `outdated` (the archive in `build/images/` holds another build than the target runs) or `missing`. Also reports workloads that run on the target but are not in the manifest, our images that nothing uses, and a startup manifest that differs from the manifest. Exits non-zero on a difference |
| `sync` | Makes the target match the manifest with as little change as possible: deletes workloads that are not in the manifest, loads our images that are missing, starts workloads that are missing or not running, removes our images that nothing uses, refreshes the catalog and web page, and rewrites the startup manifest if it differs. Running workloads are not restarted and stored images are not loaded again, so it does not pick up a rebuilt image: use the plain deploy for that |
| `clear-faults` | `DELETE` on `/sovd/v1/apps/<app>/faults` through the OpenSOVD gateway, then prints the fault table. The app id is the `--dfm-fault-app` of the manifest |
| `reset` | Removes the workloads that run our images, all `localhost/*` images, the named volumes of the manifest, `/var/lib/fevengers` and `/root/faults.sh`, and reduces the startup manifest to the workloads of other images (the MQTT broker). Ankaios and `build/images/` on the laptop stay. Needs `--yes`; without it nothing is changed |

What it does, in order:

| Step | Detail |
|---|---|
| Load images | Only the `localhost/*` images whose archive in `build/images/` holds another build than the target has stored. The image id is read from the archive with `tar` and compared with the id on the target, so nothing is transferred when nothing changed |
| Prepare the target | Creates `/tmp/iceoryx2` and, under `/var/lib/fevengers`, `catalogs` (copy of `catalogs/*.json`), `webui` (copy of `opensovd-gateway-dfm/webui/`) and `evidence` (written by the evidence collector); copies the fault table script to `/root/faults.sh` |
| Remove what left the manifest | Workloads running on the target that the manifest no longer lists are deleted (as happened to the former SOVD fault bridge when the gateway replaced it) |
| Restart workloads | Only the workloads of the images that were loaded, plus any of ours that exist but do not run. If one of them is a workload others depend on (the DFM), all of ours restart and stale iceoryx2 files are cleared, because the others hold connections to the old instance. Then the manifest is applied, which starts what is missing. `--restart` restarts all of ours regardless |
| Wait | Up to 60 s until every workload is `Running(Ok)`; fails otherwise |

The deployment is persistent by default, so the workloads start by themselves at every boot:

| What is made persistent | How |
|---|---|
| The workloads | The manifest replaces the Ankaios startup manifest on the target (`/var/lib/ankaios/state.yaml`) |
| `/tmp/iceoryx2` | A drop-in for the `ank-agent` user unit recreates it at boot (`/tmp` is a tmpfs) |

With `--no-persist` the workloads exist only in the Ankaios server's memory: after a reboot only what the previous startup manifest lists comes back.

---

## 7. Status

| Item | State |
|---|---|
| `build-images.sh` with Podman 3.4.4 on Ubuntu 22.04 (x86_64) | All images built and saved; each started once with `--help` (skeletons: plain run). Default set with everything cached: 25 s. An optional service by name builds; a removed one is refused |
| First full build, empty cache | About 18 minutes for the four real services |
| `install-build-deps.sh`, engine already present | Run: detects Podman and changes nothing |
| `install-build-deps.sh`, install with apt | Run in a clean, privileged Ubuntu 22.04 container: Podman 3.4.4 installed, test run ok |
| `install-build-deps.sh`, install with dnf or brew | Not tested |
| `build-images.sh` with Docker, or on an ARM host | Not tested |
| `setup-autosd.sh --check`, `deploy-to-autosd.sh status` | Run against the QEMU image |
| `setup-autosd.sh`, install path | Run by `setup-all.sh` against a freshly downloaded, untouched image: Ankaios 1.0.4 installed, agent `agent_A` connected |
| `setup-all.sh` | Run against that image (second AutoSD on other ports): six workloads `Running(Ok)`, 77 s with the builds cached; run again: nothing loaded or restarted. Details in `AutosdSetup.md`, Status |
| `deploy-to-autosd.sh --no-persist` (the default at that time) | Run against the QEMU image: all five workloads `Running(Ok)`, DFM loads the `battery` catalog, `http://localhost:7690/sovd/v1/components/battery/faults` answers, no SELinux denials |
| `deploy-to-autosd.sh --no-build`, persistent (the default now), followed by a restart of the image | Run: all five workloads come back `Running(Ok)` on their own, `/tmp/iceoryx2` is recreated, the SOVD interface answers, no SELinux denials |
| Data from the real board through to the Guardian | Run: readings arrive on `FEVengers_MQTT/telemetry` once per second and the Guardian goes `CLEAR` → `MONITORING` |
| Guardian reporting its faults to the DFM (the `guardian` workload's IPC options and `--dfm-catalog`) | Run with the real board: board → MQTT → publisher → Guardian → DFM → SOVD. The fault list shows real occurrence counts (connection lost, spike, stuck), no SELinux denials |
| OpenSOVD gateway image (`opensovd-gateway-dfm`) | Built in about 7 minutes with Rust 1.99 (its Containerfile notes 1.97); started once with `--help` |
| `opensovd-gateway` workload on AutoSD (replacing the bridge) | Run: attaches to the DFM (`app_id=battery`), `/sovd/v1/apps/battery/faults` lists the four faults, the fault monitor page answers on `http://localhost:7690/ui/`, `/root/faults.sh` prints the table, no SELinux denials |
| Deploy removing a workload that left the manifest | Run: `sovd-bridge` was removed, also from the startup manifest |
| Fault memory across a DFM restart | Not kept: the occurrence counters are back at 0 after a redeploy. The `dfm-store` volume is mounted but the DFM writes nothing into it |
| `check` | Run: reports a healthy target as matching; with a changed manifest it reports the missing workload, the extra workload, the unused images and the different startup manifest |
| `clear-faults` | Run: counters 15 / 9 / 2 back to 0, table printed |
| `reset --yes` | Run: four workloads, their images, the `dfm-store` volume and `/var/lib/fevengers` removed; the broker kept running and the board stayed connected |
| `sync` | Run three ways: on a healthy target (removes only the unused bridge image), again (nothing to do), and after a reset (loads four images, starts four workloads, restores files and startup manifest) |
| Deploy with nothing changed | Run: loads nothing, restarts nothing, 3 s |
| Deploy after only the Guardian image changed | Run: loads and restarts only `guardian` (4 s); it reconnects to the running DFM at once |
| Deploy after only the publisher image changed | Run: loads and restarts only `vss-publisher`; the Guardian stays in `MONITORING` |
| Deploy after the DFM image changed | Run: loads the DFM and restarts all four of ours (16 s) |
| `--restart` with nothing changed | Run: loads nothing, restarts all four |
| `check` with a newer archive than the target runs | Run: reports `outdated` and exits non-zero |
| All services on Rust 1.99.0, DFM at fault-lib `12dac502` | Run: all four images build, with no nightly and no toolchain download in the build output. The DFM, built with a nightly before, compiles with 1.99.0 and its `Cargo.lock` unchanged |
| Unit tests with Rust 1.99.0 (`cargo test --locked` in a throwaway container) | Run: Guardian 35 of 35 passed, publisher 8 of 8 passed |
| DFM built with another compiler than before, against the unchanged Guardian and gateway | Run on AutoSD: the Guardian connects to the DFM, the gateway attaches, and an injected 500 °C reading shows up as `btg.temp.out_of_range` (`testFailed` true, count 1) and heals after five valid readings |
| Evidence collector: build with Rust 1.99.0, sixth workload on AutoSD | Run: builds (about 4 minutes), deploy loads and starts only it (5 s), six workloads `Running(Ok)`, no SELinux denials |
| Evidence collector without a Zenoh configuration file | Run: live tiles show the board's temperature, counter and the Guardian state, so it receives both streams over multicast scouting |
| Evidence run over port 7700 from the laptop (`/api/start`, injected 500 °C reading, `/api/stop`) | Run: four fault rows, the out-of-range fault "Confirmed: yes", SOVD snapshot before and after differ by one occurrence; `report.md`, `faults.json`, `summary.json`, `events.jsonl` written to `/var/lib/fevengers/evidence/<run-id>/` |
| Evidence collector: stuck, spike and connection-lost rows; the 3 s stuck limit against a real stuck fault | Not run |
| Port 7700 forward | Added to the running AutoSD through the QEMU monitor; `autosd.sh` sets it at the next start (not restarted since) |
| Restart of the image with the gateway in the startup manifest | Not run yet |
| `ankaios-manifest.yaml` | Applied by the deploy above |
