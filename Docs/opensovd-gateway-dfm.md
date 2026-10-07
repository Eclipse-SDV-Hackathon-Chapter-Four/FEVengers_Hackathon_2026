# OpenSOVD Gateway with DFM Faults and Web UI

> Created with AI assistance (Claude Opus 5.5, Anthropic).

Runs the complete Guardian fault chain with the **official OpenSOVD gateway** serving faults from the Eclipse OpenSOVD **DFM** on the standard SOVD path, plus a browser fault monitor:

```
GET/DELETE http://<host>:7690/sovd/v1/apps/battery/faults[/{fault-code}]
Web UI:    http://<host>:7690/ui/
```

Status: verified end to end on Ubuntu (dummy Guardian → DFM → gateway → curl, table script and web UI).

```
dummy-guardian / Guardian (fault_lib)
   │  iceoryx2 publish
   ▼
DFM (dfm_bin) ── loads battery_guardian_catalog.json, stores faults
   ▲  iceoryx2 request/response "dfm/query"
   │
OpenSOVD gateway (--dfm-fault-app battery)  ──HTTP :7690──►  /sovd/v1/apps/battery/faults
   └── --serve-dir /ui:/webui  ─────────────────────────────►  /ui/  (web UI)
```

Replaces the standalone SOVD fault bridge (port 7691).

---

## 1. Folder layout

```
opensovd-gateway-dfm/
├── Containerfile      # builds the gateway (fetches sources itself)
├── README.md
├── fault_host.sh      # table script, Ubuntu (jq)
├── faults.sh          # table script, AutoSD (python3)
└── webui/
    └── index.html     # fault monitor page
```

Other parts of the chain:

| Item | Where |
|---|---|
| DFM image | `localhost/dfm:dev` (`dfm-container/`, see `DFM_BRINGUP.md`) |
| Dummy Guardian image | `localhost/dummy-guardian:dev` (`dummy-guardian/`, see `DUMMY_GUARDIAN.md`) |
| Fault catalog | `catalogs/battery_guardian_catalog.json` |

---

## 2. Environment variables

Set these once per terminal. Every command in this README uses them.

### Ubuntu

```bash
export REPO=/home/ashwin/Workspace/Hackathone2026/FEVengers/FEVengers_Hackathon_2026
export C=$REPO/catalogs                       # fault catalog folder
export W=$REPO/opensovd-gateway-dfm/webui     # web UI folder
export SEL=""                                 # no SELinux option on Ubuntu
export IPC="--ipc=host --pid=host -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2"
export SOVD=http://127.0.0.1:7690/sovd/v1
```

### AutoSD (inside the VM, `ssh -p 2222 root@localhost`)

```bash
export C=/root/catalogs
export W=/root/webui
export SEL="--security-opt label=disable"     # SELinux would block the shared mounts
export IPC="--ipc=host --pid=host -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2"
export SOVD=http://127.0.0.1:7690/sovd/v1
```

| Variable | Meaning |
|---|---|
| `C` | Folder containing only `battery_guardian_catalog.json` |
| `W` | Folder containing `index.html` |
| `SEL` | Extra Podman option for SELinux (AutoSD only) |
| `IPC` | Options every iceoryx2 container needs |
| `SOVD` | Base URL of the SOVD API |

Optional: put the block into `~/.bashrc` (Ubuntu) or `/root/.bashrc` (AutoSD) so new terminals have it.

Variables used inside the containers:

| Variable | Container | Default | Meaning |
|---|---|---|---|
| `SOVD_URL` | gateway | `http://0.0.0.0:7690/sovd` | Listen address and base path |
| `SOVD_DFM_FAULT_APP` | gateway | none | Same as `--dfm-fault-app` |
| `SOVD_DFM_FAULT_COMPONENT` | gateway | none | Same as `--dfm-fault-component` |
| `RUST_LOG` | all | `info` | Log level, e.g. `-e RUST_LOG=debug` |
| `URL` | table scripts | `$SOVD/apps/battery/faults` | Which fault list to show |

