# Dummy Battery Thermal Guardian – Build and Run

> Created with AI assistance (Claude Opus 5.5, Anthropic).

> **Historical.** The dummy Guardian described here was used to set and clear the four faults by hand before the real Battery Thermal Guardian reported to the DFM itself. Its code (`dummy_errortrigger/dummy-guardian/`) was removed from the repository on 7 October 2026, so the build and run commands below no longer work. The code is in the git history up to commit `0fda212` (`git show 0fda212:<path>`). To trigger faults now: the buttons of the AZ3166 board, or a test MQTT message (see [`BUILD_IMAGES.md`](BUILD_IMAGES.md)).

A stand-in for the Battery Thermal Guardian. Instead of monitoring temperature, it sets and clears the four Guardian faults on command and reports them to the Eclipse OpenSOVD **DFM**, using the same reporting code the real Guardian will use.

To see the reported faults, run the DFM and SOVD fault bridge first: see [`FAULT_CHAIN.md`](FAULT_CHAIN.md).

---

## 1. Faults

Defined in `catalogs/battery_guardian_catalog.json` (catalog id `battery`). The DFM and the dummy app must load the **same** file.

| CLI name | Fault ID | Meaning |
|---|---|---|
| `connection_lost` | `btg.src.connection_lost` | No data from the AZ3166 within timeout |
| `out_of_range` | `btg.temp.out_of_range` | Temperature outside plausible range |
| `stuck` | `btg.temp.stuck` | Temperature value frozen |
| `spike` | `btg.temp.spike` | Implausible jump between samples |

All debounce fields are `null`: the Guardian owns debouncing, the DFM records exactly what is reported.

---

## 2. Project layout

```
dummy-guardian/
├── Cargo.toml        # fault_lib + common, pinned to fault-lib commit 12dac502
├── Containerfile     # two-stage build, toolchain nightly-2025-07-14
├── .gitignore
└── src/
    ├── faults.rs     # REUSABLE: copy into the real Guardian unchanged
    └── main.rs       # throwaway test driver
```

### `src/faults.rs` (reuse in the Guardian)

| Item | What it does |
|---|---|
| `GuardianFault` | Enum of the four faults, with catalog IDs and CLI names |
| `GuardianFaults::new(catalog)` | Loads the catalog, connects to the DFM (`FaultApi`), creates one `Reporter` per fault. Fails if the DFM does not answer the catalog handshake |
| `GuardianFaults::set(fault, active)` | Reports `Failed` (active) or `Passed` (cleared) **only when the state changes**. Never panics on a failed report |
| `GuardianFaults::is_active(fault)` | Last reported state |

Usage in the real Guardian:

```rust
let mut faults = GuardianFaults::new("/catalogs/battery_guardian_catalog.json".into())?;

// in the monitoring loop, with the CURRENT condition:
faults.set(GuardianFault::Stuck, stuck_detected);
faults.set(GuardianFault::Spike, spike_detected);
```

Keep the `GuardianFaults` value alive for the whole program: dropping it disconnects from the DFM.

---

## 3. Build

Prerequisite: Podman.

```bash
tar xzf dummy-guardian.tar.gz      # or clone from the team repo
cd dummy-guardian
podman build -t localhost/dummy-guardian:dev .
```

First build takes 10–20 minutes (toolchain and iceoryx2 compile).

---

## 4. Run (Ubuntu)

The DFM must already be running with the same catalog (see `FAULT_CHAIN.md`).

```bash
C=/home/ashwin/Workspace/Hackathone2026/FEVengers/FEVengers_Hackathon_2026/catalogs
```

### Scenario mode

Sets each fault, holds it, then clears it. Good for scripts and campaign runs.

```bash
podman run --rm --ipc=host --pid=host \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 -v $C:/catalogs:ro \
  localhost/dummy-guardian:dev scenario --hold-secs 5
```

### Interactive mode

Stays running like the real Guardian and reads commands from stdin.

```bash
podman run --rm -it --ipc=host --pid=host \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 -v $C:/catalogs:ro \
  localhost/dummy-guardian:dev interactive
```

| Command | Effect |
|---|---|
| `set <fault>` | Report `Failed` for the fault |
| `clear <fault>` | Report `Passed` for the fault |
| `status` | Show the last reported state of all four faults |
| `quit` | Exit |

Example:

```
> set stuck
> status
  connection_lost  ok
  out_of_range     ok
  stuck            FAILED
  spike            ok
> clear stuck
> quit
```

### Options

| Option | Default | |
|---|---|---|
| `-c, --catalog` | `/catalogs/battery_guardian_catalog.json` | Catalog path inside the container |
| `scenario --hold-secs` | `5` | Seconds each fault stays active |
| `RUST_LOG` (env) | `info` | e.g. `-e RUST_LOG=debug` for fault_lib IPC details |

### Podman options

| Option | Why |
|---|---|
| `--ipc=host`, `--pid=host` | iceoryx2 shared-memory IPC with the DFM container |
| `-v /dev/shm:/dev/shm`, `-v /tmp/iceoryx2:/tmp/iceoryx2` | Shared memory and iceoryx2 discovery files |
| `-v $C:/catalogs:ro` | Same catalog as the DFM |
| `-it` | Interactive mode only: keyboard input |

---

## 5. Run in AutoSD

Transfer the image (from the laptop):

```bash
podman save -o dummy-guardian.tar localhost/dummy-guardian:dev
scp -P 2222 dummy-guardian.tar root@localhost:/root/
scp -P 2222 -r $C root@localhost:/root/catalogs
ssh -p 2222 root@localhost podman load -i /root/dummy-guardian.tar
```

Run inside the VM. Add `--security-opt label=disable` (SELinux):

```bash
podman run --rm -it --ipc=host --pid=host --security-opt label=disable \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 -v /root/catalogs:/catalogs:ro \
  localhost/dummy-guardian:dev interactive
```

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `error: cannot connect to DFM (is it running?): ... Timeout` | DFM not running or IPC not shared | `podman ps`; start the DFM first; same IPC options and mounts on both; clean stale iceoryx2 state (see `FAULT_CHAIN.md`) |
| `error: cannot load catalog ...` | Wrong path or invalid JSON | Check the `-v` mount; `python3 -m json.tool <file>` |
| `fault ... not in catalog` | Catalog without the four Guardian faults | Use `battery_guardian_catalog.json` |
| `fault ... report failed` (app keeps running) | DFM went away after startup | Restart the DFM; the next `set` retries |
| Interactive mode exits immediately | `-it` missing | Add `-it` |
