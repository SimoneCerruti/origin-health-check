# origin-health-check

A small pure-bash check for a Docker host behind a CDN: it verifies the TLS certificate your
**origin** actually serves for every domain, bypassing the CDN, checks disk usage and reports the
result to an [Uptime Kuma](https://github.com/louislam/uptime-kuma) push monitor. One command
installs it on a new server.

## What it solves

With Cloudflare (or any CDN) proxying your sites, visitors and external monitors only ever see the
CDN's certificate. If the origin certificate is missing or its renewal fails, nothing looks wrong:

- with SSL mode **Full**, the CDN accepts any origin certificate, so the problem stays hidden for months;
- with **Full (strict)**, or a strict SNI policy on the reverse proxy (Traefik `sniStrict: true`),
  the site breaks the day the certificate expires or disappears.

`origin-health-check` connects to the reverse proxy directly (`127.0.0.1:443` by default) with the
right SNI for each domain and reports, before visitors notice:

| Problem                    | Typical cause                                                       |
|----------------------------|---------------------------------------------------------------------|
| No certificate             | Router removed or never issued: handshake rejected with `sniStrict` |
| Traefik default certificate | No certificate matches the name and SNI is not strict              |
| Invalid certificate        | Self-signed, incomplete chain, or issued for another name           |
| Expires within N days      | Renewal failing (ACME challenge, DNS token, rate limits)            |
| Disk above threshold       | Logs, uploads, images or volumes filling the disk                   |

The result goes to a Kuma **push** monitor: `up` with a summary, `down` with every problem found.
If the check stops running altogether, the monitor's heartbeat expires and Kuma alerts as well.

## Requirements

- Debian or Ubuntu (tested on Debian 13)
- Root access
- An Uptime Kuma push monitor (optional: without it, results are only logged)
- The installer adds `openssl`, `curl`, `ca-certificates`, `coreutils`, `cron`, `logrotate`

No Python, no jq.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/origin-health-check/main/install.sh | sudo bash
```

Pin a release:

```bash
curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/origin-health-check/main/install.sh | sudo bash -s -- --version 1.0.0
```

Installer options: `--version X.Y.Z` (default: latest release), `--ref BRANCH` (development),
`--no-deps` (skip `apt-get`).

Layout after install:

```
/opt/origin-health-check/                         code (replaced on update, previous version in /opt/origin-health-check.old)
/etc/origin-health-check/origin-health-check.conf configuration (never overwritten)
/var/log/origin-health-check/                     logs (rotated weekly, 8 weeks kept)
/usr/local/bin/origin-health-check                -> /opt/origin-health-check/origin-health-check
/etc/cron.d/origin-health-check                   schedule (managed by 'origin-health-check schedule')
```

## First setup

1. **Push monitor**: in Uptime Kuma add a monitor of type *Push*, with a heartbeat interval longer
   than the schedule interval (e.g. `25200` seconds for the default 6 hours) and retries `0`.
   Copy its URL **up to the token**, without `?status=up&msg=OK&ping=`.
2. **Configure**: `sudo nano /etc/origin-health-check/origin-health-check.conf`: `PUSH_URL` and
   `DOMAINS` at least (see [Configuration](#configuration)). If Kuma runs on the same host, use its
   local endpoint (`http://127.0.0.1:3001/api/push/<token>`), so the result does not depend on the
   CDN or DNS.
3. **Test without pushing**:

   ```bash
   sudo origin-health-check run --dry-run
   ```

4. **Test the failure paths** (still without pushing):

   ```bash
   sudo origin-health-check run --dry-run nonexistent.example.com   # missing certificate
   sudo origin-health-check run --dry-run --expiry-days 365         # every certificate "expiring"
   ```

5. **Test with push**, then **schedule**:

   ```bash
   sudo origin-health-check run
   sudo origin-health-check schedule enable
   ```

## Usage

| Command                                                | Description                                                  |
|--------------------------------------------------------|--------------------------------------------------------------|
| `origin-health-check run`                              | Run all checks and push the result                           |
| `origin-health-check run --dry-run`                    | Run all checks without pushing                               |
| `origin-health-check run --expiry-days N`              | Override `EXPIRY_DAYS` for this run                          |
| `origin-health-check run DOMAIN...`                    | Check only these domains (disk is always checked)            |
| `origin-health-check status`                           | Version, schedule, configuration summary, recent results     |
| `origin-health-check schedule enable\|disable\|status` | Manage the cron schedule from `SCHEDULE`                     |
| `origin-health-check self-update [--version X.Y.Z]`    | Update origin-health-check itself (config untouched)         |
| `origin-health-check version`                          | Print the installed version                                  |

All commands except `version` and `help` need root.

## Configuration

`/etc/origin-health-check/origin-health-check.conf` is a bash file. Every value has a default; the
example file documents them all.

| Setting           | Default                         | Description                                                    |
|-------------------|---------------------------------|----------------------------------------------------------------|
| `PUSH_URL`        | empty                           | Kuma push URL up to the token; empty: results only logged      |
| `ORIGIN_HOST`     | `127.0.0.1`                     | Address of the origin reverse proxy                            |
| `ORIGIN_PORT`     | `443`                           | TLS port of the origin                                         |
| `CONNECT_TIMEOUT` | `15`                            | Seconds allowed for each TLS connection                        |
| `EXPIRY_DAYS`     | `20`                            | Alert when a certificate expires in fewer days                 |
| `DISK_THRESHOLD`  | `85`                            | Alert when usage is above this percentage                      |
| `DISK_PATHS`      | `(/)`                           | Filesystems to check                                           |
| `DOMAINS`         | empty (required)                | Hostnames to check, redirect sources (e.g. `www`) included     |
| `SCHEDULE`        | `15 */6 * * *`                  | Cron expression for the scheduled run                          |
| `LOG_DIR`         | `/var/log/origin-health-check`  | Log directory                                                  |

After changing `SCHEDULE`, run `sudo origin-health-check schedule enable` to regenerate the cron file.

**Why 20 days**: Traefik and certbot renew Let's Encrypt certificates 30 days before expiry, so a
certificate with fewer than 20 days left means renewal has been failing for about 10 days, with
enough time left to fix it.

**Why the domain list is explicit**: the tool exists to notice what is missing. Discovering
domains from Docker labels or the proxy configuration would silently drop the one whose router
vanished.

## Logging

```
/var/log/origin-health-check/origin-health-check.log   every run: one line per domain and the result
/var/log/origin-health-check/cron.log                  unexpected output from scheduled runs (usually empty)
journalctl -t origin-health-check                      problems only
```

Example:

```
2026-10-26 06:15:01 [INFO] [run] OK example.com: 61d left
2026-10-26 06:15:01 [ERROR] [run] www.example.com: no certificate (handshake failed)
2026-10-26 06:15:01 [ERROR] [run] Result: 1 problem(s): www.example.com: no certificate (handshake failed)
```

## Migrating from the standalone script

If you used the earlier single-file setup (`/usr/local/bin/origin-health-check.sh` and
`/etc/origin-health-check.conf`), the installer moves the config to
`/etc/origin-health-check/origin-health-check.conf` (the variable names are the same), removes the
old script and regenerates the cron file.

## Exit codes

| Code | Meaning                                         |
|------|-------------------------------------------------|
| `0`  | All checks passed                               |
| `1`  | Usage error                                     |
| `2`  | Problems found (certificates or disk)           |
| `3`  | Configuration error (missing file, bad value)   |

## Limitations

- Linux with GNU coreutils only.
- Certificates are checked against the system CA bundle (`ca-certificates`): an origin using a
  CDN origin certificate (e.g. Cloudflare Origin CA) is reported as invalid.
- The check runs on the host it monitors: if the host is down, nothing is pushed and only the
  push monitor's heartbeat (or an external check of Kuma itself) reveals it.

## Uninstall

```bash
sudo origin-health-check schedule disable
sudo rm -rf /opt/origin-health-check /opt/origin-health-check.old /usr/local/bin/origin-health-check /etc/logrotate.d/origin-health-check
# Optional: configuration and logs
sudo rm -rf /etc/origin-health-check /var/log/origin-health-check
```

## License

MIT
