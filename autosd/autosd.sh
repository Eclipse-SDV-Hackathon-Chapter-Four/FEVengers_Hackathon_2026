#!/usr/bin/env bash
# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# autosd.sh - start the Eclipse AutoSD QEMU image on this machine.
#
#   ./autosd/autosd.sh [--snapshot]      (re)start AutoSD and open a shell inside it
#   ./autosd/autosd.sh start [--snapshot] the same, without opening a shell (for other scripts)
#   ./autosd/autosd.sh setup             install the needed programs and download the image; starts nothing
#   ./autosd/autosd.sh ssh [cmd...]      shell (or one command) inside the running AutoSD
#   ./autosd/autosd.sh check             test that this machine can start it, change nothing
#   ./autosd/autosd.sh status            running or not, forwarded ports, board settings
#   ./autosd/autosd.sh stop              clean shutdown
#   ./autosd/autosd.sh console [--snapshot] boot in the foreground on the serial console (Ctrl-A X quits)
#
# Starting always gives a fresh instance: an AutoSD that is already running is
# shut down first, and any other program that holds one of the needed ports
# is stopped (sudo may ask for your password if it is not your process).
# To get a shell without restarting, use "ssh".
#
# A new machine needs nothing prepared: the first start does the setup by
# itself. Missing programs (QEMU, OVMF, ...) are installed by
# deploy/install-host-deps.sh (apt, dnf or pacman; sudo may ask for your
# password), and the image
#   eclipse-autosd-bootc-qemu-x86_64.qcow2
# is downloaded into this folder, next to this script (424 MB, 3.6 GB
# unpacked), and checked against the checksum of the build we use. An image
# that is already there is never downloaded again or replaced.
# --snapshot discards every disk write when AutoSD exits (image stays pristine).
#
# MQTT: the AZ3166 board publishes to <this machine's Wi-Fi IP>:1883. QEMU
# forwards that port to the MQTT broker inside AutoSD, so nothing else may
# listen on host port 1883 (a local Mosquitto is stopped at start).
#
# Tunables (environment):
#   CPUS=4  MEM=4G
#   AUTOSD_PORT=2222           host port for SSH (the deploy scripts use the same variable)
#   FORWARDS="1883:1883 7690:7690 7700:7700"   host:guest TCP forwards
#                              (MQTT broker, SOVD REST, evidence collector)
#   IMAGE=<path>               image file, if it is not in this folder
#   IMAGE_URL=<url>            where the packed image (.qcow2.xz) is downloaded from
#   IMAGE_SHA256=<hex>         checksum the download must have; empty = accept any build
#   RUN_DIR=<path>             pid file, monitor socket and logs; a second AutoSD on the same
#                              machine needs its own, with its own AUTOSD_PORT and FORWARDS
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG_NAME=autosd
AUTOSD_HOST=127.0.0.1
# shellcheck source=deploy/common.sh
. "$DIR/../deploy/common.sh"

IMAGE_NAME=eclipse-autosd-bootc-qemu-x86_64.qcow2
IMAGE="${IMAGE:-$DIR/$IMAGE_NAME}"
RUN_DIR="${RUN_DIR:-$DIR/.run}"
PIDFILE="$RUN_DIR/qemu.pid"
MONITOR="$RUN_DIR/monitor.sock"
SERIAL_LOG="$RUN_DIR/serial.log"
OVMF_VARS="$RUN_DIR/ovmf_vars.fd"

CPUS="${CPUS:-4}"
MEM="${MEM:-4G}"
MQTT_PORT=1883
# MQTT broker 1883 (from the board), SOVD REST 7690 and the evidence
# collector's web UI 7700 (both to the tester).
FORWARDS="${FORWARDS:-$MQTT_PORT:$MQTT_PORT 7690:7690 7700:7700}"

