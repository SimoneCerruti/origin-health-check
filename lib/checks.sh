#!/usr/bin/env bash
# Checks: TLS certificate served by the origin for each domain, disk usage.
# Results are collected in PROBLEMS, OK_COUNT, MIN_DAYS and DISK_SUMMARY (set by cmd_run).
# shellcheck disable=SC2034,SC2154

# Connects to ORIGIN_HOST:ORIGIN_PORT with SNI, bypassing any CDN in front of the origin.
check_certificate() {
  local domain="$1" output pem subject verify end_date end_epoch days_left

  output=$(timeout "$CONNECT_TIMEOUT" openssl s_client \
    -connect "$ORIGIN_HOST:$ORIGIN_PORT" -servername "$domain" -verify_hostname "$domain" \
    </dev/null 2>&1) || true

  # A strict SNI policy (e.g. Traefik sniStrict) rejects the handshake when no certificate
  # matches, so no PEM block appears in the output
  pem=$(openssl x509 2>/dev/null <<< "$output") || pem=""
  if [[ -z "$pem" ]]; then
    add_problem "$domain: no certificate (handshake failed)"
    return 0
  fi

  subject=$(openssl x509 -noout -subject <<< "$pem" 2>/dev/null) || subject=""
  if [[ "$subject" == *"TRAEFIK DEFAULT CERT"* ]]; then
    add_problem "$domain: Traefik default certificate"
    return 0
  fi

  # Chain checked against the system CA bundle, name checked by -verify_hostname
  verify=$(sed -n 's/^ *Verify return code: //p' <<< "$output" | head -n 1)
  if [[ "$verify" != "0 (ok)" ]]; then
    add_problem "$domain: invalid certificate (${verify:-no verification result})"
    return 0
  fi

  end_date=$(openssl x509 -noout -enddate <<< "$pem" 2>/dev/null | cut -d= -f2)
  if ! end_epoch=$(date -d "$end_date" +%s 2>/dev/null); then
    add_problem "$domain: unreadable expiry date '$end_date'"
    return 0
  fi
  days_left=$(( (end_epoch - $(date +%s)) / 86400 ))

  if (( days_left < MIN_DAYS )); then
    MIN_DAYS=$days_left
  fi
  if (( days_left < EXPIRY_DAYS )); then
    add_problem "$domain: certificate expires in ${days_left}d"
    return 0
  fi

  OK_COUNT=$((OK_COUNT + 1))
  log INFO "OK $domain: ${days_left}d left"
  return 0
}

check_disk() {
  local path usage
  for path in "${DISK_PATHS[@]}"; do
    usage=$(df --output=pcent "$path" 2>/dev/null | tail -n 1 | tr -dc '0-9') || usage=""
    if [[ -z "$usage" ]]; then
      add_problem "disk $path: usage unreadable"
      continue
    fi
    DISK_SUMMARY+=("$path ${usage}%")
    if (( usage > DISK_THRESHOLD )); then
      add_problem "disk $path: ${usage}% used (threshold ${DISK_THRESHOLD}%)"
    else
      log INFO "OK disk $path: ${usage}% used"
    fi
  done
  return 0
}

add_problem() {
  PROBLEMS+=("$1")
  log ERROR "$1"
}
