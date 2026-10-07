# Evidence Collector

> Created with AI assistance (Claude Opus 5.5, Anthropic).

Independent observer for the Battery Thermal Guardian. It listens to the Guardian and to the raw temperature stream over uProtocol, and for every fault **raised** or **cleared** it stores the value that triggered it, the value before it, and checks it against the expected limits. A web page with a **Start / Stop evidence** button controls the recording; every run is written to its own evidence folder.

Code: [`evidence-collector/`](../evidence-collector/)

---

## 1. Where it sits

```
AZ3166 ─MQTT─► broker ─► vss (8001) ──uProtocol/Zenoh──► guardian (8002) ─iceoryx2─► dfm ◄─ sovd :7690
                              │                                │                              │
                              │ //*/8001/1/8001 (raw samples)  │ //*/8002/1/FFFF (all topics)  │ HTTP GET (snapshot)
                              ▼                                ▼                              ▼
                        ┌─────────────────────────────────────────────────────────────────────────┐
                        │ evidence-collector  (own container, Zenoh + HTTP only)                  │
                        │  web UI :7700  ·  /evidence/<run-id>/                                    │
                        └─────────────────────────────────────────────────────────────────────────┘
```

The Guardian is **not changed** and does not know about the collector. The collector is a pure subscriber: it builds the "previous / current" values from its **own** copy of the raw stream instead of trusting the Guardian, and holds the limits in its **own** config. That makes it an independent judge, not a second copy of the Guardian.

No iceoryx2, no DFM access, no `--ipc=host` needed.

---

## 2. What it receives (uProtocol)

| UUri | Publisher | Used for |
|---|---|---|
| `//*/8001/1/8001` | VSS publisher (`vss`) / `vss-sim` | Raw samples (`value`, `rolling_counter`), buffer of the last 500 |
| `//*/8002/1/FFFF` | Guardian | All four Guardian topics (FFFF = wildcard) |

Guardian topics, told apart by the resource ID of the message source:

| Resource | Topic | Used for |
|---|---|---|
| `0x8001` | heartbeat | Live tiles: state, active faults, Guardian alive / silent |
| `0x8002` | state | Live state tile (`to`) |
| `0x8003` | fault | **Evidence rows** (`fault`, `status`, `catalog_id`, `class`, `state`, `detail`, `at_ms`, `seq`, `trigger`) |
| `0x8004` | mitigation | Recorded in `events.jsonl` |

Payload formats: `battery-thermal-guardian/src/contract.rs` (`VssSample`, `Heartbeat`, `StateEvent`, `FaultEvent`, `MitigationEvent`). The collector reads them as generic JSON; a renamed field shows as `–` instead of breaking it.

---

## 3. How a row is built

For each fault event received while a run is recording (built 300 ms later, so the trigger sample has surely arrived; Zenoh does not keep the order between topics):

1. **Current** = the sample named in the event's `trigger.message_id` (fallback: `trigger.rolling_counter`), looked up in the collector's raw buffer.
2. **Previous** = the sample just before it in that buffer.
3. No `trigger` (time-driven fault, e.g. connection lost after a timeout) → last two samples before the event, row marked **timeout**.
4. **Δ °C** = current − previous, **rate °C/s** = Δ / time between them.
5. **Limit check** against `limits.toml` (section 4).

| Fault | Limit shown | Collector measures | ✔ confirmed when |
|---|---|---|---|
| `TempSignalSpike` | `\|rate\| ≤ max_rate_c_per_s` | Rate previous → current | \|rate\| > limit |
| `TempOutOfRange` | `min_c … max_c` | Current value | Outside the range |
| `TempSourceConnectionLost` | `sample every ≤ stale_timeout_ms` | Gap since the last sample | Gap ≥ 90 % of the timeout |
| `TempSignalStuck` | `changes within stuck_window_ms` | How long value or rolling counter stayed the same | ≥ 90 % of the window |
| Transport faults | – | – | – (no value limit) |

Only **RAISED** rows get a verdict: **✔ confirmed** (the collector sees the violation too) or **✖ not seen** (the Guardian raised a fault the collector cannot confirm → investigate). **CLEARED** rows show the values for context. Time checks allow 10 % tolerance for sample spacing.

---

## 4. Limits (`config/limits.toml`)

```toml
min_c = -40.0
max_c = 150.0
max_rate_c_per_s = 10.0
stuck_window_ms = 30000
stale_timeout_ms = 3000
```

