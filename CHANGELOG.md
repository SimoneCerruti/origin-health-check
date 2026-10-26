# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-26

### Added
- `run`: connects to the origin with SNI for every configured domain, bypassing the CDN, and
  reports a missing certificate (handshake rejected), the Traefik default certificate, an invalid
  certificate (chain or hostname) or one expiring within `EXPIRY_DAYS`; checks disk usage
  against `DISK_THRESHOLD`.
- Result sent to an Uptime Kuma push monitor: `up` with a summary, `down` with every problem.
  A stopped schedule is caught by the monitor's heartbeat.
- `run --dry-run`, `--expiry-days N` and domain arguments for testing.
- `status`, `schedule` and `self-update` commands.
- Structured logging to `/var/log/origin-health-check`, errors to the journal.
- One-command installer with atomic updates; configuration is never overwritten.
  The manual setup (`/usr/local/bin/origin-health-check.sh`, `/etc/origin-health-check.conf`)
  is migrated automatically.
- Smoke test suite (`tests/run.sh`) with real certificates and a fake TLS connection, run in CI.
