# Podman Migration – Ubuntu to AutoSD

> Created with AI assistance (Claude Opus 5.5, Anthropic).

How to move the fault chain containers (DFM, SOVD fault bridge, dummy Guardian), the fault catalog and the table script from the Ubuntu laptop into the AutoSD QEMU VM, and run them there.

Images are built on the laptop and transferred; nothing is rebuilt in AutoSD. Running the chain after migration: see `FAULT_CHAIN.md`.

---

## 1. Overview

```
Ubuntu laptop                                   AutoSD VM (QEMU, SSH :2222)
─────────────                                   ───────────────────────────
localhost/dfm:dev               ──podman save/scp/load──►  localhost/dfm:dev
localhost/sovd-fault-bridge:dev ──podman save/scp/load──►  localhost/sovd-fault-bridge:dev
localhost/dummy-guardian:dev    ──podman save/scp/load──►  localhost/dummy-guardian:dev
<repo>/catalogs/                ──scp──────────────────►   /root/catalogs/
scripts/faults.sh               ──scp──────────────────►   /root/faults.sh
```

| Item | Laptop | AutoSD |
|---|---|---|
| Images | built locally | loaded from tar |
| Catalog | `<repo>/catalogs` | `/root/catalogs` |
| Table script | `scripts/fault_host.sh` (jq) | `/root/faults.sh` (python3) |
| iceoryx2 folder | `/tmp/iceoryx2` | `/tmp/iceoryx2` |
| Fault memory | volume `dfm-store` | volume `dfm-store` (created on first run) |

---

## 2. Prerequisites

### 2.1 Laptop

All three images built (`podman images`):

```
localhost/dfm                dev
localhost/sovd-fault-bridge  dev
localhost/dummy-guardian     dev
```

Variables used below:

```bash
REPO=/home/ashwin/Workspace/Hackathone2026/FEVengers/FEVengers_Hackathon_2026
C=$REPO/catalogs
```

### 2.2 AutoSD VM

- Running x86_64 AutoSD image (KVM) with SSH forwarded to port 2222 (see `DFM_BRINGUP.md`).
- Login `root` / `password`.
- Check from the laptop:

```bash
ssh -p 2222 root@localhost "cat /etc/os-release | head -2; podman --version; python3 --version; df -h /var | tail -1"
```

Needs Podman, python3 and about 1 GB free in `/var` (three images ~85 MB each, plus temporary tar files).

Image architecture must match the VM: x86_64 images for the x86_64 VM.

---

## 3. Prepare folders in AutoSD

```bash
ssh -p 2222 root@localhost "mkdir -p /root/catalogs /root/images /tmp/iceoryx2"
```

| Folder | Purpose |
|---|---|
| `/root/catalogs` | Fault catalog, mounted read-only into DFM and reporter |
| `/root/images` | Temporary tar files during transfer |
| `/tmp/iceoryx2` | iceoryx2 discovery files, shared by all containers |

`/tmp/iceoryx2` must be recreated after a VM reboot.

---

## 4. Transfer images

### 4.1 All images (loop)

From the laptop:

```bash
for img in dfm sovd-fault-bridge dummy-guardian; do
  echo "== $img"
  podman save -o /tmp/$img.tar localhost/$img:dev
  scp -P 2222 /tmp/$img.tar root@localhost:/root/images/
  ssh -p 2222 root@localhost "podman load -i /root/images/$img.tar && rm /root/images/$img.tar"
  rm /tmp/$img.tar
done
```

### 4.2 One image (e.g. after a rebuild)

```bash
IMG=sovd-fault-bridge          # dfm | sovd-fault-bridge | dummy-guardian
podman save -o /tmp/$IMG.tar localhost/$IMG:dev
scp -P 2222 /tmp/$IMG.tar root@localhost:/root/images/
ssh -p 2222 root@localhost "podman load -i /root/images/$IMG.tar && rm /root/images/$IMG.tar"
```

After loading a new image, restart the matching container (section 7).

### 4.3 Alternative: stream without tar files

```bash
podman save localhost/$IMG:dev | ssh -p 2222 root@localhost podman load
```

### 4.4 Verify

```bash
ssh -p 2222 root@localhost podman images
```

---

## 5. Transfer catalog and script

```bash
scp -P 2222 $C/battery_guardian_catalog.json root@localhost:/root/catalogs/
scp -P 2222 $REPO/scripts/faults.sh root@localhost:/root/faults.sh
ssh -p 2222 root@localhost "chmod +x /root/faults.sh; ls -l /root/catalogs /root/faults.sh"
```

The DFM loads **every** `.json` in `/root/catalogs`. Keep only `battery_guardian_catalog.json` there.

Use `faults.sh` (python3), not `fault_host.sh` (jq): the AutoSD image has no `jq`.

