# Fault Chain – DFM, SOVD Fault Bridge and Reporter

> Created with AI assistance (Claude Opus 5.5, Anthropic).

How to run the complete fault path and read the Guardian faults as a table:

```
Reporter (dummy-guardian / Guardian)
   │  iceoryx2 publish (fault records)
   ▼
DFM  (Eclipse OpenSOVD Diagnostic Fault Manager, stores faults)
   ▲  iceoryx2 request/response "dfm/query"
   │
SOVD fault bridge  ──HTTP :7691──►  curl / tester / evidence collector
```

Related docs: `DFM_BRINGUP.md` (DFM image), `sovd-fault-bridge/README.md` (bridge), `DUMMY_GUARDIAN.md` (reporter).

---

## 1. Prerequisites

Images built once:

| Image | From |
|---|---|
| `localhost/dfm:dev` | `dfm-container/Containerfile` |
| `localhost/sovd-fault-bridge:dev` | `sovd-fault-bridge/Containerfile` |
| `localhost/dummy-guardian:dev` | `dummy-guardian/Containerfile` |

Tools: `podman`, `curl`, `jq` (`sudo apt install -y jq`).

Catalog folder (contains only `battery_guardian_catalog.json`):

```bash
C=/home/ashwin/Workspace/Hackathone2026/FEVengers/FEVengers_Hackathon_2026/catalogs
```

---

## 2. Start the chain

Order matters: **DFM → bridge → reporter**.

### 2.1 Clean state

Stale iceoryx2 files from killed containers cause timeouts.

```bash
podman rm -f bridge dfm
sudo rm -rf /tmp/iceoryx2/* ; sudo rm -f /dev/shm/iox2_*
mkdir -p /tmp/iceoryx2
```

### 2.2 DFM

```bash
podman run -d --name dfm --ipc=host --pid=host --restart=always \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  -v $C:/catalogs:ro -v dfm-store:/store \
  localhost/dfm:dev
podman logs -f dfm
```

Wait for:

```
Loaded catalog 'battery' from /catalogs/battery_guardian_catalog.json (4 faults)
DFM ready
DFM transport listening...
```

| Option | Why |
|---|---|
| `-v $C:/catalogs:ro` | Loads only our catalog |
| `-v dfm-store:/store` | Fault memory survives DFM restarts |
| `--restart=always` | Podman restarts the DFM if it dies |

### 2.3 SOVD fault bridge

Always (re)start the bridge after the DFM.

```bash
podman run -d --name bridge --net=host --ipc=host --pid=host \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  localhost/sovd-fault-bridge:dev
podman logs bridge
```

Expected: `SOVD fault bridge listening on 0.0.0.0:7691 (entities: ["battery", "hvac"])`.

Check: four faults, nothing active.

```bash
curl -s http://127.0.0.1:7691/sovd/v1/components/battery/faults | jq '.items[].code'
```

### 2.4 Reporter

Interactive dummy Guardian (see `DUMMY_GUARDIAN.md`):

```bash
podman run --rm -it --ipc=host --pid=host \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 -v $C:/catalogs:ro \
  localhost/dummy-guardian:dev interactive
> set stuck
```

The DFM log shows each report:

```
Received new fault ID: Text("btg.temp.stuck")
process_record{path="battery"}: ... Fault ID ... stored
```

---

## 3. Fault table

### 3.1 Script

```bash
cat > ~/faults.sh <<'EOF'
#!/bin/bash
# Created with AI assistance (Claude Opus 5.5, Anthropic).
# Show Guardian fault states from the SOVD fault bridge as a table.
curl -s http://127.0.0.1:7691/sovd/v1/components/battery/faults | \
  jq -r '["FAULT","STATE","EVER","COUNT"],
         (.items[] | [.code,
                      (if .status.test_failed then "FAULTY" else "ok" end),
                      (if .status.test_failed_since_last_clear then "yes" else "no" end),
                      (.occurrence_counter // 0)])
         | @tsv' | column -t
EOF
chmod +x ~/faults.sh
```

### 3.2 Use

```bash
~/faults.sh                 # once
watch -n 1 ~/faults.sh      # live view while the reporter runs
```

Example after `set stuck`:

```
FAULT                    STATE   EVER  COUNT
btg.src.connection_lost  ok      no    0
btg.temp.out_of_range    ok      no    0
btg.temp.stuck           FAULTY  yes   1
btg.temp.spike           ok      no    0
```

| Column | Source field | Meaning |
|---|---|---|
| `FAULT` | `code` | Fault ID from the catalog |
| `STATE` | `status.test_failed` | `FAULTY` = failing now; `ok` = not failing |
| `EVER` | `status.test_failed_since_last_clear` | Failed at least once since the last clear (evidence) |
| `COUNT` | `occurrence_counter` | Number of occurrences |

After `clear stuck`, `STATE` returns to `ok`; `EVER` stays `yes` and `COUNT` stays `1`.

### 3.3 Other queries

```bash
B=http://127.0.0.1:7691/sovd/v1

# Active faults only
curl -s $B/components/battery/faults | jq '[.items[] | select(.status.test_failed) | .code]'

# One fault with environment data
curl -s $B/components/battery/faults/btg.temp.stuck | jq

# Clear fault memory (start of each campaign run)
curl -s -i -X DELETE $B/components/battery/faults
```

---

## 4. Stop

```bash
podman rm -f bridge dfm
podman volume rm dfm-store     # only to wipe stored faults
```

---

## 5. AutoSD

Same commands inside the VM, with two differences:

| Difference | Change |
|---|---|
| SELinux enforcing | Add `--security-opt label=disable` to every container |
| Catalog path | Copy the folder: `scp -P 2222 -r $C root@localhost:/root/catalogs`, then use `-v /root/catalogs:/catalogs:ro` |

Transfer images from the laptop:

```bash
for img in dfm sovd-fault-bridge dummy-guardian; do
  podman save -o $img.tar localhost/$img:dev
  scp -P 2222 $img.tar root@localhost:/root/
  ssh -p 2222 root@localhost podman load -i /root/$img.tar
done
```

Reach the bridge from the laptop with an SSH tunnel, then run `~/faults.sh` on the laptop:

```bash
ssh -p 2222 -L 7691:localhost:7691 root@localhost
```

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `curl` prints nothing | Bridge not running | `podman ps`; start the bridge |
| `503 storage error: query timeout` | DFM not running or not reachable | `podman ps -a`; clean restart (2.1–2.3) |
| Reporter: `cannot connect to DFM ... Timeout` | Same | Same |
| `dfm Exited (137)` | DFM killed | `--restart=always`; clean restart |
| `Connection reset by peer` | Rootless port forward over IPv6 | Bridge with `--net=host`; use `127.0.0.1` |
| Only `hvac` / `ivi` faults listed | DFM started without our catalog mount | Restart the DFM with `-v $C:/catalogs:ro` |
| DFM log: `No JSON catalog files found` | Wrong catalog path | `ls -l $C`; fix `C=` |
| iceoryx2 warning `No config file was loaded` | Default iceoryx2 config | Harmless |
| DFM log: `get_value could not find key` | First access to empty store | Harmless |
