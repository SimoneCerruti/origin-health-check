#!/usr/bin/env bash
# Smoke tests for origin-health-check, with fake openssl s_client, curl, df and logger.
# Certificates are real (generated with openssl); only the TLS connection is faked.
# Everything happens in a temporary directory: no real system path is touched.
#
#   tests/run.sh            run all tests
#   tests/run.sh NAME...    run only the named tests (e.g. test_run_all_ok)
set -Euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OHC="$REPO_DIR/origin-health-check"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

BIN="$TEST_TMP/bin"
ROOT="$TEST_TMP/root"       # recreated for every test
OUT="$TEST_TMP/output"      # stdout and stderr of the last origin-health-check call
FAILURES="$TEST_TMP/failures"
STATUS=0                    # exit code of the last origin-health-check call

REAL_OPENSSL="$(command -v openssl)" || { echo "openssl is required to run the tests" >&2; exit 1; }

# Environment seen by origin-health-check and by the fakes
export TZ=UTC
export PATH="$BIN:$PATH"
export FAKE_ROOT="$ROOT"
export REAL_OPENSSL
export ORIGIN_HEALTH_CHECK_CONFIG="$ROOT/origin-health-check.conf"
export ORIGIN_HEALTH_CHECK_CRON_FILE="$ROOT/cron.d/origin-health-check"
export ORIGIN_HEALTH_CHECK_ALLOW_NON_ROOT=1

# --- Fake executables ----------------------------------------------------------

mkdir -p "$BIN"

# openssl: "s_client" answers with $FAKE_ROOT/certs/<servername>.pem when it exists, with the
# verify result in <servername>.verify (default "0 (ok)"); without a certificate it fails like
# a handshake rejected by sniStrict. Every other subcommand runs the real openssl.
cat > "$BIN/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" != "s_client" ]]; then
  exec "$REAL_OPENSSL" "$@"
fi
echo "s_client $*" >> "$FAKE_ROOT/openssl-calls"
servername=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-servername" ]]; then
    servername="$2"
  fi
  shift
done
cert="$FAKE_ROOT/certs/$servername.pem"
if [[ ! -f "$cert" ]]; then
  echo "40E7A9D2:error:0A000410:SSL routines:ssl3_read_bytes:ssl/tls alert handshake failure"
  exit 1
fi
verify="0 (ok)"
if [[ -f "$FAKE_ROOT/certs/$servername.verify" ]]; then
  verify="$(cat "$FAKE_ROOT/certs/$servername.verify")"
fi
echo "CONNECTED(00000003)"
echo "---"
echo "Server certificate"
cat "$cert"
echo "---"
echo "Verify return code: $verify"
EOF

# curl: records every call in $FAKE_ROOT/curl-calls; FAKE_CURL_FAIL=1 makes it fail
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ROOT/curl-calls"
if [[ -n "${FAKE_CURL_FAIL:-}" ]]; then
  echo "curl: (7) Failed to connect" >&2
  exit 7
fi
echo '{"ok":true}'
EOF

# df: usage FAKE_DISK_USAGE (default 42) for every path; FAKE_DF_FAIL=1 makes it fail
cat > "$BIN/df" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_DF_FAIL:-}" ]]; then
  echo "df: ${*: -1}: No such file or directory" >&2
  exit 1
fi
echo "Use%"
echo " ${FAKE_DISK_USAGE:-42}%"
EOF

