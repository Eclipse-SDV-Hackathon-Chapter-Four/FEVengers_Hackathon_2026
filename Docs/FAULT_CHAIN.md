# Fault Chain – Reporter, DFM and SOVD Fault Bridge

> Created with AI assistance (Claude Opus 5.5, Anthropic).

How to run the complete fault path and read the Battery Thermal Guardian faults as a table, on the Ubuntu laptop and in AutoSD.

Status: verified end to end on Ubuntu and in AutoSD (x86_64 QEMU) with the dummy Guardian in interactive mode.

```
Reporter (dummy-guardian / Guardian, fault_lib)
   │  iceoryx2 publish (fault records)
   ▼
DFM  (Eclipse OpenSOVD Diagnostic Fault Manager: debounce, lifecycle, storage)
   ▲  iceoryx2 request/response "dfm/query"
   │
SOVD fault bridge  ──HTTP :7691──►  faults.sh / fault_host.sh / tester
```

All three run as Podman containers on the **same machine**: iceoryx2 is shared-memory IPC and does not cross machine or VM boundaries.

Related docs:

| Doc | Content |
|---|---|
| `DFM_BRINGUP.md` | Building the DFM image |
| `sovd-fault-bridge/README.md` | Bridge design and API |
| `DUMMY_GUARDIAN.md` | Dummy Guardian build, modes, reusable `faults.rs` |
| `PODMAN_MIGRATION.md` | Moving images, catalog and scripts from Ubuntu to AutoSD |

---

## 1. Components

| Container | Image | Role |
|---|---|---|
| `dfm` | `localhost/dfm:dev` | Stores faults reported against the `battery` catalog |
| `bridge` | `localhost/sovd-fault-bridge:dev` | Serves DFM faults as SOVD REST on port 7691 |
| (reporter) | `localhost/dummy-guardian:dev` | Sets and clears the four Guardian faults |

Faults (`battery_guardian_catalog.json`, catalog id `battery`, no debounce):

| CLI name | Fault ID |
|---|---|
| `connection_lost` | `btg.src.connection_lost` |
| `out_of_range` | `btg.temp.out_of_range` |
| `stuck` | `btg.temp.stuck` |
| `spike` | `btg.temp.spike` |

---

## 2. Environment differences

| | Ubuntu laptop | AutoSD VM |
|---|---|---|
| Catalog folder `$C` | `/home/ashwin/Workspace/Hackathone2026/FEVengers/FEVengers_Hackathon_2026/catalogs` | `/root/catalogs` |
| Extra Podman option | none | `--security-opt label=disable` (SELinux) |
| `sudo` for cleanup | yes | no (root) |
| Table script | `fault_host.sh` (curl + jq) | `faults.sh` (curl + python3) |
| Access | local terminal | `ssh -p 2222 root@localhost`, one window per task |

Set these once per shell:

```bash
# Ubuntu
C=/home/ashwin/Workspace/Hackathone2026/FEVengers/FEVengers_Hackathon_2026/catalogs
SEL=""

# AutoSD
C=/root/catalogs
SEL="--security-opt label=disable"
```

All commands below use `$C` and `$SEL`, so they work unchanged in both environments.

---

## 3. Start the chain

Order: **clean → DFM → bridge → reporter**.

### 3.1 Clean state

Stale iceoryx2 files from killed containers cause timeouts.

```bash
podman rm -f bridge dfm 2>/dev/null
rm -rf /tmp/iceoryx2/* ; rm -f /dev/shm/iox2_*      # Ubuntu: prefix with sudo
mkdir -p /tmp/iceoryx2
```

### 3.2 DFM

```bash
podman run -d --name dfm --ipc=host --pid=host --restart=always $SEL \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  -v $C:/catalogs:ro -v dfm-store:/store \
  localhost/dfm:dev
sleep 2; podman logs dfm
```

Wait for:

```
Loaded catalog 'battery' from /catalogs/battery_guardian_catalog.json (4 faults)
DFM ready
DFM transport listening...
```

### 3.3 Bridge

Always (re)start the bridge after the DFM.

```bash
podman run -d --name bridge --net=host --ipc=host --pid=host $SEL \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  localhost/sovd-fault-bridge:dev
sleep 1; podman logs bridge
```

Expected: `SOVD fault bridge listening on 0.0.0.0:7691 (entities: ["battery", "hvac"])`.

### 3.4 Check

```bash
podman ps --format "{{.Names}} {{.Status}}"     # dfm and bridge: Up
./fault_host.sh                                  # Ubuntu
/root/faults.sh                                  # AutoSD
```

All four faults listed, all `ok`.

### 3.5 Reporter

Separate terminal (AutoSD: separate SSH window):

```bash
podman run --rm -it --ipc=host --pid=host $SEL \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 -v $C:/catalogs:ro \
  localhost/dummy-guardian:dev interactive
```

The DFM log shows each report:

