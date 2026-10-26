#!/usr/bin/env bash
# Shared functions for origin-health-check: config loading, logging, notifications.
# Sourced by the origin-health-check entrypoint.
# shellcheck disable=SC2034

EXIT_USAGE=1
EXIT_PROBLEMS=2
EXIT_CONFIG=3

DEFAULT_REPO_SLUG="SimoneCerruti/origin-health-check"
OHC_CONFIG="${ORIGIN_HEALTH_CHECK_CONFIG:-/etc/origin-health-check/origin-health-check.conf}"
# System paths, overridable so that the test suite never touches the real ones
CRON_FILE="${ORIGIN_HEALTH_CHECK_CRON_FILE:-/etc/cron.d/origin-health-check}"

# Kuma stores messages of any length, but notifications stay readable when short
PUSH_MESSAGE_MAX=900

# Usage: die EXIT_CODE message...
die() {
  local code="$1"
  shift
  echo "Error: $*" >&2
  exit "$code"
}

require_root() {
  # The test suite runs unprivileged against fake openssl, curl and df
  if [[ $EUID -ne 0 && "${ORIGIN_HEALTH_CHECK_ALLOW_NON_ROOT:-}" != "1" ]]; then
    die "$EXIT_USAGE" "this command must be run as root (use sudo)"
  fi
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      die "$EXIT_CONFIG" "required command not found: $cmd"
    fi
  done
}

ohc_version() {
  cat "$OHC_HOME/VERSION" 2>/dev/null || echo "unknown"
}

# Usage: require_integer NAME VALUE [MIN] [MAX]
require_integer() {
  local name="$1" value="$2" min="${3:-0}" max="${4:-}" valid=true
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( 10#$value < min )); then
    valid=false
  elif [[ -n "$max" ]] && (( 10#$value > max )); then
    valid=false
  fi
  if ! $valid; then
    die "$EXIT_CONFIG" "invalid $name '$value': expected an integer >= $min${max:+ and <= $max}"
  fi
}

load_config() {
  # Defaults: every value can be overridden by the config file
  PUSH_URL=""
  ORIGIN_HOST="127.0.0.1"
  ORIGIN_PORT=443
  CONNECT_TIMEOUT=15
  EXPIRY_DAYS=20
  DISK_THRESHOLD=85
  DISK_PATHS=(/)
  DOMAINS=()
  SCHEDULE="15 */6 * * *"
  LOG_DIR="/var/log/origin-health-check"

  if [[ ! -r "$OHC_CONFIG" ]]; then
    die "$EXIT_CONFIG" "config file not found or not readable: $OHC_CONFIG"
  fi
  # shellcheck source=/dev/null
  source "$OHC_CONFIG"

  require_integer ORIGIN_PORT "$ORIGIN_PORT" 1 65535
  require_integer CONNECT_TIMEOUT "$CONNECT_TIMEOUT" 1
  require_integer EXPIRY_DAYS "$EXPIRY_DAYS" 0
  require_integer DISK_THRESHOLD "$DISK_THRESHOLD" 1 100

  # Push URLs copied from Kuma end with ?status=up&msg=OK&ping=: a second
  # status parameter could make Kuma read "up" for a failed check
  if [[ "$PUSH_URL" == *\?* ]]; then
    die "$EXIT_CONFIG" "PUSH_URL must not contain a query string: keep it up to the token ($OHC_CONFIG)"
  fi

  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/origin-health-check.log"
}

# Usage: log LEVEL message...
# Writes to the log file, to the terminal when interactive, and errors to the journal.
log() {
  local level="$1"
  shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] [${LOG_CONTEXT:-main}] $*"

  echo "$line" >> "$LOG_FILE"
  if [[ -t 1 ]]; then
    echo "$line"
  fi
  if [[ "$level" == "ERROR" ]]; then
    logger -t origin-health-check -p user.err "$*" 2>/dev/null || true
  fi
}

# Usage: join_by SEPARATOR ITEM...
join_by() {
  local separator="$1" out="" item
  shift
  for item in "$@"; do
    out+="${out:+$separator}$item"
  done
  printf '%s' "$out"
}

# Sends the result to the Uptime Kuma push monitor.
# Returns 1 when the monitor cannot be reached (Kuma then alerts on the missing heartbeat).
notify() {
  local status="$1" msg="${2:0:$PUSH_MESSAGE_MAX}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log INFO "Dry run, not pushed: $status - $msg"
    return 0
  fi
  if [[ -z "$PUSH_URL" ]]; then
    log WARN "PUSH_URL is empty, result not sent: $status - $msg"
    return 0
  fi
  if ! curl -fsS --max-time 15 --retry 2 --retry-delay 5 --get \
    --data-urlencode "status=$status" --data-urlencode "msg=$msg" \
    "$PUSH_URL" >/dev/null 2>&1; then
    log ERROR "Could not reach the push URL"
    return 1
  fi
  return 0
}