# The upstream release is rolling: the file behind this URL is replaced by
# newer builds. The checksum pins the build of 2026-10-02, the one the scripts
# in deploy/ were tested with, so everyone runs the same image.
IMAGE_URL="${IMAGE_URL:-https://github.com/eclipse-autosd/eclipse-autosd/releases/download/dev/$IMAGE_NAME.xz}"
IMAGE_SHA256="${IMAGE_SHA256-ebf8c0316a573d3aaba6730043aeb800d4bf550aa06f5ce2dd8220277b933cfa}"

usage() { sed -n '4,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

have() { command -v "$1" >/dev/null 2>&1; }

is_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

port_busy() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

# PIDs listening on a host TCP port. Processes of other users are only
# visible to root, hence the sudo fallback.
port_pids() {
  local pids
  pids="$(ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)"
  if [[ -z "$pids" ]]; then
    pids="$(sudo ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)"
  fi
  echo "$pids"
}

# "name (pid N)" of whoever listens on a port, without asking for a password.
port_owner() {
  local pid
  pid="$(ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -n 1)"
  if [[ -n "$pid" ]]; then
    echo "$(ps -o comm= -p "$pid") (pid $pid)"
  else
    echo "a program of another user"
  fi
}

wait_gone() {   # wait_gone <pid> <seconds>
  local i
  for ((i = 0; i < $2 * 2; i++)); do
    [[ -d "/proc/$1" ]] || return 0
    sleep 0.5
  done
  return 1
}

# Asks the guest of a QEMU process to shut down, through its monitor socket.
# Connects from the socket's folder: a UNIX socket path is limited to 108 bytes.
qemu_powerdown() {   # qemu_powerdown <monitor socket>
  ( cd "$(dirname "$1")" && python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(b"system_powerdown\n")
time.sleep(0.5)
' "$(basename "$1")" ) 2>/dev/null || true
}

# Stops one process that is in the way: a QEMU gets a guest shutdown request
# first (its disk may be an AutoSD image), a systemd service is stopped
# through systemd (so it is not restarted), anything else is terminated.
stop_process() {
  local pid="$1" name unit monitor run=""
  name="$(ps -o comm= -p "$pid" 2>/dev/null)" || return 0
  [[ -O "/proc/$pid" ]] || run=sudo

  if [[ "$name" == qemu-system* ]]; then
    monitor="$(tr '\0' '\n' <"/proc/$pid/cmdline" | grep -A1 -x -e '-monitor' | sed -n 's/^unix:\([^,]*\).*/\1/p')"
    if [[ -S "$monitor" ]]; then
      log "asking the guest of $name (pid $pid) to shut down ..."
      qemu_powerdown "$monitor"
      wait_gone "$pid" 30 && return 0
      log "no clean shutdown within 30 s, terminating it"
    fi
  else
    unit="$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [[ "$unit" == *.service && "$unit" != user@* ]]; then
      log "stopping systemd service $unit (sudo; it starts again at the next boot unless you disable it)"
      sudo systemctl stop "$unit" || true
      wait_gone "$pid" 10 && return 0
    fi
  fi

  $run kill "$pid" 2>/dev/null || true
  wait_gone "$pid" 5 && return 0
  $run kill -9 "$pid" 2>/dev/null || true
  wait_gone "$pid" 3 || fail "could not stop $name (pid $pid)"
}

# Makes a host port available by stopping whatever listens on it.
free_port() {
  local port="$1" pid pids
  port_busy "$port" || return 0
  pids="$(port_pids "$port")"
  [[ -n "$pids" ]] || fail "host port $port is in use, but the program holding it could not be identified"
  for pid in $pids; do
    [[ -d "/proc/$pid" ]] || continue   # already gone with an earlier port
    log "host port $port is used by $(ps -o comm= -p "$pid") (pid $pid): stopping it"
    stop_process "$pid"
  done
  port_busy "$port" && fail "host port $port is still in use"
  return 0
}

# Before a start: no AutoSD of ours running, every needed port free.
make_room() {
  local fwd
  if is_running; then
    log "AutoSD is already running: restarting it"
    cmd_stop
  fi
  free_port "$AUTOSD_PORT"
  for fwd in $FORWARDS; do
    free_port "${fwd%%:*}"
  done
}

# Address of this machine on the network the board is on (default route).
host_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

# UEFI firmware; the distributions disagree on folder and file names
# (Debian/Ubuntu, Fedora, Arch).
find_ovmf() {
  local d pair
  for d in /usr/share/OVMF /usr/share/edk2/ovmf /usr/share/edk2/x64; do
    for pair in OVMF_CODE_4M.fd:OVMF_VARS_4M.fd OVMF_CODE.4m.fd:OVMF_VARS.4m.fd OVMF_CODE.fd:OVMF_VARS.fd; do
      if [[ -f "$d/${pair%%:*}" && -f "$d/${pair##*:}" ]]; then
        OVMF_CODE="$d/${pair%%:*}"; OVMF_VARS_TEMPLATE="$d/${pair##*:}"; return 0
      fi
    done
  done
  return 1
}

# Programs this script needs that this machine does not have.
missing_programs() {
  local p out=""
  for p in qemu-system-x86_64 ssh python3 ss ip curl xz sha256sum; do
    have "$p" || out+="$p "
  done
  find_ovmf || out+="OVMF "
  echo "$out"
}

sha_ok() {   # sha_ok <file>: true if the file is the build IMAGE_SHA256 names
  [[ -f "$1" ]] || return 1
  [[ -n "$IMAGE_SHA256" ]] || return 0
  [[ "$(sha256sum "$1" | cut -d' ' -f1)" == "$IMAGE_SHA256" ]]
}

# Puts the image into place if it is not there: downloads the packed file
# (unless someone already copied it next to where the image belongs), checks
# it and unpacks it. An existing image is left alone.
fetch_image() {
  [[ -f "$IMAGE" ]] && return 0
  local packed="$IMAGE.xz" part="$IMAGE.xz.part" need_gb=4 free_kb
  [[ -f "$packed" ]] || need_gb=5
  mkdir -p "$(dirname "$IMAGE")"
  free_kb="$(df -Pk "$(dirname "$IMAGE")" | awk 'NR == 2 {print $4}')"
  (( free_kb >= need_gb * 1024 * 1024 )) \
    || fail "not enough disk space in $(dirname "$IMAGE"): $need_gb GB needed, $((free_kb / 1024 / 1024)) GB free"

  if [[ -f "$packed" ]]; then
    sha_ok "$packed" || fail "$packed is not the build we use (SHA-256 differs): remove it and run again to download the right one"
  else
    # A finished download whose rename was interrupted is not fetched again.
    if [[ -z "$IMAGE_SHA256" ]] || ! sha_ok "$part"; then
      log "downloading the AutoSD image (424 MB) from $IMAGE_URL"
      curl --fail --location --continue-at - --progress-bar --output "$part" "$IMAGE_URL" \
        || fail "download failed; run again, it continues where it stopped"
    fi
    if ! sha_ok "$part"; then
      local got
      got="$(sha256sum "$part" | cut -d' ' -f1)"
      rm -f "$part"
      fail "downloaded file has SHA-256 $got, not $IMAGE_SHA256. Run again; if it stays that way, upstream has published a newer build than the one we tested: get our build from a teammate, or accept the new one with IMAGE_SHA256=$got"
    fi
    mv "$part" "$packed"
  fi
  [[ -n "$IMAGE_SHA256" ]] && log "checksum ok" || warn "IMAGE_SHA256 is empty: the build was not checked"

  log "unpacking to $IMAGE (3.6 GB) ..."
  xz --decompress --stdout "$packed" >"$IMAGE.part" || { rm -f "$IMAGE.part"; fail "unpacking $packed failed"; }
  mv "$IMAGE.part" "$IMAGE"
  log "image ready; $packed is kept, to get back a pristine image delete the .qcow2 and run setup again"
}

kvm_usable() { [[ -r /dev/kvm && -w /dev/kvm ]]; }

kvm_hint() {
  kvm_usable || warn "KVM is not usable: AutoSD will run in slow software emulation ('$DIR/../deploy/install-host-deps.sh --check' says why)"
}

# What this machine needs to start AutoSD at all. Changes nothing.
require_startable() {
  local missing
  missing="$(missing_programs)"
  [[ -z "$missing" ]] || fail "missing on this machine: $missing('$0 setup' installs them)"
  find_ovmf
  [[ -f "$IMAGE" ]] || fail "image not found: $IMAGE ('$0 setup' downloads it)"
  kvm_hint
}

# Everything a new machine lacks: programs and image. Changes nothing on a
# machine that has both.
cmd_setup() {
  [[ -z "$(missing_programs)" ]] || "$DIR/../deploy/install-host-deps.sh" --run-only
  fetch_image
}

# Everything that must hold right before QEMU is started. Changes nothing.
preflight() {
  local fwd host
  require_startable
  # Starting frees these ports first (make_room); "check" only reports them.
  port_busy "$AUTOSD_PORT" && fail "host port $AUTOSD_PORT (SSH) is in use by $(port_owner "$AUTOSD_PORT"); starting stops that program"
  for fwd in $FORWARDS; do
    host="${fwd%%:*}"
    port_busy "$host" || continue
    if [[ "$host" == "$MQTT_PORT" ]]; then
      # With a local broker on 1883 the board would talk to that one and no
      # data would ever reach AutoSD.
      fail "host port $MQTT_PORT (MQTT from the board) is in use by $(port_owner "$host"); starting stops that program"
    fi
    fail "host port $host is in use by $(port_owner "$host"); starting stops that program"
  done
}

build_qemu_args() {   # build_qemu_args <snapshot:0|1>
  local netdev fwd
  preflight
  mkdir -p "$RUN_DIR"
  [[ -f "$OVMF_VARS" ]] || cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"

  # SSH only from this machine; the service ports are open to the network.
  netdev="user,id=n0,hostfwd=tcp:127.0.0.1:${AUTOSD_PORT}-:22"
  for fwd in $FORWARDS; do
    netdev+=",hostfwd=tcp:0.0.0.0:${fwd%%:*}-:${fwd##*:}"
  done

  QEMU_ARGS=(-machine q35 -smp "$CPUS" -m "$MEM")
  if kvm_usable; then
    QEMU_ARGS+=(-enable-kvm -cpu host)
  else
    QEMU_ARGS+=(-cpu max)
  fi
  QEMU_ARGS+=(
    -drive "file=$OVMF_CODE,if=pflash,format=raw,unit=0,readonly=on"
    -drive "file=$OVMF_VARS,if=pflash,format=raw,unit=1"
    -drive "file=$IMAGE,index=0,media=disk,format=qcow2,if=virtio"
    -device virtio-net-pci,netdev=n0 -netdev "$netdev"
    -device virtio-rng-pci
    -pidfile "$PIDFILE"
    -monitor "unix:$(basename "$MONITOR"),server,nowait"
  )
  if [[ "$1" == 1 ]]; then
    QEMU_ARGS+=(-snapshot)
    log "snapshot mode: disk writes are discarded on exit"
  fi
}

parse_snapshot() {
  SNAPSHOT=0
  case "${1:-}" in
    --snapshot) SNAPSHOT=1 ;;
    "") ;;
    *) fail "unknown option: $1" ;;
  esac
}