---

## 3. Build the gateway image

The `Containerfile` clones the sources at pinned commits; nothing is copied by hand.

| Source | Commit | Used for |
|---|---|---|
| `Eclipse-SDV-Hackathon-Chapter-Four/Doctor-Whodunit` (`example-first-steps`) | `5756330` | `demo/opensovd-core`: Rama's gateway, fault routes, DFM adapter |
| `eclipse-opensovd/opensovd-core` | `1bf4c47` | `opensovd-cli/lib`, `opensovd-cli/build` (missing in the example branch) |
| `eclipse-opensovd/fault-lib` | `12dac502` | `dfm_lib` for the adapter, same as our DFM image |

Two fixes applied during the build:

1. Restore `opensovd-cli/lib` and `opensovd-cli/build`: the example branch's `.gitignore` ignores every `lib/` and `build/` folder.
2. Repin the adapter's `dfm_lib` from the PR fork (`bburda42dot/fault-lib @ 2b638d84`) to upstream `12dac502`, so gateway and DFM use the same iceoryx2 query protocol.

```bash
cd $REPO/opensovd-gateway-dfm
podman build -t localhost/opensovd-gateway-dfm:dev .
```

First build: about 10 minutes (stable Rust toolchain).

---

## 4. Run the chain

Order: **clean → DFM → gateway → reporter**. Use separate terminals; each needs the variables from section 2.

### 4.1 Clean state

Stale iceoryx2 files from killed containers cause timeouts.

```bash
podman rm -f sovd bridge dfm 2>/dev/null
sudo rm -rf /tmp/iceoryx2/* ; sudo rm -f /dev/shm/iox2_*     # AutoSD: without sudo
mkdir -p /tmp/iceoryx2
```

### 4.2 DFM (terminal 1)

```bash
podman run -d --name dfm --restart=always $IPC $SEL \
  -v $C:/catalogs:ro -v dfm-store:/store \
  localhost/dfm:dev
sleep 2; podman logs dfm
```

Expect `Loaded catalog 'battery' ... (4 faults)` and `DFM transport listening...`.

### 4.3 Gateway with web UI (terminal 1)

```bash
ls -l $W/index.html            # must exist

podman run -d --name sovd --net=host $IPC $SEL \
  -v $W:/webui:ro \
  localhost/opensovd-gateway-dfm:dev \
  --dfm-fault-app battery --serve-dir /ui:/webui
podman logs sovd | grep -i "attached\|static\|listening"
```

Expect:

```
Attached DFM fault provider app_id=battery
Serving static files path=/ui dir=/webui
Listening addr=0.0.0.0:7690 ...
```

| Option | Why |
|---|---|
| `--net=host` | Port 7690 reachable; avoids the rootless IPv6 port-forward reset |
| `$IPC` | iceoryx2 query to the DFM |
| `-v $W:/webui:ro` | Web UI files inside the container |
| `--dfm-fault-app battery` | Registers app `battery` on host component `hpc`; must equal the catalog `id` |
| `--serve-dir /ui:/webui` | Serves `/webui` at URL path `/ui` |

Arguments after the image name **replace** the image's default command. Always pass `--dfm-fault-app battery` together with `--serve-dir`.

The gateway does not read the catalog. The DFM owns the fault definitions; the gateway asks the DFM for path `battery`.

The iceoryx2 warning `[W] Config::global_config() ... No config file was loaded` is harmless.

### 4.4 Check

```bash
podman ps --format "{{.Names}}  {{.Status}}"            # dfm, sovd: Up
curl -s $SOVD/apps | jq -r '.items[].id'                 # battery
curl -s $SOVD/apps/battery/faults | jq '.items[].code'   # four codes
```

### 4.5 Dummy Guardian (terminal 2)

