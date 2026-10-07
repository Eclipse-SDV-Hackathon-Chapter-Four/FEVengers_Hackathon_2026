#!/usr/bin/env bash
# Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
#
# build-images.sh - build the container images of every service that runs on AutoSD.
#
#   ./deploy/build-images.sh               build the services that get deployed
#   ./deploy/build-images.sh guardian dfm  build only these (name or unique part of it)
#   ./deploy/build-images.sh --all         also build the services marked "optional"
#   ./deploy/build-images.sh --list        show the services and their image names
#   ./deploy/build-images.sh --no-save     build, but do not write the image archives
#
# Each image is tagged localhost/<name>:dev and saved as build/images/<name>.tar,
# ready to be copied to the AutoSD target and loaded with "podman load".
# A failed build does not stop the others; the exit code is non-zero if any failed.
#
# Needs Podman or Docker: ./deploy/install-build-deps.sh
#
# Tunables (environment):
#   ENGINE=podman|docker   container engine (default: podman if usable, else docker)
#   TAG=dev                image tag
#   PLATFORM=linux/amd64   target platform (the AutoSD image we use is x86_64)
#   OUT_DIR=build/images   where the image archives go
set -euo pipefail

# ---------------------------------------------------------------- services
# One line per service: <image name>|<build context, relative to the repo root>
# The context must contain a Containerfile. To add a service, add a line.
# A third field "optional" marks a service that is not deployed yet: it is
# built only when it is named on the command line, or with --all.
SERVICES="
vss-uprotocol-publisher|vss-uprotocol-publisher
battery-thermal-guardian|battery-thermal-guardian
dfm|dfm-container
opensovd-gateway-dfm|opensovd-gateway-dfm
fault-campaign-runner|fault-campaign-runner|optional
evidence-collector|evidence-collector
"
# The MQTT broker is not built: it is the stock docker.io/library/eclipse-mosquitto:2.
# -------------------------------------------------------------------------

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${TAG:-dev}"
PLATFORM="${PLATFORM:-linux/amd64}"
OUT_DIR="${OUT_DIR:-$REPO/build/images}"
# Warn below this much free space; the Rust build stages need several GB.
MIN_FREE_GB=15

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '4,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Prints every "name|context[|optional]" line of the table (blank and # lines skipped).
services() { printf '%s\n' "$SERVICES" | grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#'; }

# The same as "name|context" lines; without an argument the optional ones are left out.
selectable() {   # selectable [all]
  services | awk -F'|' -v all="${1:-}" 'all == "all" || $3 != "optional" {print $1 "|" $2}'
}

image_of() { echo "localhost/$1:$TAG"; }

# resolve <name> -> "name|context"; an exact name wins, otherwise the
# argument must be part of exactly one name.
resolve() {
  local want="$1" exact="" partial="" hits=0 name ctx
  while IFS='|' read -r name ctx; do
    [ "$name" = "$want" ] && exact="$name|$ctx"
    case "$name" in
      *"$want"*) partial="$name|$ctx"; hits=$((hits + 1)) ;;
    esac
  done <<EOF
$(selectable all)
EOF
  if [ -n "$exact" ]; then echo "$exact"; return 0; fi
  [ "$hits" -eq 1 ] && { echo "$partial"; return 0; }
  [ "$hits" -eq 0 ] && fail "unknown service '$want' (see --list)"
  fail "'$want' matches more than one service (see --list)"
}

pick_engine() {
  local e
  if [ -n "${ENGINE:-}" ]; then
    command -v "$ENGINE" >/dev/null 2>&1 || fail "ENGINE=$ENGINE not found"
    "$ENGINE" info >/dev/null 2>&1 || fail "'$ENGINE info' fails: the engine is installed but not usable"
    return 0
  fi
  for e in podman docker; do
    if command -v "$e" >/dev/null 2>&1 && "$e" info >/dev/null 2>&1; then
      ENGINE="$e"
      return 0
    fi
  done
  fail "no working container engine (podman or docker). Run ./deploy/install-build-deps.sh"
}

