#!/usr/bin/env bash
# origin-health-check installer: installs or updates origin-health-check on a Debian/Ubuntu host.
# The configuration in /etc/origin-health-check is never overwritten.
#
#   curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/origin-health-check/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/origin-health-check/main/install.sh | sudo bash -s -- --version 1.0.0
set -Eeuo pipefail

REPO_SLUG="${ORIGIN_HEALTH_CHECK_REPO:-SimoneCerruti/origin-health-check}"
INSTALL_DIR="${ORIGIN_HEALTH_CHECK_HOME:-/opt/origin-health-check}"
CONF_DIR="/etc/origin-health-check"
CONF_FILE="$CONF_DIR/origin-health-check.conf"
LOG_DIR="/var/log/origin-health-check"
BIN_LINK="/usr/local/bin/origin-health-check"
CRON_FILE="/etc/cron.d/origin-health-check"
# Manual setup that preceded this tool: a single script and a config file in /etc
LEGACY_SCRIPT="/usr/local/bin/origin-health-check.sh"
LEGACY_CONFIG="/etc/origin-health-check.conf"
DEPENDENCIES=(openssl curl ca-certificates coreutils cron logrotate)
REQUIRED_FILES=(
  origin-health-check
  lib/common.sh
  lib/checks.sh
  lib/commands.sh
  templates/logrotate
  origin-health-check.conf.example
  VERSION
)

info() { echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install.sh [--version X.Y.Z | --ref BRANCH] [--no-deps]

  --version X.Y.Z   Install a tagged release (default: latest release)
  --ref BRANCH      Install from a branch instead of a release (development only)
  --no-deps         Do not install system packages
EOF
}

version="latest"
ref=""
install_deps=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ -n "${2:-}" ]] || die "--version requires a value"
      version="${2#v}"
      shift 2
      ;;
    --ref)
      [[ -n "${2:-}" ]] || die "--ref requires a value"
      ref="$2"
      shift 2
      ;;
    --no-deps)
      install_deps=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (pipe into 'sudo bash')"

# --- Dependencies ---
if $install_deps; then
  command -v apt-get >/dev/null 2>&1 \
    || die "apt-get not found: only Debian/Ubuntu are supported (use --no-deps to skip)"
  info "Installing dependencies: ${DEPENDENCIES[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${DEPENDENCIES[@]}" >/dev/null
fi
for cmd in curl tar; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

# --- Resolve what to download ---
if [[ -n "$ref" ]]; then
  label="$ref"
  archive_url="https://github.com/$REPO_SLUG/archive/refs/heads/$ref.tar.gz"
else
  if [[ "$version" == "latest" ]]; then
    tag=$(curl -fsSL "https://api.github.com/repos/$REPO_SLUG/releases/latest" \
      | grep -m1 '"tag_name"' \
      | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/') || true
    [[ -n "${tag:-}" ]] || die "could not resolve the latest release of $REPO_SLUG (use --version or --ref)"
  else
    tag="v$version"
  fi
  label="$tag"
  archive_url="https://github.com/$REPO_SLUG/archive/refs/tags/$tag.tar.gz"
fi

# --- Download and validate ---
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

info "Downloading $REPO_SLUG@$label"
curl -fsSL "$archive_url" | tar -xz -C "$tmp_dir" --strip-components=1 \
  || die "download failed: $archive_url"

for file in "${REQUIRED_FILES[@]}"; do
  [[ -f "$tmp_dir/$file" ]] || die "unexpected archive layout, missing: $file"
done
# Libraries added later are checked from the entrypoint, so older releases still install
while read -r file; do
  [[ -f "$tmp_dir/$file" ]] || die "unexpected archive layout, missing: $file"
done < <(grep -oE 'lib/[a-z_-]+\.sh' "$tmp_dir/origin-health-check" | sort -u)
for script in "$tmp_dir/origin-health-check" "$tmp_dir"/lib/*.sh; do
  bash -n "$script" || die "syntax check failed: ${script#"$tmp_dir"/}"
done

# --- Install code (atomic swap, previous version kept in $INSTALL_DIR.old) ---
staging_dir="$INSTALL_DIR.new"
rm -rf "$staging_dir"
mkdir -p "$staging_dir"
cp -r "$tmp_dir/origin-health-check" "$tmp_dir/lib" "$tmp_dir/templates" \
  "$tmp_dir/origin-health-check.conf.example" "$tmp_dir/VERSION" "$staging_dir/"
chmod -R go-rwx "$staging_dir"
chmod 700 "$staging_dir/origin-health-check"

if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR.old"
  mv "$INSTALL_DIR" "$INSTALL_DIR.old"
fi
mv "$staging_dir" "$INSTALL_DIR"
ln -sfn "$INSTALL_DIR/origin-health-check" "$BIN_LINK"

# --- Config, logs, logrotate (config is never overwritten) ---
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
new_config=false
if [[ ! -f "$CONF_FILE" ]]; then
  if [[ -f "$LEGACY_CONFIG" ]]; then
    # Same variable names as the manual script: the old file works as is
    install -m 600 "$LEGACY_CONFIG" "$CONF_FILE"
    rm -f "$LEGACY_CONFIG"
    info "Configuration migrated from $LEGACY_CONFIG"
  else
    install -m 600 "$INSTALL_DIR/origin-health-check.conf.example" "$CONF_FILE"
    new_config=true
  fi
fi

mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"
install -m 644 "$INSTALL_DIR/templates/logrotate" /etc/logrotate.d/origin-health-check

# Leftover of the manual setup: a cron file calling it is regenerated below
rm -f "$LEGACY_SCRIPT"

info "origin-health-check $(cat "$INSTALL_DIR/VERSION") installed in $INSTALL_DIR"

if $new_config; then
  cat <<EOF

Next steps:
  1. Create an Uptime Kuma Push monitor (heartbeat: schedule interval + 1h, e.g. 25200 for 6h)
  2. Edit the configuration:   sudo nano $CONF_FILE
     PUSH_URL up to the token (no query string), DOMAINS, thresholds
  3. Test without pushing:     sudo origin-health-check run --dry-run
  4. Test with push:           sudo origin-health-check run
  5. Enable the schedule:      sudo origin-health-check schedule enable
EOF
else
  info "Existing configuration kept: $CONF_FILE"
  info "Compare it with $INSTALL_DIR/origin-health-check.conf.example for new options"
  if [[ -f "$CRON_FILE" ]]; then
    if "$BIN_LINK" schedule enable >/dev/null; then
      info "Schedule refreshed"
    fi
  fi
fi
