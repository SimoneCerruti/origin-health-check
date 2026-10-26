# CLAUDE.md

Guidance for working on this repository.

## What this is

`origin-health-check` is a pure-bash check for a single Docker host behind a CDN (e.g. Cloudflare).
It connects to the origin reverse proxy with SNI for every configured domain, bypassing the CDN,
verifies the certificate the origin actually serves, checks disk usage and reports the result to an
Uptime Kuma push monitor. It is installed with one command and must be reproducible on a fresh
Debian server.

Why it exists: with the CDN in front, visitors see the CDN's certificate. A missing or expired
origin certificate stays hidden until the CDN switches to strict validation, and with a strict SNI
policy on the origin (Traefik `sniStrict`) the site then fails. This tool reports it beforehand.

## Layout

```
origin-health-check                 entrypoint: sources lib/*, dispatches commands
lib/common.sh                       config loading, logging, notifications
lib/checks.sh                       certificate and disk checks
lib/commands.sh                     run, status, schedule, self-update
install.sh                          installer and updater (also used by self-update)
templates/logrotate                 installed to /etc/logrotate.d/origin-health-check
origin-health-check.conf.example    documented configuration, copied once to /etc/origin-health-check
tests/run.sh                        smoke tests with fake openssl s_client, curl and df (not installed)
```

## Design rules

- **Code and config are separate.** Code lives in `/opt/origin-health-check` and is replaced on
  every update. `/etc/origin-health-check/origin-health-check.conf` is created once and never
  overwritten. New settings must have a default in `load_config()` so old config files keep working.
- **The domain list is explicit.** Domains are never discovered from Docker labels or the proxy:
  the tool exists to notice what is missing, and discovery would hide a vanished router.
- **Fail loudly.** Every problem is logged as ERROR, sent to the journal and to the push monitor in
  one `down` message listing all problems. A stopped schedule is caught by the monitor's heartbeat.
- **PUSH_URL has no query string.** `status` and `msg` are appended; a URL copied from Kuma with
  `?status=up` would send two statuses, so `load_config` rejects it.
- **No new dependencies** beyond what Debian ships: no Python, no jq.

## Conventions

- Bash with `set -Eeuo pipefail` in entrypoints; library files are sourced, not executed.
- Commands that may legitimately fail inside checks are guarded (`|| true`, `|| var=""`) so
  `set -e` never aborts a run halfway: every check must report.
- Identifiers, comments, logs and docs in English.
- Functions that may legitimately produce no output end with `return 0`.
- Must pass `bash -n` and `shellcheck -x origin-health-check install.sh lib/*.sh tests/run.sh`
  (CI enforces it).

## Testing

`tests/run.sh` (pure bash, no framework) runs the commands against fake `openssl s_client`, `curl`,
`df` and `logger` executables placed first in `PATH`, inside a temporary directory. Certificates are
real, generated with openssl for each test; every other openssl subcommand runs the real binary.
Run `bash tests/run.sh`, or `bash tests/run.sh test_run_all_ok ...` for single tests.
It needs neither root nor network access. CI runs it after ShellCheck.

- `s_client` serves `$FAKE_ROOT/certs/<servername>.pem` with the verify result in
  `<servername>.verify` (default `0 (ok)`); without a certificate it fails like a rejected handshake.
  Calls are recorded in `$FAKE_ROOT/openssl-calls`.
- The fake `curl` records every call in `$FAKE_ROOT/curl-calls`; `FAKE_CURL_FAIL=1` makes it fail.
- The fake `df` reports `FAKE_DISK_USAGE` (default 42); `FAKE_DF_FAIL=1` makes it fail.
- Certificates are issued "now", so days left may be N or N-1: assert with `assert_matches`.
- Tests must never touch real system paths. Hard-coded system paths are overridable through
  environment variables that default to the production value. Any new one must follow the
  same pattern and be listed here:

  | Variable                             | Default                                            |
  |--------------------------------------|----------------------------------------------------|
  | `ORIGIN_HEALTH_CHECK_CONFIG`         | `/etc/origin-health-check/origin-health-check.conf` |
  | `ORIGIN_HEALTH_CHECK_CRON_FILE`      | `/etc/cron.d/origin-health-check`                  |
  | `ORIGIN_HEALTH_CHECK_ALLOW_NON_ROOT` | unset; `1` skips the root check (tests only)       |

- New behaviour comes with a test.

## Releasing

1. Update `VERSION` and `CHANGELOG.md`.
2. Commit, then tag `vX.Y.Z` matching `VERSION` and push the tag.
3. The release workflow checks the tag against `VERSION`, lints, tests and creates the GitHub release.

Exit codes: 0 all checks passed, 1 usage, 2 problems found, 3 configuration error.