# What to put into the board firmware so its MQTT data ends up in AutoSD.
board_hint() {
  local ip
  ip="$(host_ip)"
  if [[ -z "$ip" ]]; then
    warn "this machine has no network address: the board cannot reach it"
    return 0
  fi
  log "board firmware (cloud_config.h): MQTT_LOCAL_BROKER_IP = $ip, MQTT_BROKER_PORT = $MQTT_PORT"
  log "if the board cannot connect, check the firewall: sudo ufw allow $MQTT_PORT/tcp"
}

cmd_check() {
  preflight
  log "ok: QEMU, firmware, image and ports $AUTOSD_PORT $(for f in $FORWARDS; do printf '%s ' "${f%%:*}"; done)are ready"
  board_hint
}

cmd_start() {
  parse_snapshot "${1:-}"
  # First make sure it can start at all: nothing is stopped for a start that
  # would fail anyway (missing image, QEMU or firmware).
  cmd_setup
  require_startable
  make_room
  build_qemu_args "$SNAPSHOT"
  : >"$SERIAL_LOG"
  # Started in RUN_DIR: the monitor socket is given as a relative path, because
  # a UNIX socket path is limited to 108 bytes and the repo may sit deep.
  ( cd "$RUN_DIR" && qemu-system-x86_64 "${QEMU_ARGS[@]}" -display none -serial "file:$SERIAL_LOG" -daemonize )
  log "started (pid $(cat "$PIDFILE")), waiting for SSH ..."
  local i
  for ((i = 0; i < 90; i++)); do
    if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$AUTOSD_PORT && head -c 4 <&3" 2>/dev/null | grep -q SSH; then
      log "ready"
      log "forwards (host->guest): ${AUTOSD_PORT}->22 ${FORWARDS//:/->}"
      board_hint
      return 0
    fi
    is_running || fail "qemu exited during boot, see $SERIAL_LOG"
    sleep 1
  done
  fail "SSH did not come up in 90 s, see $SERIAL_LOG"
}