```
Received new fault ID: Text("btg.temp.stuck")
process_record{path="battery"}: ... Fault ID ... stored
```

### Podman options

| Option | Container | Why |
|---|---|---|
| `--ipc=host`, `--pid=host` | all | iceoryx2 shared memory and dead-peer detection across containers |
| `-v /dev/shm:/dev/shm`, `-v /tmp/iceoryx2:/tmp/iceoryx2` | all | Shared memory segments and iceoryx2 discovery files |
| `-v $C:/catalogs:ro` | DFM, reporter | Same catalog on both sides |
| `-v dfm-store:/store` | DFM | Fault memory survives DFM restarts |
| `--restart=always` | DFM | Podman restarts the DFM if it dies |
| `--net=host` | bridge | Port 7691 reachable; avoids rootless IPv6 port-forward reset |
| `$SEL` | all (AutoSD) | SELinux would block the shared mounts |
| `-it` | reporter | Interactive input |

---

## 4. Fault table

### 4.1 Scripts

| Script | Where | Needs |
|---|---|---|
| `scripts/fault_host.sh` | Ubuntu laptop | `curl`, `jq`, `column` |
| `scripts/faults.sh` | AutoSD | `curl`, `python3` |

Both print the same table. Install:

```bash
# Ubuntu
chmod +x scripts/fault_host.sh

# AutoSD (copy from laptop, see PODMAN_MIGRATION.md)
chmod +x /root/faults.sh
```

### 4.2 Use

Separate terminal (AutoSD: separate SSH window):

```bash
watch -n 1 ./scripts/fault_host.sh     # Ubuntu
watch -n 1 /root/faults.sh             # AutoSD
```

| Column | Source field | Meaning |
|---|---|---|
| `FAULT` | `code` | Fault ID from the catalog |
| `STATE` | `status.test_failed` | `FAULTY` = failing now; `ok` = not failing |
| `EVER` | `status.test_failed_since_last_clear` | Failed at least once since the last clear (evidence) |
| `COUNT` | `occurrence_counter` | Number of occurrences |

### 4.3 Verified test sequence

In the reporter:

```
> set stuck
> set spike
> status
> clear stuck
> set connection_lost
> clear spike
> clear connection_lost
> quit
```

Table after each step (starting from a cleared fault memory):

| After | `stuck` | `spike` | `connection_lost` |
|---|---|---|---|
| `set stuck` | FAULTY yes 1 | ok no 0 | ok no 0 |
| `set spike` | FAULTY yes 1 | FAULTY yes 1 | ok no 0 |
| `clear stuck` | ok yes 1 | FAULTY yes 1 | ok no 0 |
| `set connection_lost` | ok yes 1 | FAULTY yes 1 | FAULTY yes 1 |
| `clear spike`, `clear connection_lost` | ok yes 1 | ok yes 1 | ok yes 1 |

After `clear`, `STATE` returns to `ok` while `EVER` and `COUNT` keep the evidence.

Example:

```
FAULT                    STATE   EVER  COUNT
btg.src.connection_lost  ok      no    0
btg.temp.out_of_range    ok      no    0
btg.temp.stuck           FAULTY  yes   1
btg.temp.spike           ok      no    0
```

### 4.4 Other queries

```bash
B=http://127.0.0.1:7691/sovd/v1

curl -s $B/components/battery/faults                       # raw JSON
curl -s $B/components/battery/faults/btg.temp.stuck        # one fault + environment data
curl -s -i -X DELETE $B/components/battery/faults          # clear fault memory (start of each run)
```

`dfm-store` keeps counts across DFM restarts. Clear the fault memory before a test run to start from zero.

---

## 5. Stop

```bash
podman rm -f bridge dfm
podman volume rm dfm-store     # only to wipe stored faults
```

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Table: `bridge not reachable` | Bridge not running | `podman ps -a`; start the bridge (3.3) |
| `503 storage error: query timeout` | DFM not running or not reachable | Clean restart (3.1–3.3) |
| Reporter: `cannot connect to DFM ... Timeout` | Same | Same |
| `dfm Exited (137)` | DFM killed | Clean restart; `--restart=always` |
| Only `hvac` / `ivi` faults listed | DFM started without the catalog mount | Restart the DFM with `-v $C:/catalogs:ro` |
| DFM log: `No JSON catalog files found` | Wrong `$C` | `ls -l $C` |
| `Permission denied` on mounts (AutoSD) | SELinux | `$SEL` set to `--security-opt label=disable` |
| `Connection reset by peer` (Ubuntu) | Rootless port forward over IPv6 | Bridge with `--net=host`; use `127.0.0.1` |
| `faults.sh`: `SyntaxError ... line continuation` | Old script version with escaped f-strings | Use the current `scripts/faults.sh` |
| iceoryx2 warning `No config file was loaded` | Default iceoryx2 config | Harmless |
| DFM log: `get_value could not find key` | First access to empty store | Harmless |
