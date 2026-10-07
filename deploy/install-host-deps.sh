#!/usr/bin/env bash
# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# install-host-deps.sh - install every package the scripts of this repository need on this machine.
#
#   ./deploy/install-host-deps.sh             install what is missing
#   ./deploy/install-host-deps.sh --run-only  only what running AutoSD and deploying to it needs
#   ./deploy/install-host-deps.sh --check     only report what is missing, install nothing
#
# Three groups:
#   run     autosd/autosd.sh, deploy/setup-autosd.sh, deploy/deploy-to-autosd.sh:
#           QEMU, OVMF firmware, OpenSSH client, Python 3, iproute2, curl, xz, tar, awk, ...
#   tools   used by hand in the documents: jq and column (opensovd-gateway-dfm/fault_host.sh),
#           mosquitto_pub / mosquitto_sub (sending a test reading without the board)
#   build   deploy/build-images.sh: a container engine. Installed and tested by
#           ./deploy/install-build-deps.sh, which this script calls.
#
# If nothing is missing, nothing is changed and no password is asked.
# Supported package managers: apt (Ubuntu/Debian), dnf (Fedora).
# The AutoSD image itself is not a package: ./autosd/autosd.sh setup downloads it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m[host-deps]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[host-deps]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[host-deps]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '4,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

have() { command -v "$1" >/dev/null 2>&1; }

# Commands the scripts call, per group. OVMF is a file, checked separately.
RUN_CMDS="qemu-system-x86_64 ssh python3 ss ip curl xz sha256sum tar awk sed grep ps df timeout"
TOOL_CMDS="jq column mosquitto_pub mosquitto_sub"

# Packages that provide them. Whole groups are handed to the package manager,
# which skips what is installed.
APT_RUN="qemu-system-x86 ovmf openssh-client python3 iproute2 curl ca-certificates xz-utils tar gawk sed grep procps coreutils"
APT_TOOLS="jq bsdextrautils mosquitto-clients"
DNF_RUN="qemu-system-x86-core edk2-ovmf openssh-clients python3 iproute curl ca-certificates xz tar gawk sed grep procps-ng coreutils"
DNF_TOOLS="jq util-linux mosquitto"

have_ovmf() {
  local d
  for d in /usr/share/OVMF /usr/share/edk2/ovmf; do
    compgen -G "$d/OVMF_CODE*.fd" >/dev/null && return 0
  done
  return 1
}

missing() {   # missing <commands...>: prints the ones not installed
  local c out=""
  for c in "$@"; do have "$c" || out+="$c "; done
  echo "$out"
}

missing_run() {
  local out
  # shellcheck disable=SC2086
  out="$(missing $RUN_CMDS)"
  have_ovmf || out+="OVMF "
  echo "$out"
}

# shellcheck disable=SC2086
missing_tools() { missing $TOOL_CMDS; }

# KVM makes AutoSD boot in seconds instead of minutes. True if usable now.
kvm_usable() { [[ -r /dev/kvm && -w /dev/kvm ]]; }

kvm_report() {
  if kvm_usable; then
    log "KVM: usable"
  elif [[ -e /dev/kvm ]]; then
    warn "KVM: /dev/kvm exists but you may not use it; AutoSD would run in slow software emulation"
    return 1
  else
    warn "KVM: no /dev/kvm; AutoSD will run in slow software emulation. Enable virtualization (VT-x / AMD-V) in the BIOS; inside a VM, enable nested virtualization"
  fi
}

# /dev/kvm is usable by the members of its group (kvm): add the user to it.
kvm_fix() {
  kvm_usable && return 0
  [[ -e /dev/kvm ]] || { kvm_report || true; return 0; }
  local user group
  user="$(id -un)"
  group="$(stat -c %G /dev/kvm)"
  if ! getent group "$group" >/dev/null || [[ "$group" == root || "$group" == nogroup ]]; then
    warn "KVM: /dev/kvm is not usable by you and belongs to no group you could join ($group); AutoSD will run in slow software emulation"
    return 0
  fi
  if getent group "$group" | cut -d: -f4 | tr ',' '\n' | grep -qx "$user"; then
    warn "KVM: you are in the group $group, but this login session is older than that: log out and in again"
    return 0
  fi
  log "adding $user to the group $group, for /dev/kvm (sudo may ask for your password)"
  $SUDO usermod -aG "$group" "$user"
  warn "KVM: log out and in again to use it; until then AutoSD runs in slow software emulation"
}

install_packages() {   # install_packages <groups...>   groups: RUN TOOLS
  local g apt="" dnf=""
  for g in "$@"; do
    local a="APT_$g" d="DNF_$g"
    apt+="${!a} "; dnf+="${!d} "
  done
  # shellcheck disable=SC2086
  if have apt-get; then
    log "installing with apt (sudo may ask for your password)"
    $SUDO apt-get update
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $apt
  elif have dnf; then
    log "installing with dnf (sudo may ask for your password)"
    $SUDO dnf install -y $dnf
  else
    fail "no supported package manager found (apt, dnf): install the missing programs by hand"
  fi
}

RUN_ONLY=0
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --run-only) RUN_ONLY=1 ;;
    --check)    CHECK=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          fail "unknown option: $arg (try --help)" ;;
  esac
done

SUDO=sudo
[[ "$(id -u)" -eq 0 ]] && SUDO=""

m_run="$(missing_run)"
m_tools=""
[[ "$RUN_ONLY" == 1 ]] || m_tools="$(missing_tools)"

if [[ "$CHECK" == 1 ]]; then
  bad=0
  [[ -z "$m_run" ]]   && log "run: complete"   || { warn "run: missing $m_run"; bad=1; }
  if [[ "$RUN_ONLY" == 0 ]]; then
    [[ -z "$m_tools" ]] && log "tools: complete" || { warn "tools: missing $m_tools"; bad=1; }
    "$REPO/deploy/install-build-deps.sh" --check || bad=1
  fi
  kvm_report || bad=1
  [[ "$bad" == 0 ]] || warn "to install what is missing: $0"
  exit "$bad"
fi

groups=()
[[ -z "$m_run" ]]   || groups+=(RUN)
[[ -z "$m_tools" ]] || groups+=(TOOLS)
if [[ ${#groups[@]} -gt 0 ]]; then
  [[ -z "$SUDO" ]] || have sudo || fail "sudo not found: run this as root, or install by hand: $m_run$m_tools"
  log "missing: $m_run$m_tools"
  install_packages "${groups[@]}"
  m_run="$(missing_run)"
  [[ "$RUN_ONLY" == 1 ]] || m_tools="$(missing_tools)"
  [[ -z "$m_run$m_tools" ]] || fail "still missing after the install: $m_run$m_tools"
  log "installed"
else
  log "programs: nothing to install"
fi
kvm_fix

if [[ "$RUN_ONLY" == 0 ]]; then
  "$REPO/deploy/install-build-deps.sh"
fi