cmd_console() {
  parse_snapshot "${1:-}"
  # First make sure it can start at all: nothing is stopped for a start that
  # would fail anyway (missing image, QEMU or firmware).
  cmd_setup
  require_startable
  make_room
  build_qemu_args "$SNAPSHOT"
  log "serial console, login root / password, quit with Ctrl-A X"
  cd "$RUN_DIR"
  exec qemu-system-x86_64 "${QEMU_ARGS[@]}" -nographic
}

cmd_ssh() {
  is_running || fail "AutoSD is not running (start it: $0)"
  target "$@"
}

cmd_status() {
  if is_running; then
    log "running (pid $(cat "$PIDFILE")), ssh on 127.0.0.1:$AUTOSD_PORT"
    tr '\0' ' ' <"/proc/$(cat "$PIDFILE")/cmdline" | grep -o 'hostfwd=[^, ]*' | sed 's/^/  /'
    board_hint
  else
    log "not running"
  fi
}

cmd_stop() {
  is_running || { log "not running"; return 0; }
  local pid i
  pid="$(cat "$PIDFILE")"
  log "requesting shutdown ..."
  qemu_powerdown "$MONITOR"
  for ((i = 0; i < 30; i++)); do
    kill -0 "$pid" 2>/dev/null || { log "stopped"; rm -f "$PIDFILE" "$MONITOR"; return 0; }
    sleep 1
  done
  log "still running after 30 s, killing"
  kill "$pid" 2>/dev/null || true
  rm -f "$PIDFILE" "$MONITOR"
}

case "${1:-}" in
  ""|--snapshot)
    cmd_start "$@"
    log "opening a shell inside AutoSD (leave it with 'exit'; AutoSD keeps running)"
    cmd_ssh ;;
  start)    shift; cmd_start "$@" ;;
  check)    cmd_check ;;
  setup)    cmd_setup; require_startable; log "ready: start AutoSD with $0" ;;
  console)  shift; cmd_console "$@" ;;
  ssh)      shift; cmd_ssh "$@" ;;
  status)   cmd_status ;;
  stop)     cmd_stop ;;
  -h|--help) usage ;;
  *)        fail "unknown command: $1 (try --help)" ;;
esac
