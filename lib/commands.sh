#!/usr/bin/env bash
# Commands: run, status, schedule, self-update.
# shellcheck disable=SC2034,SC2154

cmd_run() {
  DRY_RUN=0
  local expiry_override="" cli_domains=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --expiry-days)
        if [[ -z "${2:-}" ]]; then
          die "$EXIT_USAGE" "--expiry-days requires a value"
        fi
        expiry_override="$2"
        shift 2
        ;;
      -*)
        die "$EXIT_USAGE" "usage: origin-health-check run [--dry-run] [--expiry-days N] [domain...]"
        ;;
      *)
        cli_domains+=("$1")
        shift
        ;;
    esac
  done

  require_root
  load_config
  require_commands openssl curl timeout df date

  if [[ -n "$expiry_override" ]]; then
    require_integer --expiry-days "$expiry_override" 0
    EXPIRY_DAYS="$expiry_override"
  fi
  if [[ ${#cli_domains[@]} -gt 0 ]]; then
    DOMAINS=("${cli_domains[@]}")
  fi

  LOG_CONTEXT="run"
  if [[ "$DRY_RUN" == "1" ]]; then
    LOG_CONTEXT="dry-run"
  fi

  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    log ERROR "No domains configured in $OHC_CONFIG"
    notify down "origin-health-check: no domains configured" || true
    exit "$EXIT_CONFIG"
  fi

  PROBLEMS=()
  DISK_SUMMARY=()
  OK_COUNT=0
  MIN_DAYS=99999

  log INFO "Checking ${#DOMAINS[@]} domain(s) on $ORIGIN_HOST:$ORIGIN_PORT (origin-health-check $(ohc_version))"

  local domain
  for domain in "${DOMAINS[@]}"; do
    check_certificate "$domain"
  done
  check_disk

  local msg
  if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
    msg="${#PROBLEMS[@]} problem(s): $(join_by "; " "${PROBLEMS[@]}")"
    log ERROR "Result: $msg"
    notify down "$msg" || true
    exit "$EXIT_PROBLEMS"
  fi

  msg="$OK_COUNT certs OK (min ${MIN_DAYS}d left), disk $(join_by ", " "${DISK_SUMMARY[@]}")"
  log INFO "Result: $msg"
  notify up "$msg" || true
}

cmd_status() {
  require_root
  load_config

  echo "== Version"
  echo "  $(ohc_version)"

  echo
  echo "== Schedule"
  schedule_status

  echo
  echo "== Configuration ($OHC_CONFIG)"
  echo "  Origin:     $ORIGIN_HOST:$ORIGIN_PORT"
  echo "  Domains:    ${#DOMAINS[@]}"
  echo "  Expiry:     alert below $EXPIRY_DAYS days"
  echo "  Disk:       alert above $DISK_THRESHOLD% on $(join_by ", " "${DISK_PATHS[@]}")"
  if [[ -n "$PUSH_URL" ]]; then
    echo "  Push:       configured"
  else
    echo "  Push:       NOT configured (results are only logged)"
  fi

  echo
  echo "== Recent results ($LOG_FILE)"
  if [[ -f "$LOG_FILE" ]]; then
    { grep -F '] Result: ' "$LOG_FILE" || true; } | tail -n 10
  else
    echo "  No log yet"
  fi
}

schedule_status() {
  if [[ -f "$CRON_FILE" ]]; then
    grep 'origin-health-check run' "$CRON_FILE" | sed 's/^/  /' || true
  else
    echo "  Disabled"
  fi
}

cmd_schedule() {
  require_root
  load_config

  case "${1:-status}" in
    enable)
      if [[ -z "$SCHEDULE" ]]; then
        die "$EXIT_CONFIG" "SCHEDULE is empty in $OHC_CONFIG"
      fi
      if [[ -z "$PUSH_URL" ]]; then
        echo "Warning: PUSH_URL is empty, scheduled results will only be logged" >&2
      fi

      {
        echo "# Managed by origin-health-check: do not edit."
        echo "# Change SCHEDULE in $OHC_CONFIG, then run 'origin-health-check schedule enable'."
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "$SCHEDULE root /usr/local/bin/origin-health-check run >> $LOG_DIR/cron.log 2>&1"
      } > "$CRON_FILE"
      chmod 600 "$CRON_FILE"

      echo "Schedule enabled:"
      schedule_status
      ;;
    disable)
      rm -f "$CRON_FILE"
      echo "Schedule disabled"
      ;;
    status)
      schedule_status
      ;;
    *)
      die "$EXIT_USAGE" "usage: origin-health-check schedule enable|disable|status"
      ;;
  esac
}

cmd_self_update() {
  require_root
  require_commands curl

  local installer_args=(--no-deps)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version|--ref)
        if [[ -z "${2:-}" ]]; then
          die "$EXIT_USAGE" "$1 requires a value"
        fi
        installer_args+=("$1" "$2")
        shift 2
        ;;
      *)
        die "$EXIT_USAGE" "usage: origin-health-check self-update [--version X.Y.Z | --ref BRANCH]"
        ;;
    esac
  done

  local slug="${ORIGIN_HEALTH_CHECK_REPO:-$DEFAULT_REPO_SLUG}"
  curl -fsSL "https://raw.githubusercontent.com/$slug/main/install.sh" \
    | bash -s -- "${installer_args[@]}"
}
