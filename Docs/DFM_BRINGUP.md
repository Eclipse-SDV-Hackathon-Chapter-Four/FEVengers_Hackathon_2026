# Disclaimer
Generated with AI assist
Claud

# DFM Bring-up Guide – Doctor Whodunit (FEVengers)

How to build the Eclipse OpenSOVD **Diagnostic Fault Manager (DFM)** as a Podman container, test it on Ubuntu, and run it inside the AutoSD QEMU VM.

Status: DFM container verified on Ubuntu laptop and in AutoSD (x86_64 QEMU) with the `tst_app` reporter.

---

## 1. What the DFM is

The DFM comes from [`eclipse-opensovd/fault-lib`](https://github.com/eclipse-opensovd/fault-lib) (Rust).

| Piece | Crate | Role |
|---|---|---|
| Fault library | `fault_lib` | Linked into the reporting app (later: Battery Thermal Guardian). `Reporter` publishes fault records. |
| DFM | `dfm_lib` + `dfm_bin` | Standalone process. Validates, debounces, tracks lifecycle, ages and persists faults. |
| Query server | inside `dfm_lib` | Answers OpenSOVD over iceoryx2 service `dfm/query`. |

Communication:

```
App (fault_lib Reporter) ──iceoryx2 publish──► DFM ◄──iceoryx2 req/resp "dfm/query"── OpenSOVD ◄──HTTP── tester
```

The DFM **manages** faults. It does not detect them (the Guardian does) and does not expose REST (OpenSOVD does).

---

## 2. Prerequisites

Ubuntu laptop:

```bash
sudo apt update && sudo apt install -y podman curl ovmf qemu-system-x86 qemu-utils
```

AutoSD VM (see section 5) with SSH on port 2222, login `root` / `password`.

---

## 3. Build the container image (laptop)

Containerfile: [`dfm-container/Containerfile`](../dfm-container/Containerfile)

It is a two-stage build:

| Stage | Purpose |
|---|---|
| Build | Rust image clones `fault-lib` and compiles `dfm_bin` and the demo reporter `tst_app`. `clang`/`libclang` are needed by iceoryx2's build; the pinned nightly toolchain is installed automatically. |
| Runtime | Small Debian image with only the two binaries and the sample fault catalogs from `fault-lib`. Default command: `dfm_bin --catalog-dir /catalogs --storage-dir /store`. |

Build:

```bash
cd dfm-container
podman build -t localhost/dfm:dev .
podman images | grep dfm
```

First build takes 10–20 minutes.

---

## 4. Test on Ubuntu

```bash
mkdir -p /tmp/iceoryx2
```

### 4.1 Terminal 1 – DFM

```bash
podman run -d --name dfm \
  --ipc=host \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  localhost/dfm:dev
podman logs -f dfm
```

Expected:

```
INFO dfm_bin: Loaded catalog 'hvac' from /catalogs/hvac_fault_catalog.json (2 faults)
INFO dfm_bin: Loaded catalog 'ivi' from /catalogs/ivi_fault_catalog.json (2 faults)
INFO dfm_bin: Starting DFM with query server (4 faults across 2 catalogs)
INFO dfm_bin: DFM ready
[W] "Config::global_config()" | No config file was loaded, a config with default values will be used.
INFO dfm_lib::fault_lib_communicator: DFM transport listening...
```

The `[W]` warning comes from iceoryx2 and is harmless.

### Validation 4.2 Terminal 2 – reporter (`tst_app`)

```bash
podman run --rm --name tst \
  --ipc=host \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  --entrypoint /usr/local/bin/tst_app \
  localhost/dfm:dev -c /catalogs/hvac_fault_catalog.json
```

`tst_app` reports every fault in the given catalog, alternating Passed/Failed every 200 ms for 20 rounds (~4 s), then exits.

Success: `Loop 0` … `Loop 19` in terminal 2 and new DFM log activity in terminal 1. For more DFM output, start it with `-e RUST_LOG=debug`.

### 4.3 Podman options explained

| Option | Why |
|---|---|
| `--ipc=host` | Share the host IPC namespace so iceoryx2 works across containers |
| `-v /dev/shm:/dev/shm` | Shared memory segments (the actual data) |
| `-v /tmp/iceoryx2:/tmp/iceoryx2` | iceoryx2 discovery files |
| `--entrypoint` | Run `tst_app` from the same image instead of `dfm_bin` |
| `--rm` | Delete the reporter container when it exits |

Start order: **DFM first**, then reporter.

---

## 5. Run in AutoSD (QEMU)

### 5.1 Transfer the image (from the laptop)

Save the image to a tar file on the laptop:

```bash
cd dfm-container
podman save -o dfm.tar localhost/dfm:dev
ls -lh dfm.tar
```

Copy it into the VM (note: `scp` uses capital `-P` for the port):

```bash
scp -P 2222 dfm.tar root@localhost:/root/
```

Load it inside the VM:

```bash
ssh -p 2222 root@localhost
podman load -i /root/dfm.tar
podman images          # localhost/dfm:dev should be listed
rm /root/dfm.tar       # free disk space; the image stays loaded
```

Check inside the VM: `podman images`.

### 5.3 Run inside AutoSD

AutoSD has **SELinux enforcing**, so add `--security-opt label=disable` to every container that mounts `/dev/shm` or `/tmp`.

Terminal 1 (VM):

```bash
mkdir -p /tmp/iceoryx2
podman run -d --name dfm \
  --ipc=host --security-opt label=disable \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  localhost/dfm:dev
podman logs -f dfm
```

Terminal 2 (VM):

```bash
podman run --rm --name tst \
  --ipc=host --security-opt label=disable \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  --entrypoint /usr/local/bin/tst_app \
  localhost/dfm:dev -c /catalogs/hvac_fault_catalog.json
```

Clean up: `podman rm -f dfm`

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `air`: `Unable to find EFI firmware` | Ubuntu OVMF file names | Section 5.1 symlinks, or `./air --ovmf-dir <dir>` |
| `tst_app` panics `publish failed` | Containers cannot see each other via iceoryx2 | Same `--ipc=host` and mounts on both; try `-v /tmp:/tmp`; run both as the same user |
| DFM shows nothing while `tst_app` runs | Low log level | `-e RUST_LOG=debug` on the DFM |
| `Permission denied` on `/dev/shm` in AutoSD | SELinux | `--security-opt label=disable` on both containers |
| `exec format error` | x86_64 image in aarch64 VM or vice versa | Match image and VM architecture |

---

## 7. Next steps

1. Replace `tst_app` with the Battery Thermal Guardian, using the same `fault_lib` Reporter API.
2. Add the DFM to the Ankaios manifest with the same Podman options (`--ipc=host`, `--security-opt label=disable`, `/dev/shm` and `/tmp/iceoryx2` mounts).
3. Connect OpenSOVD to the DFM query service `dfm/query`.

## 8 Additional Info Boot AutoSD

Image: `auto-osbuild-qemu-autosd10-developer-*-x86_64-*.qcow2` from
<https://autosd.sig.centos.org/AutoSD-10/nightly/sample-images/>.

Use **x86_64** on the laptop (KVM, near-native speed). aarch64 is fully emulated and very slow.

Boot helper `air`:

```bash
curl -o air "https://gitlab.com/CentOS/automotive/src/automotive-image-builder/-/raw/main/bin/air"
chmod +x air
```

`air` looks for `OVMF_CODE.fd` / `OVMF_VARS.fd`. Ubuntu ships `OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd`, so link them:

```bash
mkdir -p ~/.local/share/ovmf
ln -sf /usr/share/OVMF/OVMF_CODE_4M.fd ~/.local/share/ovmf/OVMF_CODE.fd
ln -sf /usr/share/OVMF/OVMF_VARS_4M.fd ~/.local/share/ovmf/OVMF_VARS.fd

./air --nographics auto-osbuild-qemu-autosd10-developer-*-x86_64-*.qcow2
```

Login: `root` / `password`. SSH from the laptop:

```bash
ssh -p 2222 root@localhost
```