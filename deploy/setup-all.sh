#!/usr/bin/env bash
# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# setup-all.sh - from a fresh clone on a new machine to the running system, in one command.
#
#   ./deploy/setup-all.sh             do every step below that is not done yet
#   ./deploy/setup-all.sh --no-build  do not build the service images (use the archives in build/images/)
#   ./deploy/setup-all.sh --check     only report the state of every step, change nothing
#
# Steps, each one a script of its own that can also be run alone:
#   1. ./deploy/install-host-deps.sh   packages on this machine: QEMU, OVMF, ... and Podman
#   2. ./autosd/autosd.sh setup        the AutoSD image, downloaded into autosd/
#   3. ./autosd/autosd.sh start        boot AutoSD; one that is already running is kept
#   4. ./deploy/setup-autosd.sh        Ankaios inside AutoSD
#   5. ./deploy/build-images.sh        build the service images (first time: about 20 minutes)
#   6. ./deploy/deploy-to-autosd.sh    load them into AutoSD and start the workloads
#
# Every step leaves alone what is already there, so running this again after
# a failure, or on a machine that is already set up, only does what is missing.
# sudo may ask for your password in step 1 (package install) and in
# step 3 (if another program holds a port AutoSD needs).
#
# Needs internet: packages, the AutoSD image (424 MB), Ankaios, the base
# images and Rust crates of the builds, the MQTT broker image.
#
# Tunables (environment): those of the scripts above, see their --help.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG_NAME=setup-all
# shellcheck source=deploy/common.sh
. "$REPO/deploy/common.sh"

usage() { sed -n '4,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

BUILD=1
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --check)    CHECK=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          fail "unknown option: $arg (try --help)" ;;
  esac
done

autosd_up() { target true 2>/dev/null; }

step() { printf '\n'; log "step $1 of 6: $2"; }

if [[ "$CHECK" == 1 ]]; then
  bad=0
  # check: a running AutoSD holds its own ports, which "autosd.sh check" reports as busy.
  if autosd_up; then
    log "AutoSD: running, reachable at $AUTOSD_USER@$AUTOSD_HOST:$AUTOSD_PORT"
    "$REPO/deploy/setup-autosd.sh" --check || bad=1
    "$REPO/deploy/deploy-to-autosd.sh" check || bad=1
  else
    "$REPO/autosd/autosd.sh" check || bad=1
    warn "AutoSD is not running: Ankaios and the workloads were not checked"
    bad=1
  fi
  "$REPO/deploy/install-host-deps.sh" --check || bad=1
  [[ "$bad" == 0 ]] && log "everything is set up" || warn "not everything is set up: run $0"
  exit "$bad"
fi

step 1 "packages on this machine"
if [[ "$BUILD" == 1 ]]; then
  "$REPO/deploy/install-host-deps.sh"
else
  "$REPO/deploy/install-host-deps.sh" --run-only
fi

step 2 "the AutoSD image"
"$REPO/autosd/autosd.sh" setup

step 3 "boot AutoSD"
if autosd_up; then
  log "already running, kept as it is"
else
  "$REPO/autosd/autosd.sh" start
fi

step 4 "Ankaios inside AutoSD"
"$REPO/deploy/setup-autosd.sh"

step 5 "build the service images"
if [[ "$BUILD" == 1 ]]; then
  "$REPO/deploy/build-images.sh"
else
  log "skipped (--no-build)"
fi

step 6 "load the images into AutoSD and start the workloads"
"$REPO/deploy/deploy-to-autosd.sh"

printf '\n'
log "done. The system is running and starts by itself whenever AutoSD boots."
log "  fault monitor       http://localhost:7690/ui/"
log "  evidence collector  http://localhost:7700/"
log "  shell in AutoSD     ./autosd/autosd.sh ssh"
log "  workloads           ./deploy/deploy-to-autosd.sh status"
log "board: './autosd/autosd.sh status' prints the address to put into its firmware"