```bash
podman run --rm -it $IPC $SEL -v $C:/catalogs:ro \
  localhost/dummy-guardian:dev interactive
> set stuck
```

Commands: `set <fault>`, `clear <fault>`, `status`, `quit`; faults: `connection_lost`, `out_of_range`, `stuck`, `spike`.

---

## 5. Watch the faults

### 5.1 Web UI

Open in the laptop browser:

```
http://localhost:7690/ui/
```

If it returns 404, use `http://localhost:7690/sovd/ui/`.

AutoSD has no browser. Tunnel the port from the laptop (stop the laptop's own gateway first so 7690 is free), then open the same URL on the laptop:

```bash
ssh -p 2222 -L 7690:localhost:7690 root@localhost
```

The page refreshes every second and loads nothing from the internet.

| Element | Meaning |
|---|---|
| **Active now** | Faults failing now (`testFailed`) |
| **Occurred, cleared** | Failed since the last clear, not failing now (`testFailedSinceLastClear` only) |
| **Never failed** | No failure since the last clear |
| **Faults in catalog** | All faults the DFM knows for the entity |
| Chip **ACTIVE** / **OCCURRED** / **OK** | Same three states per fault; active faults sort first |
| **Count** | `occurrence_counter` |
| **First / Last** | First and last occurrence (UTC) |
| **Mask** | DTC status byte (section 5.3) |
| **Sev.** | Severity number (section 5.3) |
| Entity selector | `apps` / `components` and id; or open `/ui/?app=battery` |
| Filter | All faults / Active only / Active or occurred |
| **Pause** | Stop auto-refresh |
| **Clear** (row) | `DELETE .../faults/{code}` |
| **Clear all** | `DELETE .../faults`; click twice within 3 s to confirm |

### 5.2 Table in the terminal

```bash
cd $REPO/opensovd-gateway-dfm
watch -n 1 ./fault_host.sh        # Ubuntu
watch -n 1 /root/faults.sh        # AutoSD
```

```
FAULT                    STATE   EVER  COUNT
btg.src.connection_lost  ok      no    0
btg.temp.out_of_range    ok      no    0
btg.temp.stuck           FAULTY  yes   1
btg.temp.spike           ok      no    0
```

Other source: `URL=<fault-list-url> ./fault_host.sh`.

### 5.3 Fields explained

**Mask** – ISO 14229 DTC status byte (hex):

| Bit | Value | Flag | Meaning |
|---|---|---|---|
| 0 | `0x01` | testFailed | Failing now |
| 1 | `0x02` | testFailedThisOperationCycle | Failed in this operation cycle |
| 2 | `0x04` | pendingDTC | Failed, not yet confirmed |
| 3 | `0x08` | confirmedDTC | Confirmed and stored |
| 4 | `0x10` | testNotCompletedSinceLastClear | Not tested since last clear |
| 5 | `0x20` | testFailedSinceLastClear | Failed since last clear |
| 6 | `0x40` | testNotCompletedThisOperationCycle | Not tested in this cycle |
| 7 | `0x80` | warningIndicatorRequested | Warning lamp requested (our faults are `SafetyCritical`) |

| Mask | Meaning | Chip |
|---|---|---|
| `0xAB` | Failing now, confirmed, warning on | ACTIVE |
| `0xA2` | Failed earlier, not now | OCCURRED |
| `0x00` | No failure since last clear | OK |

**Sev.** – severity number. The SOVD spec recommends 1 = FATAL, 2 = ERROR, 3 = WARN, 4 = INFO. The DFM currently reports catalog `Error` as 4 and `Warn` as 3 (shifted by one); the UI shows the raw number only.

**Clear** – SOVD `DELETE`, forwarded to the DFM. Resets the stored state (status bits, count, timestamps); the catalog definition stays. Same as clearing DTCs in a workshop (UDS `0x14`). Use **Clear all** at the start of each test run.

The dummy Guardian reports only state changes. After clearing a fault in the UI that the dummy still has set, `set` alone does nothing; run `clear <fault>` then `set <fault>` in the dummy.

---

## 6. Verified test sequence

Start with **Clear all**, then in the dummy:

| Command | UI after the command |
|---|---|
| `set stuck` | stuck ACTIVE; Active now = 1 |
| `set spike` | spike ACTIVE; Active now = 2 |
| `clear stuck` | stuck OCCURRED, count 1 |
| `set connection_lost` | connection_lost ACTIVE |
| `set out_of_range` | out_of_range ACTIVE; Active now = 3 |
| `clear spike`, `clear connection_lost`, `clear out_of_range` | all OCCURRED; Active now = 0 |

---

## 7. REST reference

```bash
curl -s $SOVD/apps | jq                                     # apps (battery)
curl -s $SOVD/apps/battery | jq                             # app detail with "faults" link
curl -s $SOVD/apps/battery/faults | jq                      # all faults
curl -s $SOVD/apps/battery/faults/btg.temp.stuck | jq       # one fault + environment data
curl -s -i -X DELETE $SOVD/apps/battery/faults/btg.temp.stuck   # clear one   (204)
curl -s -i -X DELETE $SOVD/apps/battery/faults                  # clear all   (204)
curl -s http://127.0.0.1:7690/sovd/version-info | jq        # server info
```

Matches ISO 17978-3 (`faults/faults.yaml`): `GET`/`DELETE` on `/{entity-collection}/{entity-id}/faults[/{fault-code}]`, list wrapped in `items`, `204` on delete. Status keys are camelCase, as in the spec example. Query filters (`status`, `severity`, `scope`) are not implemented.

---

## 8. AutoSD migration

Transfer images, catalog, web UI and script from the laptop (details: `PODMAN_MIGRATION.md`):

```bash
for img in dfm opensovd-gateway-dfm dummy-guardian; do
  podman save -o /tmp/$img.tar localhost/$img:dev
  scp -P 2222 /tmp/$img.tar root@localhost:/root/
  ssh -p 2222 root@localhost "podman load -i /root/$img.tar && rm /root/$img.tar"
done
ssh -p 2222 root@localhost "mkdir -p /root/catalogs /root/webui /tmp/iceoryx2"
scp -P 2222 $C/battery_guardian_catalog.json root@localhost:/root/catalogs/
scp -P 2222 $W/index.html root@localhost:/root/webui/
scp -P 2222 $REPO/opensovd-gateway-dfm/faults.sh root@localhost:/root/faults.sh
```

Then run section 4 inside the VM with the AutoSD variables (section 2).

---

## 9. Stop

```bash
podman rm -f sovd dfm
podman volume rm dfm-store      # only to wipe stored faults
```

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Entity not found: battery` | Gateway started without `--dfm-fault-app battery`, or another gateway on 7690 | `podman ps`; remove old gateways; restart as in 4.3 |
| `statfs .../webui/webui: no such file` | `$W` relative to the wrong directory | Use the absolute `W` from section 2 |
| UI 404 on `/ui/` | Static files under the base path | Try `/sovd/ui/`; check `podman logs sovd \| grep static` |
| UI footer: `Cannot read faults` | Gateway or DFM down | `podman ps`; restart 4.1–4.3 |
| `SOVD server not reachable` (scripts) | Gateway not running | Start it (4.3) |
| `503 ... unavailable` / timeout | DFM down or stale iceoryx2 files | 4.1 → 4.3 |
| Dummy: `cannot connect to DFM ... Timeout` | Same | Same |
| `set` after UI Clear has no effect | Dummy reports changes only | `clear <fault>` then `set <fault>` in the dummy |
| `Permission denied` on mounts (AutoSD) | SELinux | `SEL="--security-opt label=disable"` |
| `bind: address already in use` for the tunnel | Laptop gateway holds 7690 | `podman rm -f sovd` on the laptop |
| `[W] Config::global_config()` | iceoryx2 default config | Harmless |
