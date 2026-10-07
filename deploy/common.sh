# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# common.sh - shared by the scripts that talk to the AutoSD target over SSH.
# Sourced, not executed. The caller sets TAG_NAME (prefix of its messages).
#
# The target is any running AutoSD system: the QEMU image on this machine
# (default, reached through the forwarded SSH port) or a device on the network.
#
# Tunables (environment):
#   AUTOSD_HOST=127.0.0.1  AUTOSD_PORT=2222  AUTOSD_USER=root
#   AUTOSD_PASSWORD=password   empty = use your SSH key / agent instead

AUTOSD_HOST="${AUTOSD_HOST:-127.0.0.1}"
AUTOSD_PORT="${AUTOSD_PORT:-2222}"
AUTOSD_USER="${AUTOSD_USER:-root}"
# Development-only root password baked into the upstream AutoSD image.
AUTOSD_PASSWORD="${AUTOSD_PASSWORD-password}"

# Paths on the target. /var is the only location that survives a reboot on
# AutoSD (/etc is transient, /usr is read-only); /root is /var/roothome.
T_IOX=/tmp/iceoryx2                          # iceoryx2 discovery files (tmpfs)
T_STARTUP_MANIFEST=/var/lib/ankaios/state.yaml
T_UNIT_DIR=/root/.config/systemd/user        # Ankaios runs as lingering root user units

# ank on the target; the development setup runs Ankaios without TLS.
ANK="ank --insecure"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$TAG_NAME" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$TAG_NAME" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "$TAG_NAME" "$*" >&2; exit 1; }

ASKPASS=""
cleanup() { [ -z "$ASKPASS" ] || rm -f "$ASKPASS"; }
trap cleanup EXIT

# target <command...>: run a command on the AutoSD system; stdin is passed through.
target() {
  local opts="-p $AUTOSD_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
  if [ -n "$AUTOSD_PASSWORD" ]; then
    # Feed the password through SSH_ASKPASS so no prompt appears.
    if [ -z "$ASKPASS" ]; then
      ASKPASS="$(mktemp)"
      printf '#!/bin/sh\necho "$FEV_AUTOSD_PASSWORD"\n' >"$ASKPASS"
      chmod 700 "$ASKPASS"
    fi
    # shellcheck disable=SC2086
    FEV_AUTOSD_PASSWORD="$AUTOSD_PASSWORD" SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
      ssh $opts -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      "$AUTOSD_USER@$AUTOSD_HOST" "$@"
  else
    # shellcheck disable=SC2086
    ssh $opts "$AUTOSD_USER@$AUTOSD_HOST" "$@"
  fi
}

require_target() {
  command -v ssh >/dev/null 2>&1 || fail "ssh not found"
  target true || fail "cannot reach AutoSD at $AUTOSD_USER@$AUTOSD_HOST:$AUTOSD_PORT (is it running? set AUTOSD_HOST / AUTOSD_PORT)"
}