# logger: keep test errors out of the real journal
cat > "$BIN/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$BIN"/*

# --- Helpers -------------------------------------------------------------------

setup() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT/certs" "$ROOT/cron.d"
  : > "$ROOT/curl-calls"
  : > "$ROOT/openssl-calls"

  cat > "$ORIGIN_HEALTH_CHECK_CONFIG" <<EOF
PUSH_URL="http://127.0.0.1:3001/api/push/testtoken"
LOG_DIR="$ROOT/log"
DOMAINS=(
  example.com
  www.example.com
)
EOF
  cert example.com 60
  cert www.example.com 90
}

# Usage: cert DOMAIN DAYS [SUBJECT_CN]: real self-signed certificate valid for DAYS days.
# Issued "now", so the tool may report DAYS or DAYS-1 days left: assertions accept both.
cert() {
  local domain="$1" days="$2" cn="${3:-$1}"
  "$REAL_OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout /dev/null -subj "/CN=$cn" -days "$days" \
    -out "$ROOT/certs/$domain.pem" >/dev/null 2>&1
}

# Appends lines to the test config
config() {
  printf '%s\n' "$@" >> "$ORIGIN_HEALTH_CHECK_CONFIG"
}

ohc() {
  STATUS=0
  bash "$OHC" "$@" > "$OUT" 2>&1 || STATUS=$?
}

fail() {
  echo "    $*" >> "$FAILURES"
}

assert_status() {
  if [[ "$STATUS" != "$1" ]]; then
    fail "expected exit code $1, got $STATUS; output: $(head -c 400 "$OUT")"
  fi
}

# Usage: assert_contains FILE TEXT (fixed string)
assert_contains() {
  if ! grep -qF -- "$2" "$1" 2>/dev/null; then
    fail "$(basename "$1") does not contain: $2"
  fi
}

# Usage: assert_matches FILE REGEX (extended regex)
assert_matches() {
  if ! grep -qE -- "$2" "$1" 2>/dev/null; then
    fail "$(basename "$1") does not match: $2"
  fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    fail "$(basename "$1") unexpectedly contains: $2"
  fi
}

log_file() {
  echo "$ROOT/log/origin-health-check.log"
}

curl_calls() {
  echo "$ROOT/curl-calls"
}

# --- Tests: run ----------------------------------------------------------------

test_run_all_ok() {
  ohc run
  assert_status 0
  assert_contains "$(curl_calls)" "--get --data-urlencode status=up"
  assert_matches "$(curl_calls)" "msg=2 certs OK \\(min (59|60)d left\\), disk / 42%"
  assert_contains "$(curl_calls)" "http://127.0.0.1:3001/api/push/testtoken"
  assert_contains "$ROOT/openssl-calls" "-connect 127.0.0.1:443 -servername example.com -verify_hostname example.com"
  assert_matches "$(log_file)" "\\[INFO\\] \\[run\\] OK example.com: (59|60)d left"
  assert_contains "$(log_file)" "[INFO] [run] OK disk /: 42% used"
}

test_run_missing_certificate() {
  rm "$ROOT/certs/www.example.com.pem"
  ohc run
  assert_status 2
  assert_contains "$(curl_calls)" "status=down"
  assert_contains "$(curl_calls)" "msg=1 problem(s): www.example.com: no certificate (handshake failed)"
  assert_contains "$(log_file)" "[ERROR] [run] www.example.com: no certificate (handshake failed)"
}

test_run_traefik_default_certificate() {
  cert www.example.com 365 "TRAEFIK DEFAULT CERT"
  echo "18 (self-signed certificate)" > "$ROOT/certs/www.example.com.verify"
  ohc run
  assert_status 2
  assert_contains "$(curl_calls)" "www.example.com: Traefik default certificate"
}

test_run_invalid_certificate() {
  echo "62 (hostname mismatch)" > "$ROOT/certs/example.com.verify"
  ohc run
  assert_status 2
  assert_contains "$(curl_calls)" "example.com: invalid certificate (62 (hostname mismatch))"
}

test_run_expiring_certificate() {
  cert example.com 10
  ohc run
  assert_status 2
  assert_matches "$(curl_calls)" "example.com: certificate expires in (9|10)d"
}

test_run_disk_above_threshold() {
  export FAKE_DISK_USAGE=90
  ohc run
  assert_status 2
  assert_contains "$(curl_calls)" "disk /: 90% used (threshold 85%)"
}

test_run_disk_unreadable() {
  export FAKE_DF_FAIL=1
  ohc run
  assert_status 2
  assert_contains "$(curl_calls)" "disk /: usage unreadable"
}

test_run_multiple_problems() {
  rm "$ROOT/certs/example.com.pem"
  export FAKE_DISK_USAGE=99
  ohc run
  assert_status 2
  assert_contains "$(curl_calls)" "msg=2 problem(s): example.com: no certificate (handshake failed); disk /: 99% used"
}

test_run_dry_run_does_not_push() {
  rm "$ROOT/certs/example.com.pem"
  ohc run --dry-run
  assert_status 2
  [[ ! -s "$(curl_calls)" ]] || fail "dry run pushed: $(cat "$(curl_calls)")"
  assert_contains "$(log_file)" "[INFO] [dry-run] Dry run, not pushed: down - 1 problem(s)"
}

test_run_cli_domains_override_config() {
  ohc run --dry-run missing.example.com
  assert_status 2
  assert_contains "$(log_file)" "missing.example.com: no certificate"
  assert_not_contains "$ROOT/openssl-calls" "-servername example.com "
}

test_run_expiry_days_override() {
  ohc run --dry-run --expiry-days 365
  assert_status 2
  assert_matches "$(log_file)" " example.com: certificate expires in (59|60)d"
  assert_matches "$(log_file)" "www.example.com: certificate expires in (89|90)d"
}

test_run_custom_origin() {
  config 'ORIGIN_HOST="::1"' 'ORIGIN_PORT=8443'
  ohc run
  assert_status 0
  assert_contains "$ROOT/openssl-calls" "-connect ::1:8443 "
}

test_run_push_failure_is_logged() {
  export FAKE_CURL_FAIL=1
  ohc run
  assert_status 0
  assert_contains "$(log_file)" "[ERROR] [run] Could not reach the push URL"
}

test_run_without_push_url_only_logs() {
  config 'PUSH_URL=""'
  ohc run
  assert_status 0
  [[ ! -s "$(curl_calls)" ]] || fail "pushed without PUSH_URL"
  assert_contains "$(log_file)" "[WARN] [run] PUSH_URL is empty, result not sent: up"
}

test_run_no_domains() {
  config 'DOMAINS=()'
  ohc run
  assert_status 3
  assert_contains "$(curl_calls)" "msg=origin-health-check: no domains configured"
}

test_run_push_url_with_query_string_rejected() {
  config 'PUSH_URL="http://127.0.0.1:3001/api/push/testtoken?status=up&msg=OK&ping="'
  ohc run
  assert_status 3
  assert_contains "$OUT" "PUSH_URL must not contain a query string"
  [[ ! -s "$(curl_calls)" ]] || fail "pushed with an invalid PUSH_URL"
}

test_run_invalid_threshold_rejected() {
  config 'DISK_THRESHOLD=120'
  ohc run
  assert_status 3
  assert_contains "$OUT" "invalid DISK_THRESHOLD '120'"
}

test_run_missing_config() {
  rm "$ORIGIN_HEALTH_CHECK_CONFIG"
  ohc run
  assert_status 3
  assert_contains "$OUT" "config file not found or not readable"
}

test_run_unknown_option() {
  ohc run --verbose
  assert_status 1
}

# --- Tests: other commands -----------------------------------------------------

test_status() {
  ohc run
  ohc status
  assert_status 0
  assert_contains "$OUT" "Domains:    2"
  assert_contains "$OUT" "Push:       configured"
  assert_contains "$OUT" "Result: 2 certs OK"
}

test_schedule() {
  ohc schedule enable
  assert_status 0
  assert_contains "$ORIGIN_HEALTH_CHECK_CRON_FILE" "15 */6 * * * root /usr/local/bin/origin-health-check run"
  [[ "$(stat -c %a "$ORIGIN_HEALTH_CHECK_CRON_FILE" 2>/dev/null)" == "600" ]] || fail "cron file mode is not 600"
  ohc schedule disable
  assert_status 0
  [[ ! -e "$ORIGIN_HEALTH_CHECK_CRON_FILE" ]] || fail "cron file not removed"
}

test_schedule_custom() {
  config 'SCHEDULE="0 7 * * *"'
  ohc schedule enable
  assert_status 0
  assert_contains "$ORIGIN_HEALTH_CHECK_CRON_FILE" "0 7 * * * root /usr/local/bin/origin-health-check run"
}

test_version() {
  ohc version
  assert_status 0
  assert_contains "$OUT" "$(cat "$REPO_DIR/VERSION")"
}

test_unknown_command() {
  ohc frobnicate
  assert_status 1
}

# --- Runner --------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
  tests=("$@")
else
  mapfile -t tests < <(declare -F | sed -n "s/^declare -f \\(test_.*\\)/\\1/p")
fi

passed=0
failed=0
for test in "${tests[@]}"; do
  setup
  : > "$FAILURES"
  # Subshell: exported FAKE_* variables do not leak between tests
  ( "$test" )
  if [[ -s "$FAILURES" ]]; then
    echo "FAIL  $test"
    cat "$FAILURES"
    failed=$((failed + 1))
  else
    echo "PASS  $test"
    passed=$((passed + 1))
  fi
done

echo
echo "$passed passed, $failed failed"
if (( failed > 0 )); then
  exit 1
fi