preflight() {
  local name ctx arch free_kb
  while IFS='|' read -r name ctx; do
    [ -f "$REPO/$ctx/Containerfile" ] || fail "$name: no Containerfile in $ctx/"
  done <<EOF
$SELECTED
EOF

  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)             arch="$(uname -m)" ;;
  esac
  if [ "$arch" != "${PLATFORM##*/}" ]; then
    warn "host is $arch, building for $PLATFORM: the build runs emulated and is slow"
  fi

  free_kb="$(df -Pk "$REPO" | awk 'NR==2 {print $4}')"
  if [ "$free_kb" -lt $((MIN_FREE_GB * 1024 * 1024)) ]; then
    warn "only $((free_kb / 1024 / 1024)) GB free on this disk; the builds may run out of space"
  fi
}

# ---------------------------------------------------------------- arguments
SAVE=1
ALL=""
WANTED=""
for arg in "$@"; do
  case "$arg" in
    --list)
      printf '%-28s %-44s %-28s %s\n' SERVICE IMAGE CONTEXT ""
      services | while IFS='|' read -r name ctx opt; do
        printf '%-28s %-44s %-28s %s\n' "$name" "$(image_of "$name")" "$ctx/" "${opt:+optional: only by name or with --all}"
      done
      exit 0 ;;
    --all)     ALL=all ;;
    --no-save) SAVE=0 ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "unknown option: $arg (try --help)" ;;
    *)  WANTED="$WANTED $arg" ;;
  esac
done

if [ -z "$WANTED" ]; then
  SELECTED="$(selectable $ALL)"
else
  SELECTED=""
  for arg in $WANTED; do
    line="$(resolve "$arg")" || exit 1
    # Naming a service twice builds it once.
    case "
$SELECTED
" in
      *"
$line
"*) ;;
      *) SELECTED="${SELECTED:+$SELECTED
}$line" ;;
    esac
  done
fi

# ---------------------------------------------------------------- build
pick_engine
preflight
[ "$SAVE" -eq 1 ] && mkdir -p "$OUT_DIR"
log "engine: $ENGINE, platform: $PLATFORM, tag: $TAG"

OK=""
FAILED=""
while IFS='|' read -r name ctx; do
  image="$(image_of "$name")"
  started=$SECONDS
  log "building $image from $ctx/"
  # stdin from /dev/null: the engine must not swallow the rest of the service list.
  if "$ENGINE" build --platform "$PLATFORM" -t "$image" \
       -f "$REPO/$ctx/Containerfile" "$REPO/$ctx" </dev/null; then
    if [ "$SAVE" -eq 1 ]; then
      # Write to a temporary name first: an interrupted save must not leave
      # a truncated archive, and podman refuses to overwrite an existing one.
      rm -f "$OUT_DIR/$name.tar.part"
      if "$ENGINE" save -o "$OUT_DIR/$name.tar.part" "$image" </dev/null; then
        mv -f "$OUT_DIR/$name.tar.part" "$OUT_DIR/$name.tar"
      else
        rm -f "$OUT_DIR/$name.tar.part"
        warn "$name: built, but saving the archive failed"
        FAILED="$FAILED $name"
        continue
      fi
    fi
    log "$name done in $((SECONDS - started)) s"
    OK="$OK $name"
  else
    warn "$name: build failed after $((SECONDS - started)) s"
    FAILED="$FAILED $name"
  fi
done <<EOF
$SELECTED
EOF

# ---------------------------------------------------------------- summary
echo
for name in $OK; do
  if [ "$SAVE" -eq 1 ]; then
    size="$(du -h "$OUT_DIR/$name.tar" | cut -f1)"
    log "ok      $(image_of "$name")  ->  ${OUT_DIR#"$REPO"/}/$name.tar ($size)"
  else
    log "ok      $(image_of "$name")"
  fi
done
for name in $FAILED; do
  warn "FAILED  $name"
done
[ -z "$FAILED" ] || exit 1
