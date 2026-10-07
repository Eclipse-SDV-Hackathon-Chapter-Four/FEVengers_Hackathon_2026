#!/usr/bin/env bash
# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# deploy-to-autosd.sh - load the images into a running AutoSD system and start them with Ankaios.
#
#   ./deploy/deploy-to-autosd.sh               load the images that changed, restart their workloads,
#                                              keep everything across reboots
#   ./deploy/deploy-to-autosd.sh --restart     also restart the workloads whose image did not change
#   ./deploy/deploy-to-autosd.sh --no-build    never load an image, even if the archive is newer
#   ./deploy/deploy-to-autosd.sh --no-persist  start the workloads for this boot only
#   ./deploy/deploy-to-autosd.sh status        show the Ankaios workloads on the target
#   ./deploy/deploy-to-autosd.sh check         compare the target with the manifest, name by name; changes nothing
#   ./deploy/deploy-to-autosd.sh sync          remove what the manifest does not use, add what is missing;
#                                              running workloads and stored images are left alone
#   ./deploy/deploy-to-autosd.sh clear-faults  empty the DFM's fault memory (start of a test run)
#   ./deploy/deploy-to-autosd.sh reset [--yes] remove our workloads, images and files from the target;
#                                              without --yes it only shows what it would remove
#
# The deployment is persistent: the manifest becomes the Ankaios startup
# manifest on the target, so the workloads start by themselves at every boot.
#
# Run ./deploy/build-images.sh first. An image is loaded only if the archive
# in build/images/ holds another build than the target has stored; only the
# workloads of loaded images are restarted (all of ours if one of them is a
# workload that others depend on, such as the DFM). Workloads of other images
# (the MQTT broker) are left running, and workloads on the target that the
# manifest does not list are removed.
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

# Everything the deployment puts on the target lives in this folder.
T_DATA=/var/lib/fevengers
# Fault catalogs on the target (mounted into the dfm and guardian workloads).
T_CATALOGS=$T_DATA/catalogs
# Fault monitor page, served by the opensovd-gateway workload on /ui/.
WEBUI_DIR="$REPO/opensovd-gateway-dfm/webui"
T_WEBUI=$T_DATA/webui
# Evidence runs written by the evidence-collector workload (one folder per run).
T_EVIDENCE=$T_DATA/evidence
# Fault table for the terminal, used on the target as "watch -n 1 /root/faults.sh".
FAULTS_SCRIPT="$REPO/opensovd-gateway-dfm/faults.sh"