- Values = defaults of `battery-thermal-guardian/config/guardian.toml` `[signal]`.
- Baked into the image at `/etc/evidence-collector/limits.toml`; missing file → same built-in defaults.
- **Keep in sync with the Guardian.** If the Guardian runs with `demo.toml` (5 s stuck window), use the same values here, or the collector judges against the wrong limit.
- Change without rebuild: `-v /root/limits.toml:/etc/evidence-collector/limits.toml:ro`.
- Loaded values are printed at startup: log line `expected limits {...}`.

---

## 5. Web UI

`http://<host>:7700/` (from the laptop through the SSH tunnel, section 8.3).

| Element | Meaning |
|---|---|
| **Start / Stop evidence** button | Starts or ends a run. Recording: red button, pulsing rings, scan line under the header, REC badge, timer |
| Live tiles | Temperature + rolling counter, Guardian state, Guardian alive / silent (heartbeat < 3 s), active faults |
| Fault evidence table | Newest first, latest 10 shown; new rows slide in and flash |
| Columns | #, time, fault (+ catalog id), event RAISED / CLEARED (+ "timeout"), previous → current °C with rolling counters, Δ °C, rate °C/s, limit check, Guardian state, Guardian reason |
| Counter | Total events, raised, cleared, "showing newest 10" |
| After Stop | Box with run id, counts, duration and the evidence folder |
| Logo | Top right, from `--logo`; hidden if the file is missing |

The page polls `/api/status` every 500 ms. Works offline (no external resources).

### REST

| Method | Path | Result |
|---|---|---|
| `GET` | `/` | Web UI |
| `GET` | `/logo` | Logo file (`--logo`) |
| `GET` | `/api/status` | Recording state, live values, newest rows, last run |
| `POST` | `/api/start` | Starts a run → `{"run_id": ...}` (409 if already recording) |
| `POST` | `/api/stop` | Ends the run, writes the evidence folder → run summary (409 if not recording) |

Scriptable, e.g. for openDuT:

```bash
curl -s -X POST http://127.0.0.1:7700/api/start
# ... inject fault ...
curl -s -X POST http://127.0.0.1:7700/api/stop
```

---

## 6. Evidence folder

On Stop: `<out>/<run-id>/`, run id = `run-YYYYMMDD-HHMMSS` (UTC).

| File | Content |
|---|---|
| `events.jsonl` | Every uProtocol message received during the run: `rx_ms`, `topic`, `message_id`, `event` |
| `faults.json` | The evidence rows (all of them, not only the latest 10) |
| `summary.json` | Run times, counts per fault, SOVD fault list **before** (at Start) and **after** (at Stop) |
| `report.md` | Readable table of all rows incl. limit check |

SOVD snapshots come from `--sovd` (default `http://127.0.0.1:7690/sovd/v1/apps/battery/faults`). With `--clear-sovd-on-start` the fault memory is cleared at Start, so the "after" snapshot contains only this run.

---

## 7. Options

| Option | Default | Meaning |
|---|---|---|
| `--listen` | `0.0.0.0:7700` | Web UI / REST address |
| `--out` | `/evidence` | Evidence folder |
| `--zenoh-config` | – | Zenoh JSON5; **required on AutoSD** (IPv4 only) |
| `--authority` | `evidence` | uProtocol authority of the collector |
| `--guardian-filter` | `//*/8002/1/FFFF` | Guardian topics |
| `--vss-topic` | `//*/8001/1/8001` | Raw sample topic |
| `--sovd` | `http://127.0.0.1:7690/sovd/v1/apps/battery/faults` | SOVD fault list; `""` = off |
| `--clear-sovd-on-start` | off | `DELETE` on `--sovd` at Start |
| `--limits` | `/etc/evidence-collector/limits.toml` | Expected limits |
| `--logo` | `/etc/evidence-collector/logo.png` | Logo (png / jpg / jpeg / svg) |
| `--table-rows` | `10` | Rows in the web UI |
| `RUST_LOG` (env) | `info,zenoh=warn` | Log level |

Arguments after the image name **replace** the image's default command (`--out /evidence --logo /etc/evidence-collector/logo.jpeg`), so pass `--out` and `--logo` again when adding others.

---

## 8. Build and run

### 8.1 Folder layout

```
evidence-collector/
├── Cargo.toml
├── Containerfile
├── config/limits.toml
├── src/main.rs
└── web/
    ├── index.html        # embedded into the binary at build time
    └── logo.jpeg         # copied into the image (must exist)
```

`index.html` is compiled into the binary: a UI change needs a rebuild. The logo is a separate file in the image.

### 8.2 Laptop: build and transfer