---

## 6. Changes compared to Ubuntu

No image or code changes. Only runtime options and paths:

| | Ubuntu | AutoSD |
|---|---|---|
| SELinux option | none | `--security-opt label=disable` on every container |
| Catalog mount | `-v $C:/catalogs:ro` | `-v /root/catalogs:/catalogs:ro` |
| Cleanup of iceoryx2 files | `sudo rm ...` | `rm ...` (root) |
| Table script | `fault_host.sh` | `/root/faults.sh` |

Unchanged: `--ipc=host`, `--pid=host`, `/dev/shm` and `/tmp/iceoryx2` mounts, `--net=host` for the bridge, `dfm-store` volume.

---

## 7. Run each container in AutoSD

Open SSH windows from the laptop (`ssh -p 2222 root@localhost`):

| Window | Use |
|---|---|
| 1 | DFM and bridge, checks |
| 2 | Dummy Guardian (interactive) |
| 3 | `watch -n 1 /root/faults.sh` |

### 7.1 Clean state (window 1)

```bash
podman rm -f bridge dfm 2>/dev/null
rm -rf /tmp/iceoryx2/* ; rm -f /dev/shm/iox2_*
mkdir -p /tmp/iceoryx2
```

### 7.2 DFM (window 1)

```bash
podman run -d --name dfm --ipc=host --pid=host --restart=always \
  --security-opt label=disable \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  -v /root/catalogs:/catalogs:ro -v dfm-store:/store \
  localhost/dfm:dev
sleep 2; podman logs dfm
```

Expect `Loaded catalog 'battery' ... (4 faults)` and `DFM transport listening...`.

### 7.3 SOVD fault bridge (window 1)

```bash
podman run -d --name bridge --net=host --ipc=host --pid=host \
  --security-opt label=disable \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  localhost/sovd-fault-bridge:dev
sleep 1; podman logs bridge
/root/faults.sh
```

Expect `listening on 0.0.0.0:7691` and the four faults, all `ok`.

### 7.4 Fault table (window 3)

```bash
watch -n 1 /root/faults.sh
```

### 7.5 Dummy Guardian (window 2)

```bash
podman run --rm -it --ipc=host --pid=host \
  --security-opt label=disable \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  -v /root/catalogs:/catalogs:ro \
  localhost/dummy-guardian:dev interactive
> set stuck
```

Window 3 shows `btg.temp.stuck  FAULTY  yes  1`. Test sequence and expected results: `FAULT_CHAIN.md` section 4.3.

### 7.6 Restart after loading a new image

| New image | Restart |
|---|---|
| `dfm` | 7.1 → 7.2 → 7.3 (bridge must reconnect) |
| `sovd-fault-bridge` | `podman rm -f bridge`, then 7.3 |
| `dummy-guardian` | Just start it again (7.5) |

---

## 8. Optional: read the table from the laptop

QEMU forwards only SSH. To query the AutoSD bridge from the laptop, open an SSH tunnel and run the host script:

```bash
podman rm -f bridge                                  # free port 7691 on the laptop
ssh -p 2222 -L 7691:localhost:7691 root@localhost    # keep open
./scripts/fault_host.sh                              # second laptop terminal
```

---

## 9. Checklist

- [ ] Three images visible in `ssh -p 2222 root@localhost podman images`
- [ ] `/root/catalogs/battery_guardian_catalog.json` present, no other `.json`
- [ ] `/root/faults.sh` executable
- [ ] `/tmp/iceoryx2` exists
- [ ] DFM log: `Loaded catalog 'battery' ... (4 faults)`
- [ ] `/root/faults.sh` shows four faults
- [ ] `set stuck` in the dummy Guardian shows `FAULTY` in the table

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `scp: Connection refused` | VM not running or SSH not forwarded | Boot the VM; check port 2222 |
| `podman load`: `no space left on device` | `/var` full | `df -h /var`; remove tar files; `podman image prune` |
| `exec format error` | Image architecture does not match VM | Use x86_64 images with the x86_64 VM |
| `Permission denied` on `/dev/shm`, `/tmp/iceoryx2` or `/catalogs` | SELinux | `--security-opt label=disable` on that container |
| DFM log: `No JSON catalog files found` | Catalog not copied | Section 5 |
| DFM loads `hvac` / `ivi` | Catalog mount missing | `-v /root/catalogs:/catalogs:ro` |
| `503 query timeout`, reporter `Timeout` | DFM down or stale iceoryx2 files | Section 7.1 → 7.3 |
| `faults.sh`: `SyntaxError` | Old script with escaped f-strings | Copy current `scripts/faults.sh` |
| Everything fails after VM reboot | `/tmp/iceoryx2` gone, containers stopped | Section 3 `mkdir`, then 7.1 → 7.3 |