usage() { sed -n '4,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

# Id of the image inside an archive written by "podman save" / "docker save":
# the name of its config blob. Read with tar, so no container engine is needed.
archive_id() {
  tar -xOf "$1" manifest.json 2>/dev/null | tr -d ' \n' \
    | sed -n 's/.*"Config":"\([^"]*\)".*/\1/p' | sed 's|.*/||; s|\.json$||'
}

# Names of the images stored on the target, and the id of one of them (from $FACTS).
target_images()   { section images | awk '{print $1}'; }
target_image_id() { section images | awk -v i="$1" '$1 == i {sub("^sha256:", "", $2); print $2; exit}'; }

# Workloads that other workloads depend on ("dependencies:" in the manifest).
dependency_targets() {
  awk '/^      [A-Za-z0-9_-]+:[[:space:]]*ADD_COND/ {n = $1; sub(":", "", n); print n}' "$MANIFEST" | sort -u
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

# Loads the images whose archive holds another build than the target has
# stored. Sets CHANGED_IMAGES to the images that were loaded. Needs $FACTS.
load_images() {
  local image tar want have
  CHANGED_IMAGES=""
  for image in $(own_images); do
    tar="$(archive_of "$image")"
    [ -f "$tar" ] || fail "$image: archive missing ($tar). Run ./deploy/build-images.sh"
  done
  for image in $(own_images); do
    tar="$(archive_of "$image")"
    want="$(archive_id "$tar")"
    have="$(target_image_id "$image")"
    if [ -n "$want" ] && [ "$want" = "$have" ]; then
      log "up to date, not loaded: $image"
      continue
    fi
    log "loading $image ($(du -h "$tar" | cut -f1))"
    # Streamed over SSH: nothing is stored twice on the target's small disk.
    target 'podman load -q >/dev/null' <"$tar" || fail "$image: podman load failed on the target"
    CHANGED_IMAGES="$CHANGED_IMAGES $image"
  done
}

prepare_vm() {
  local f
  log "preparing the target ($T_IOX and $T_DATA/{catalogs,webui,evidence})"
  target "mkdir -p $T_IOX $T_CATALOGS $T_WEBUI $T_EVIDENCE"
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
# service that was replaced). "ank apply" would leave them running. Needs $FACTS.
stale_workloads() {
  local name wanted
  wanted=" $(manifest_images | awk '{print $1}' | tr '\n' ' ')"
  for name in $(section workloads | awk '{print $1}'); do
    case "$wanted" in
      *" $name "*) ;;
      *) echo "$name" ;;
    esac
  done
}

# Removes stale workloads, restarts the workloads that need it and applies
# the manifest. Needs $FACTS, $CHANGED_IMAGES and $RESTART_ALL.
apply_manifest() {
  local stale name image state dep restart="" all
  all="$(own_workloads | tr '\n' ' ')"
  stale="$(stale_workloads | tr '\n' ' ')"
  # The manifest is the whole desired state: what it does not list is removed.
  if [ -n "$stale" ]; then
    log "removing workloads that are not in the manifest: $stale"
    # shellcheck disable=SC2086
    target "$ANK delete workload $stale" >/dev/null 2>&1 || true
  fi

  # Ankaios leaves an unchanged workload alone, so a new image is not picked
  # up by "ank apply": the workloads of loaded images are deleted first. So
  # is a workload that exists but does not run.
  while read -r name image; do
    case "$image" in localhost/*) ;; *) continue ;; esac
    state="$(section workloads | awk -v n="$name" '$1 == n {print $2}')"
    case " $CHANGED_IMAGES " in *" $image "*) restart="$restart$name "; continue ;; esac
    if [ "$RESTART_ALL" -eq 1 ] || { [ -n "$state" ] && [ "$state" != "Running(Ok)" ]; }; then
      restart="$restart$name "
    fi
  done <<EOF
$(manifest_images)
EOF
  # A workload that others depend on (the DFM) takes its peers with it: they
  # hold iceoryx2 connections to the instance that goes away.
  for dep in $(dependency_targets); do
    case " $restart" in *" $dep "*) restart="$all" ;; esac
  done

  if [ -n "$restart" ]; then
    log "restarting workloads: $restart"
    # shellcheck disable=SC2086
    target "$ANK delete workload $restart" >/dev/null 2>&1 || true
    if [ "$restart" = "$all" ]; then
      # All iceoryx2 users are down: stale files of the old containers would
      # make the new ones time out.
      target "rm -rf $T_IOX/* /dev/shm/iox2_* 2>/dev/null; true"
    fi
  else
    log "no workload needs a restart"
  fi
  # Starts what is missing and updates a workload whose definition changed.
  # ank prints a progress table per state change; the final table follows below.
  target "$ANK apply -" <"$MANIFEST" >/dev/null || fail "ank apply failed"
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

# ---------------------------------------------------------------- maintenance
# What the target reports, fetched in one SSH call: workloads with their
# state, stored images with their ids and the checksum of the startup manifest (without
# comments and blank lines, see manifest_digest).
target_facts() {
  target "
    echo '== workloads'; $ANK get workloads | awk 'NR > 1 {print \$1, \$4}'
    echo '== images'; podman images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.Id}}'
    echo '== startup'; sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*\$/d' $T_STARTUP_MANIFEST 2>/dev/null | sha256sum | cut -d' ' -f1
  "
}

# section <name>: the lines of one "== name" section of $FACTS.
section() { printf '%s\n' "$FACTS" | awk -v s="== $1" '$0 == s {on = 1; next} /^== / {on = 0} on'; }

# Checksum of the manifest without comments and blank lines, so that only a
# change of the workloads counts as a difference to the startup manifest.
manifest_digest() {
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$MANIFEST" | {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
  } | cut -d' ' -f1
}

# The manifest without the workloads that run our own images: what is left
# on the target after a reset (the MQTT broker). Comments are dropped.
base_manifest() {
  awk '
    function flush() { if (inblock && !own) printf "%s", block; block = ""; inblock = 0; own = 0 }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); inblock = 1 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    inblock { block = block $0 "\n"; if ($0 ~ /image:[[:space:]]*localhost\//) own = 1; next }
    { print }
    END { flush() }
  ' "$MANIFEST"
}

# Compares the target with the manifest, workload by workload. Changes nothing.
cmd_check() {
  local name image state stored have want tar problems=0 outdated=0 used
  FACTS="$(target_facts)" || fail "could not query the target"
  printf '%-18s %-14s %-9s %s\n' WORKLOAD STATE IMAGE "(image)"
  while read -r name image; do
    state="$(section workloads | awk -v n="$name" '$1 == n {print $2}')"
    stored=missing
    have="$(target_image_id "$image")"
    if [ -n "$have" ]; then
      stored=stored
      # One of ours: is it the build that lies in build/images/?
      tar="$(archive_of "$image")"
      case "$image" in
        localhost/*)
          if [ -f "$tar" ]; then
            want="$(archive_id "$tar")"
            if [ -n "$want" ] && [ "$want" != "$have" ]; then stored=outdated; outdated=1; fi
          fi ;;
      esac
    fi
    printf '%-18s %-14s %-9s %s\n' "$name" "${state:-missing}" "$stored" "$image"
    { [ "$state" = "Running(Ok)" ] && [ "$stored" = stored ]; } || problems=$((problems + 1))
  done <<EOF
$(manifest_images)
EOF

  # Running on the target, but not in the manifest.
  for name in $(section workloads | awk '{print $1}'); do
    manifest_images | awk -v n="$name" '$1 == n {found = 1} END {exit !found}' && continue
    warn "workload '$name' runs on the target but is not in the manifest (the next deploy removes it)"
    problems=$((problems + 1))
  done

  # Our images on the target that no workload of the manifest uses: only disk space.
  used="$(manifest_images | awk '{print $2}')"
  for image in $(target_images | grep '^localhost/' || true); do
    printf '%s\n' "$used" | grep -qxF "$image" && continue
    log "unused image on the target: $image (remove: podman rmi $image)"
  done

  if [ "$(section startup)" != "$(manifest_digest)" ]; then
    warn "the startup manifest on the target differs from $(basename "$MANIFEST"): after a reboot something else starts (fix: deploy again)"
    problems=$((problems + 1))
  fi

  [ "$outdated" -eq 0 ] || warn "outdated: build/images/ holds a newer build than the target runs (fix: $0)"
  [ "$problems" -eq 0 ] || fail "$problems difference(s) between the target and the manifest"
  log "ok: the target matches the manifest"
}

# Empties the DFM's fault memory through the SOVD interface, as at the start
# of a test run. Runs curl on the target, so no port forward is needed.
cmd_clear_faults() {
  local app url code
  app="$(sed -n 's/.*"--dfm-fault-app", *"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)"
  [ -n "$app" ] || fail "no --dfm-fault-app in $MANIFEST: cannot tell which SOVD app holds the faults"
  url="http://127.0.0.1:7690/sovd/v1/apps/$app/faults"
  log "clearing the fault memory of '$app' (DELETE $url on the target)"
  code="$(target "curl -s -m 10 -o /dev/null -w '%{http_code}' -X DELETE $url")" || true
  [ "$code" = 204 ] || fail "the SOVD gateway answered HTTP ${code:-nothing} instead of 204; is the opensovd-gateway workload running?"
  target "test -x /root/faults.sh && /root/faults.sh" || true
  log "cleared. A fault that is active right now appears again only when it next changes: the Guardian reports changes, not states"
}

# Brings the target in line with the manifest with as little change as
# possible: removes what the manifest does not use, adds what is missing.
# Unlike a full deploy it does not reload images that are already stored and
# does not restart workloads that are running.
cmd_sync() {
  local name image state tar stale="" broken="" unused="" changes=0
  FACTS="$(target_facts)" || fail "could not query the target"

  # Workloads on the target that the manifest does not list.
  for name in $(section workloads | awk '{print $1}'); do
    manifest_images | awk -v n="$name" '$1 == n {found = 1} END {exit !found}' || stale="$stale $name"
  done
  if [ -n "$stale" ]; then
    log "removing workloads that are not in the manifest:$stale"
    # shellcheck disable=SC2086
    target "$ANK delete workload $stale" >/dev/null 2>&1 || true
    changes=$((changes + 1))
  fi

  # Our images that the manifest needs but the target does not have.
  for image in $(own_images); do
    [ -z "$(target_image_id "$image")" ] || continue
    tar="$(archive_of "$image")"
    [ -f "$tar" ] || fail "$image is missing on the target and has no archive ($tar). Run ./deploy/build-images.sh"
    log "loading missing image $image ($(du -h "$tar" | cut -f1))"
    target 'podman load -q >/dev/null' <"$tar" || fail "$image: podman load failed on the target"
    changes=$((changes + 1))
  done

  # Catalog, web page and fault table: cheap, so always brought up to date.
  prepare_vm

  # Workloads of the manifest that are missing or not running. "ank apply"
  # adds the missing ones and leaves the running ones alone; one that exists
  # in another state has to be deleted first, or apply would not restart it.
  while read -r name image; do
    state="$(section workloads | awk -v n="$name" '$1 == n {print $2}')"
    [ "$state" = "Running(Ok)" ] && continue
    broken="$broken $name"
    # </dev/null: ssh must not swallow the rest of the workload list.
    [ -z "$state" ] || target "$ANK delete workload $name" </dev/null >/dev/null 2>&1 || true
  done <<EOF
$(manifest_images)
EOF
  if [ -n "$broken" ]; then
    log "starting workloads that are missing or not running:$broken"
    # ank prints a progress table per state change; the check below shows the result.
    target "$ANK apply -" <"$MANIFEST" >/dev/null || fail "ank apply failed"
    changes=$((changes + 1))
  fi

  # Our images on the target that no workload of the manifest uses.
  for image in $(target_images | grep '^localhost/' || true); do
    manifest_images | awk -v i="$image" '$2 == i {found = 1} END {exit !found}' || unused="$unused $image"
  done
  if [ -n "$unused" ]; then
    log "removing unused images:$unused"
    # shellcheck disable=SC2086
    target "podman rmi $unused" >/dev/null || warn "some unused images could not be removed (still in use?)"
    changes=$((changes + 1))
  fi
  # Untagged leftovers of images that were loaded again under the same name.
  target "podman image prune -f" >/dev/null 2>&1 || true

  # Startup manifest: what the target starts by itself after a reboot.
  if [ "$(section startup)" != "$(manifest_digest)" ]; then
    persist
    changes=$((changes + 1))
  fi

  [ "$changes" -gt 0 ] || log "nothing to remove or add"
  wait_running >/dev/null
  cmd_check
}

# Removes the deployment from the target: our workloads, images and files.
# Ankaios and the workloads of other images (the MQTT broker) stay.
cmd_reset() {
  local confirmed="$1" keep name workloads="" images volumes
  FACTS="$(target_facts)" || fail "could not query the target"
  keep=" $(base_manifest | awk '/^  [A-Za-z0-9_-]+:[[:space:]]*$/ {n = $1; sub(":", "", n); printf "%s ", n}')"
  for name in $(section workloads | awk '{print $1}'); do
    case "$keep" in
      *" $name "*) ;;
      *) workloads="$workloads $name" ;;
    esac
  done
  images="$(target_images | grep '^localhost/' | tr '\n' ' ' || true)"
  # Named volumes of the manifest ("--volume=<name>:<path>", no slash in the name).
  volumes="$(grep -o -- '--volume=[A-Za-z0-9_.-]*:' "$MANIFEST" | sed 's/--volume=//; s/://' | sort -u | tr '\n' ' ' || true)"

  log "reset removes from the target:"
  log "  workloads:${workloads:- none}"
  log "  images:    ${images:-none}"
  log "  volumes:   ${volumes:-none}"
  log "  files:     $T_DATA (including the recorded evidence runs)  /root/faults.sh"
  log "  startup manifest: reduced to$keep"
  log "kept: Ankaios, the workloads listed above as kept, and build/images/ on this machine"
  if [ "$confirmed" != yes ]; then
    log "nothing was changed. To do it: $0 reset --yes"
    return 0
  fi

  log "free space before: $(target "df -h /var | awk 'NR == 2 {print \$4}'")"
  # shellcheck disable=SC2086
  [ -z "$workloads" ] || target "$ANK delete workload $workloads" >/dev/null 2>&1 || true
  target "rm -rf $T_IOX/* /dev/shm/iox2_* 2>/dev/null; true"
  # shellcheck disable=SC2086
  [ -z "$images" ] || target "podman rmi -f $images" >/dev/null || warn "some images could not be removed"
  # Untagged leftovers of images that were loaded again under the same name.
  target "podman image prune -f" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  [ -z "$volumes" ] || target "podman volume rm $volumes" >/dev/null 2>&1 || true
  target "rm -rf $T_DATA /root/faults.sh"
  base_manifest | target "cat > $T_STARTUP_MANIFEST"
  log "free space after:  $(target "df -h /var | awk 'NR == 2 {print \$4}'")"
  show_status
  log "reset done. To deploy again: $0"
}

# ---------------------------------------------------------------- main
case "${1:-}" in
  status)       preflight; show_status; exit 0 ;;
  check)        preflight; cmd_check; exit 0 ;;
  sync)         preflight; cmd_sync; exit 0 ;;
  clear-faults) preflight; cmd_clear_faults; exit 0 ;;
  reset)
    case "${2:-}" in
      --yes) preflight; cmd_reset yes ;;
      "")    preflight; cmd_reset no ;;
      *)     fail "unknown option for reset: $2" ;;
    esac
    exit 0 ;;
esac

LOAD=1
PERSIST=1
RESTART_ALL=0
CHANGED_IMAGES=""
for arg in "$@"; do
  case "$arg" in
    --no-build)   LOAD=0 ;;
    --restart)    RESTART_ALL=1 ;;
    --no-persist) PERSIST=0 ;;
    --persist)    PERSIST=1 ;;   # the default; kept for older instructions
    -h|--help)    usage; exit 0 ;;
    *)            fail "unknown argument: $arg (try --help)" ;;
  esac
done

preflight
FACTS="$(target_facts)" || fail "could not query the target"
[ "$LOAD" -eq 0 ] || load_images
prepare_vm
apply_manifest
[ "$PERSIST" -eq 0 ] || persist
wait_running
log "deployed. SOVD faults: http://$AUTOSD_HOST:7690/sovd/v1/apps/battery/faults"
log "          fault monitor: http://$AUTOSD_HOST:7690/ui/"
log "          evidence runs: http://$AUTOSD_HOST:7700/"
if [ "$PERSIST" -eq 1 ]; then
  log "persistent: the workloads start by themselves at every boot"
else
  log "not persistent: after a reboot only the previous startup manifest is started"
fi