```bash
export REPO=/home/ashwin/Workspace/Hackathone2026/FEVengers/FEVengers_Hackathon_2026
cd $REPO
podman build -t localhost/evidence-collector:dev -f evidence-collector/Containerfile evidence-collector && \
podman save -o /tmp/evidence.tar localhost/evidence-collector:dev && \
scp -P 2222 /tmp/evidence.tar root@localhost:/root/ && \
ssh -p 2222 root@localhost "podman load -i /root/evidence.tar && rm /root/evidence.tar" && \
rm /tmp/evidence.tar
```

First build ~5–10 min. Tip: `ssh-copy-id -p 2222 root@localhost` once, so the chain does not stop at a password prompt (SSH closes the connection if the password is not typed in time).

### 8.3 AutoSD: run

Needs `/root/zenoh.json5` (IPv4-only Zenoh listener, see `LAUNCH.md` 4.1) and the running chain (`vss`, `guardian`; `sovd` for the snapshots).

```bash
mkdir -p /root/evidence
podman rm -f evidence 2>/dev/null
podman run -d --name evidence --restart=always --net=host --security-opt label=disable \
  -v /root/zenoh.json5:/etc/zenoh.json5:ro \
  -v /root/evidence:/evidence \
  localhost/evidence-collector:dev \
  --zenoh-config /etc/zenoh.json5 --out /evidence --logo /etc/evidence-collector/logo.jpeg

podman logs evidence
curl -sI http://127.0.0.1:7700/logo | head -3
```

Expect in the log: `expected limits {...}`, `subscribed`, `evidence collector web UI addr=0.0.0.0:7700`; `curl` → `200 OK`, `image/jpeg`.

| Option | Why |
|---|---|
| `--net=host` | Zenoh discovery of `vss` and `guardian`; port 7700; SOVD on 127.0.0.1 |
| `--zenoh-config` | AutoSD has IPv6 disabled |
| `-v /root/evidence:/evidence` | Evidence folders survive container restarts, readable on the VM |
| `--security-opt label=disable` | SELinux enforcing on AutoSD |

### 8.4 Laptop: open the UI

Run on the **laptop**, not in the VM (keep it open):

```bash
ssh -p 2222 -N -L 8700:127.0.0.1:7700 root@localhost
```

Open **`http://localhost:8700/`**.

### 8.5 Get the evidence onto the laptop

```bash
scp -P 2222 -r root@localhost:/root/evidence/run-20261007-163005 $REPO/evidence/
```

---

## 9. Demo run

1. Open the UI; live tiles show temperature, Guardian **alive**, state MONITORING.
2. **Start evidence**.
3. Cause a fault, e.g. unplug the AZ3166 for ~5 s, plug it back in.
4. Rows appear: `TempSourceConnectionLost` **RAISED** (timeout, "no sample for 3xxx ms", ✔ confirmed), then **CLEARED**.
5. **Stop evidence** → result box with the evidence folder.
6. Show `report.md` / `summary.json` (SOVD before / after) from the folder.

With `vss-sim` instead of the board, every scenario (stuck, spike, out-of-range, dropout, delay, duplicate, reorder) produces rows the same way.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Build: `COPY Cargo.lock*` no such file | Podman needs the file for a wildcard | Remove that line (current Containerfile has none) |
| Build: `stat "/src": no such file` | Files not in `src/`, `web/`, `config/` | Folder layout 8.1 |
| Build: `web/logo.jpeg` not found | Logo missing | Put it at `web/logo.jpeg` |
| `Failed to open Zenoh session` / `Address family not supported` | IPv6 disabled | `--zenoh-config /etc/zenoh.json5` |
| Tiles `–`, "no heartbeat" | Guardian not running or not reachable over Zenoh | `podman ps`; same `zenoh.json5` for all; `--net=host` |
| Temperature `–` | `vss` not publishing | `podman logs vss` (`publish sample`) |
| Rows without previous / current | Raw sample not received (topic differs) | `--vss-topic` must match the publisher |
| Limit check always "✖ not seen" | `limits.toml` differs from the Guardian's config | Copy the Guardian's `[signal]` values |
| SOVD snapshot `{"error": ...}` | Gateway not running | `podman ps`; `--sovd ""` to switch off |
| Logo missing | `--logo` not passed (arguments replace CMD) or file missing | 8.3 command; `curl -sI .../logo` |
| `ssh: connect ... port 2222` / `Address family not supported` for the tunnel | Tunnel started inside the VM | Run it on the laptop |
| `Connection closed by ... port 2222` during scp | Password prompt timed out | Type promptly or `ssh-copy-id` |
| Start → 409 | A run is already recording | Stop first |
