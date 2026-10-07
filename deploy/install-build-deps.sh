#!/usr/bin/env bash
# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# install-build-deps.sh - install what build-images.sh needs on this machine.
#
#   ./deploy/install-build-deps.sh           install a container engine if none works yet
#   ./deploy/install-build-deps.sh --check   only report what is missing, install nothing
#
# All services are compiled inside containers, so no Rust toolchain, clang or
# other compiler is installed on the host. The only requirement is a working
# container engine (Podman or Docker). If one already works, nothing is changed.
#
# Supported package managers: apt (Ubuntu/Debian), dnf (Fedora/RHEL),
# pacman (Arch), brew (macOS). sudo is called only for the package install.
#
# Tunables (environment):
#   PLATFORM=linux/amd64   target of the images (the AutoSD image we use is x86_64)
set -euo pipefail

PLATFORM="${PLATFORM:-linux/amd64}"
# Small image the services use as runtime base anyway, so this pull is not wasted.
PROBE_IMAGE="docker.io/library/debian:bookworm-slim"

log()  { printf '\033[1;34m[deps]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deps]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[deps]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Engine that is installed *and* usable by this user ("docker info" fails
# without a running daemon or without permission on its socket).
working_engine() {
  local e
  for e in podman docker; do
    if have "$e" && "$e" info >/dev/null 2>&1; then
      echo "$e"
      return 0
    fi
  done
  return 1
}

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *)             uname -m ;;
  esac
}

# True if the images are built for another CPU than this machine has.
needs_emulation() { [ "$(host_arch)" != "${PLATFORM##*/}" ]; }

report() {
  local e
  if e="$(working_engine)"; then
    log "container engine: $e ($("$e" --version))"
  else
    for e in podman docker; do
      have "$e" && warn "$e is installed but not usable: run '$e info' to see why"
    done
    warn "no working container engine (podman or docker)"
    return 1
  fi
  if needs_emulation; then
    warn "host is $(host_arch), images are built for $PLATFORM: builds run emulated and are slow"
  fi
}

install_podman() {
  local sudo=sudo
  [ "$(id -u)" -eq 0 ] && sudo=""
  if have apt-get; then
    log "installing podman with apt (sudo will ask for your password)"
    $sudo apt-get update
    $sudo apt-get install -y podman uidmap slirp4netns fuse-overlayfs
    if needs_emulation; then $sudo apt-get install -y qemu-user-static; fi
  elif have dnf; then
    log "installing podman with dnf (sudo will ask for your password)"
    $sudo dnf install -y podman
    if needs_emulation; then $sudo dnf install -y qemu-user-static; fi
  elif have pacman; then
    log "installing podman with pacman (sudo will ask for your password)"
    $sudo pacman -S --needed --noconfirm podman slirp4netns fuse-overlayfs
    if needs_emulation; then
      $sudo pacman -S --needed --noconfirm qemu-user-static qemu-user-static-binfmt
    fi
  elif have brew; then
    log "installing podman with brew"
    brew install podman
    # On macOS containers run in a small Linux VM managed by podman.
    if ! podman machine inspect >/dev/null 2>&1; then
      podman machine init
    fi
    podman machine start 2>/dev/null || true
  else
    fail "no supported package manager found (apt, dnf, pacman, brew). Install Podman or Docker by hand, then rerun with --check."
  fi
}

# Rootless Podman on Linux needs a subordinate uid/gid range for the user.
check_rootless() {
  [ "$(uname -s)" = Linux ] || return 0
  [ "$(id -u)" -ne 0 ] || return 0
  local user
  user="$(id -un)"
  if ! grep -q "^$user:" /etc/subuid 2>/dev/null || ! grep -q "^$user:" /etc/subgid 2>/dev/null; then
    warn "no subordinate uid/gid range for '$user'; rootless builds will fail. Fix with:"
    warn "  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user"
    warn "  podman system migrate"
    return 1
  fi
}

# Pull and run one small image for the target platform: proves registry
# access, the storage driver and (on a foreign CPU) the emulation.
probe() {
  local e="$1" out
  log "test run: $e run --platform $PLATFORM $PROBE_IMAGE"
  if out="$("$e" run --rm --platform "$PLATFORM" "$PROBE_IMAGE" uname -m 2>&1)"; then
    log "test run ok (container CPU: $(printf '%s\n' "$out" | tail -n 1))"
  else
    printf '%s\n' "$out" >&2
    fail "test run failed, see the output above"
  fi
}

case "${1:-}" in
  --check)
    report || exit 1
    check_rootless || exit 1
    exit 0 ;;
  "") ;;
  -h|--help) sed -n '4,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) fail "unknown option: $1 (try --help)" ;;
esac

if engine="$(working_engine)"; then
  log "already installed, nothing to do"
else
  install_podman
  engine="$(working_engine)" || fail "podman was installed but 'podman info' still fails; run it to see why"
fi
report
check_rootless || exit 1
probe "$engine"
log "ready: ./deploy/build-images.sh"
