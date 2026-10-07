#!/usr/bin/env bash
# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# setup-autosd.sh - install and start Eclipse Ankaios on a running AutoSD system.
#
#   ./deploy/setup-autosd.sh           install Ankaios if it is not running yet
#   ./deploy/setup-autosd.sh --check   only report the state, change nothing
#
# The stock AutoSD image has Podman but no Ankaios. This installs the three
# Ankaios programs and starts two of them as services:
#   ank-server   holds the desired state (which workloads should run)
#   ank-agent    named agent_A, starts and stops the containers with Podman
#   ank          command line tool, used by deploy-to-autosd.sh
# Workloads are then started with ./deploy/deploy-to-autosd.sh.
#
# Run once per AutoSD system. If Ankaios already answers, nothing is changed.
# The target needs internet access (GitHub) for the download.
#
# Tunables (environment):
#   AUTOSD_HOST  AUTOSD_PORT  AUTOSD_USER  AUTOSD_PASSWORD   see deploy/common.sh
#   ANKAIOS_VERSION=v1.0.4
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG_NAME=setup
# shellcheck source=deploy/common.sh
. "$REPO/deploy/common.sh"
ANKAIOS_VERSION="${ANKAIOS_VERSION:-v1.0.4}"
AGENT_NAME=agent_A   # the manifest uses "agent: agent_A"

usage() { sed -n '4,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ankaios_running() { target "command -v ank >/dev/null && $ANK get agents 2>/dev/null | grep -q '^$AGENT_NAME '"; }

report() {
  target 'command -v podman >/dev/null' || fail "podman not found on the target: this does not look like an AutoSD image"
  log "target: $(target '. /etc/os-release; echo "$PRETTY_NAME, $(uname -m)"')"
  if ankaios_running; then
    log "Ankaios: $(target 'ank --version') running, agent $AGENT_NAME connected"
    return 0
  fi
  if target 'command -v ank >/dev/null'; then
    warn "Ankaios is installed but not answering (services stopped?)"
  else
    warn "Ankaios is not installed"
  fi
  return 1
}

install() {
  log "installing Ankaios $ANKAIOS_VERSION"
  # Everything below runs on the target. The image has no tar, so the archive
  # is unpacked with python3. Unit files in /etc would be lost at reboot, so
  # Ankaios runs as user units of root with lingering, all under /var.
  target "ANKAIOS_VERSION='$ANKAIOS_VERSION' AGENT_NAME='$AGENT_NAME' T_IOX='$T_IOX' \
          T_STARTUP_MANIFEST='$T_STARTUP_MANIFEST' T_UNIT_DIR='$T_UNIT_DIR' bash -s" <<'REMOTE'
set -euo pipefail
case "$(uname -m)" in
  x86_64)  arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo "unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac
archive="ankaios-linux-$arch.tar.gz"
base="https://github.com/eclipse-ankaios/ankaios/releases/download/$ANKAIOS_VERSION"

cd /var/tmp
curl -sfLO "$base/$archive"
curl -sfLO "$base/$archive.sha512sum.txt"
sha512sum -c "$archive.sha512sum.txt"
python3 -W ignore -c 'import sys, tarfile; tarfile.open(sys.argv[1]).extractall("/usr/local/bin")' "$archive"
chown root:root /usr/local/bin/ank /usr/local/bin/ank-server /usr/local/bin/ank-agent
rm -f "$archive" "$archive.sha512sum.txt"

mkdir -p "$T_UNIT_DIR" "$(dirname "$T_STARTUP_MANIFEST")"
# Startup manifest: what the server starts on its own after a reboot.
# Starts with the broker only; deploy-to-autosd.sh replaces it with the full manifest.
if [ ! -f "$T_STARTUP_MANIFEST" ]; then
  cat > "$T_STARTUP_MANIFEST" <<EOF
apiVersion: v1
workloads:
  mqtt-broker:
    runtime: podman
    agent: $AGENT_NAME
    restartPolicy: ALWAYS
    runtimeConfig: |
      image: docker.io/library/eclipse-mosquitto:2
      commandOptions: ["--net=host"]
      commandArgs: ["/usr/sbin/mosquitto", "-c", "/mosquitto-no-auth.conf"]
EOF
fi

cat > "$T_UNIT_DIR/ank-server.service" <<EOF
[Unit]
Description=Ankaios server
[Service]
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/ank-server --insecure --startup-manifest $T_STARTUP_MANIFEST
Restart=on-failure
[Install]
WantedBy=default.target
EOF

cat > "$T_UNIT_DIR/ank-agent.service" <<EOF
[Unit]
Description=Ankaios agent
After=ank-server.service
Wants=ank-server.service
[Service]
Environment=RUST_LOG=info
ExecStartPre=/usr/bin/mkdir -p $T_IOX
ExecStart=/usr/local/bin/ank-agent --insecure --name $AGENT_NAME
Restart=on-failure
[Install]
WantedBy=default.target
EOF

# Lingering: the root user manager (and with it Ankaios) starts at boot.
loginctl enable-linger root
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
for _ in $(seq 1 20); do [ -S "$XDG_RUNTIME_DIR/bus" ] && break; sleep 0.5; done
systemctl --user daemon-reload
systemctl --user enable --now ank-server ank-agent
REMOTE
}

case "${1:-}" in
  --check)   require_target; report; exit $? ;;
  "")        ;;
  -h|--help) usage; exit 0 ;;
  *)         fail "unknown option: $1 (try --help)" ;;
esac

require_target
if report; then
  log "nothing to do"
  exit 0
fi
[ "$AUTOSD_USER" = root ] || fail "the installation needs AUTOSD_USER=root"
install
for _ in $(seq 1 15); do
  ankaios_running && break
  sleep 2
done
report || fail "Ankaios was installed but the agent did not connect; on the target: journalctl --user -u ank-server -u ank-agent"
log "ready: ./deploy/deploy-to-autosd.sh"
