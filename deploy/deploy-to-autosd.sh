#!/usr/bin/env bash
# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# deploy-to-autosd.sh - load the images into a running AutoSD system and start them with Ankaios.
#
#   ./deploy/deploy-to-autosd.sh               load the images, start the workloads, keep them across reboots
#   ./deploy/deploy-to-autosd.sh --no-build    same, without loading the images again (they are already on the target)
#   ./deploy/deploy-to-autosd.sh --no-persist  start the workloads for this boot only
#   ./deploy/deploy-to-autosd.sh status        show the Ankaios workloads on the target
#
# The deployment is persistent: the manifest becomes the Ankaios startup
# manifest on the target, so the workloads start by themselves at every boot.
#
# Run ./deploy/build-images.sh first. Only the localhost/* images named in the
# manifest are loaded; workloads that use them are restarted, other workloads
# of the manifest (e.g. the MQTT broker) are left running, and workloads on
# the target that the manifest does not list are removed.
#
# The target is reached over SSH. Default is the QEMU image on this machine
# (127.0.0.1:2222, no IP needed); for a device on the network set AUTOSD_HOST
# and AUTOSD_PORT. Needed on the target: podman, and Ankaios running
# (./deploy/setup-autosd.sh installs it).
#
# Tunables (environment):
#   AUTOSD_HOST  AUTOSD_PORT  AUTOSD_USER  AUTOSD_PASSWORD   see deploy/common.sh
#   IMAGES_DIR=build/images
#   MANIFEST=deploy/ankaios-manifest.yaml
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG_NAME=deploy
# shellcheck source=deploy/common.sh
. "$REPO/deploy/common.sh"
IMAGES_DIR="${IMAGES_DIR:-$REPO/build/images}"
MANIFEST="${MANIFEST:-$REPO/deploy/ankaios-manifest.yaml}"

# Fault catalogs on the target (mounted into the dfm and guardian workloads).
T_CATALOGS=/var/lib/fevengers/catalogs
# Fault monitor page, served by the opensovd-gateway workload on /ui/.
WEBUI_DIR="$REPO/opensovd-gateway-dfm/webui"
T_WEBUI=/var/lib/fevengers/webui
# Fault table for the terminal, used on the target as "watch -n 1 /root/faults.sh".
FAULTS_SCRIPT="$REPO/opensovd-gateway-dfm/faults.sh"

usage() { sed -n '4,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- manifest
# Prints "workload image" for every workload of the manifest.
manifest_images() {
  awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { name = $1; sub(":", "", name) }
    /^[[:space:]]+image:[[:space:]]/  { print name, $2 }
  ' "$MANIFEST"
}

# Workloads that run an image we build ourselves (localhost/<name>:<tag>).
own_workloads() { manifest_images | awk '$2 ~ /^localhost\// { print $1 }'; }
own_images()    { manifest_images | awk '$2 ~ /^localhost\// { print $2 }' | sort -u; }

archive_of() {   # localhost/<name>:<tag> -> <IMAGES_DIR>/<name>.tar
  local name="${1#localhost/}"
  echo "$IMAGES_DIR/${name%%:*}.tar"
}

# ---------------------------------------------------------------- steps
preflight() {
  [ -f "$MANIFEST" ] || fail "manifest not found: $MANIFEST"
  [ -n "$(own_workloads)" ] || fail "no localhost/* image in $MANIFEST"
  require_target
  target 'command -v podman >/dev/null' || fail "podman not found on the target"
  target "command -v ank >/dev/null && $ANK get agents >/dev/null 2>&1" \
    || fail "Ankaios is not installed or not running on the target. Run ./deploy/setup-autosd.sh"
}

load_images() {
  local image tar
  for image in $(own_images); do
    tar="$(archive_of "$image")"
    [ -f "$tar" ] || fail "$image: archive missing ($tar). Run ./deploy/build-images.sh"
  done
  for image in $(own_images); do
    tar="$(archive_of "$image")"
    log "loading $image ($(du -h "$tar" | cut -f1))"
    # Streamed over SSH: nothing is stored twice on the target's small disk.
    target 'podman load -q >/dev/null' <"$tar" || fail "$image: podman load failed on the target"
  done
}

prepare_vm() {
  local f
  log "preparing the target ($T_IOX, $T_CATALOGS, $T_WEBUI)"
  target "mkdir -p $T_IOX $T_CATALOGS $T_WEBUI"
  for f in "$REPO"/catalogs/*.json; do
    [ -f "$f" ] || fail "no fault catalog in catalogs/"
    target "cat > $T_CATALOGS/$(basename "$f")" <"$f"
  done
  for f in "$WEBUI_DIR"/*; do
    [ -f "$f" ] || fail "no web UI files in ${WEBUI_DIR#"$REPO"/}/"
    target "cat > $T_WEBUI/$(basename "$f")" <"$f"
  done
  if [ -f "$FAULTS_SCRIPT" ]; then
    target "cat > /root/faults.sh && chmod +x /root/faults.sh" <"$FAULTS_SCRIPT"
  fi
}

# Workloads running on the target that the manifest no longer lists (e.g. a
# service that was replaced). "ank apply" would leave them running.
stale_workloads() {
  local name wanted
  wanted=" $(manifest_images | awk '{print $1}' | tr '\n' ' ')"
  for name in $(target "$ANK get workloads" | awk 'NR > 1 {print $1}'); do
    case "$wanted" in
      *" $name "*) ;;
      *) echo "$name" ;;
    esac
  done
}

apply_manifest() {
  local workloads stale
  workloads="$(own_workloads | tr '\n' ' ')"
  stale="$(stale_workloads | tr '\n' ' ')"
  # The manifest is the whole desired state: what it does not list is removed.
  if [ -n "$stale" ]; then
    log "removing workloads that are not in the manifest: $stale"
    # shellcheck disable=SC2086
    target "$ANK delete workload $stale" >/dev/null 2>&1 || true
  fi
  # Ankaios leaves an unchanged workload alone, so a new image would not be
  # picked up: delete our workloads first, then apply the whole manifest.
  log "restarting workloads: $workloads"
  # shellcheck disable=SC2086
  target "$ANK delete workload $workloads" >/dev/null 2>&1 || true
  # Stale iceoryx2 files of the old containers make the new ones time out.
  target "rm -rf $T_IOX/* /dev/shm/iox2_* 2>/dev/null; true"
  target "$ANK apply -" <"$MANIFEST" || fail "ank apply failed"
}

persist() {
  log "making the deployment persistent"
  # Startup manifest: Ankaios recreates the workloads when the server starts.
  target "mkdir -p $(dirname "$T_STARTUP_MANIFEST") && cat > $T_STARTUP_MANIFEST" <"$MANIFEST"
  # /tmp is a tmpfs: recreate the iceoryx2 folder before the agent starts containers.
  if target "test -f $T_UNIT_DIR/ank-agent.service"; then
    target "mkdir -p $T_UNIT_DIR/ank-agent.service.d && cat > $T_UNIT_DIR/ank-agent.service.d/fevengers.conf && systemctl --user daemon-reload" <<EOF
[Service]
ExecStartPre=/usr/bin/mkdir -p $T_IOX
EOF
  else
    warn "ank-agent is not a user unit of $AUTOSD_USER: create $T_IOX at boot yourself"
  fi
  target "grep -q -- '--startup-manifest $T_STARTUP_MANIFEST' $T_UNIT_DIR/ank-server.service 2>/dev/null" \
    || warn "ank-server is not started with --startup-manifest $T_STARTUP_MANIFEST: workloads will not come back after a reboot"
}

show_status() {
  target "$ANK get workloads"
}

# Waits until every workload of the manifest is running; fails after 60 s.
wait_running() {
  local i out pending=""
  for i in $(seq 1 30); do
    out="$(show_status)"
    pending="$(printf '%s\n' "$out" | awk 'NR > 1 && $0 !~ /Running\(Ok\)/ { print $1 }' | tr '\n' ' ')"
    [ -z "$pending" ] && { printf '%s\n' "$out"; return 0; }
    sleep 2
  done
  printf '%s\n' "$out"
  fail "not running after 60 s: $pending(logs: podman logs <container> on the target)"
}

# ---------------------------------------------------------------- main
LOAD=1
PERSIST=1
for arg in "$@"; do
  case "$arg" in
    status)      preflight; show_status; exit 0 ;;
    --no-build)  LOAD=0 ;;
    --no-persist) PERSIST=0 ;;
    --persist)    PERSIST=1 ;;   # the default; kept for older instructions
    -h|--help)   usage; exit 0 ;;
    *)           fail "unknown argument: $arg (try --help)" ;;
  esac
done

preflight
[ "$LOAD" -eq 0 ] || load_images
prepare_vm
apply_manifest
[ "$PERSIST" -eq 0 ] || persist
wait_running
log "deployed. SOVD faults: http://$AUTOSD_HOST:7690/sovd/v1/apps/battery/faults"
log "          fault monitor: http://$AUTOSD_HOST:7690/ui/"
if [ "$PERSIST" -eq 1 ]; then
  log "persistent: the workloads start by themselves at every boot"
else
  log "not persistent: after a reboot only the previous startup manifest is started"
fi
