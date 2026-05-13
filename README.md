# Forgejo on Hetzner

Self-hosted Forgejo on a Hetzner VM, fronted by Caddy with Let's Encrypt
TLS, PostgreSQL, encrypted restic backups to Cloudflare R2, and
Tailscale-only admin SSH.

## Accessing the server

| Purpose | How |
|---------|-----|
| **Admin SSH** | `ssh -p 2222 root@<tailscale-name-or-ip>` (Tailscale only — port 2222 is closed on the public IP) |
| **Git over SSH** | `git clone git@git.fvienot.link:user/repo.git` (port 22, public) |
| **Web UI** | https://git.fvienot.link (Caddy + Let's Encrypt on 80/443) |

The host SSH daemon was moved from port 22 to **2222** during bootstrap so
that port 22 is free for Forgejo's built-in SSH server. Port 2222 is only
reachable via the Tailscale interface (`tailscale0`).

If you ever lose Tailscale access, recovery requires Hetzner console access
(VNC) to restore SSH.

## Architecture

```
                Internet
                   │
        ┌──────────┴──────────┐
        │                     │
     git push           HTTPS (:443)
     (SSH :22)          Cloudflare DNS-only
        │                     │
        ▼                     ▼
   ┌────────────────────────────────┐
   │  Hetzner VM (CX22)             │
   │                                │
   │  caddy (TLS, Let's Encrypt)    │
   │     │                          │
   │  forgejo ── postgres           │
   │                                │
   │  cron: restic ──► R2 (encrypted)│
   └────────────────────────────────┘
        ▲
        │ tailscale (admin SSH :2222)
        │
   You / your laptop
```

## Files

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | forgejo + postgres + caddy + runner |
| `.env.example`       | secrets template — copy to `.env` |
| `caddy/Caddyfile`    | reverse proxy + automatic Let's Encrypt TLS |
| `backup/backup.sh`   | nightly: pg_dump + restic → R2 |
| `backup/restore.sh`  | restore from a snapshot |
| `backup/crontab`     | cron schedule for backup + weekly check |
| `scripts/bootstrap.sh` | provisions a fresh Hetzner VM |

## Deploy (first time)

1. **Create Hetzner CX22**, Debian 12, attach a 20 GB volume mounted at `/opt/forgejo/data` (optional but recommended).
2. **Run bootstrap** as root: `bash scripts/bootstrap.sh`.
3. **Tailscale**: `tailscale up --ssh`, accept in browser.
4. **Cloudflare DNS**: create an `A` record for `git.fvienot.link` → VM public IP,
   **DNS-only** (grey cloud), so Caddy can complete the ACME challenge on :80/:443.
   Open ports 80 and 443 on the Hetzner firewall.
   Set `ACME_EMAIL` in `.env` (used for Let's Encrypt renewal notices).
5. **R2 bucket**: create `forgejo-backups`, generate an S3-compatible API token,
   fill `RESTIC_*` and `AWS_*` in `.env`. Generate a strong `RESTIC_PASSWORD`
   and **store it outside the VM** (without it, backups are unrecoverable).
6. **Resend**: copy API key → `RESEND_API_KEY`, verify `fvienot.link` domain.
7. **Healthchecks.io**: create a check, paste the ping URL → `HEALTHCHECK_URL`.
8. `cp .env.example .env`, fill it, then:
   ```
   docker compose up -d
   ```
9. Open `https://git.fvienot.link` → create the first admin user.
10. Install cron: `crontab backup/crontab` (after adjusting paths).
11. **Test the restore** in a throwaway dir before trusting it.

## Runner registration (Forgejo Actions)

The runner needs a one-time registration token from your Forgejo instance.

1. Start everything **except** the runner first:
   ```
   docker compose up -d forgejo postgres caddy
   ```
2. Log in as admin → **Site Administration → Actions → Runners → Create new Runner** → copy the token.
3. Register the runner (writes `.runner` into `./data/runner`):
   ```
   docker run --rm -it \
     -v "$PWD/data/runner:/data" \
     code.forgejo.org/forgejo/runner:12 \
     forgejo-runner register \
       --no-interactive \
       --instance http://forgejo:3000 \
       --token <REGISTRATION_TOKEN> \
       --name vm-runner \
       --labels docker:docker://node:24-bookworm
   ```
   (Run this on the same docker network: add `--network forgejo_web` if needed,
   or use the public URL `https://git.fvienot.link` instead of the internal one.)
4. Now bring up the runner: `docker compose up -d runner`
5. Verify it appears as **Idle** in the admin Runners page.

For the **home server runner** (heavy jobs): same procedure on that machine,
register with a different name (e.g. `home-runner`) and labels
(e.g. `heavy:docker://...`). Workflows then target it via `runs-on: heavy`.

## Forgejo settings to enable post-install (Site Admin UI)

- **Two-Factor Authentication** on every account, especially admin.
- **Actions → Approval for first-time contributors**: required.
  Without this, an external PR can run arbitrary code on the runner
  (which has access to the host docker socket).
- **Repo visibility default**: Private.
- Audit users / orgs periodically; remove dormant tokens and SSH keys.

## Hardening checklist (do these on day 1)

- [ ] **Force 2FA** on your admin account immediately after creation
      (User Settings → Security → Two-Factor Authentication).
      For org-wide enforcement: set `[service] REQUIRE_SIGNIN_VIEW = true`
      (already on) and require 2FA via `[security] DEFAULT_ENABLE_TIMETRACKING`
      style settings, or simply audit your few users.
- [ ] **Geo-block at Hetzner / Caddy level if desired**
      Since Cloudflare runs in DNS-only mode, the CF WAF is bypassed. If you
      want a country block, do it at the Hetzner firewall (IP-range based) or
      add Caddy `@geo` matchers via the `caddy-maxmind-geolocation` module.
      Note: this does NOT block git SSH (port 22).
- [ ] **R2 bucket hardening**
      - Use a **write-only token** for the VM (no `Object:Delete`).
      - Enable **Object Lock** (Compliance mode, 30 days) so even a compromised
        VM can't wipe your backups.
      - Keep a separate admin token *off the VM* for retention/restore.
- [ ] **Run `./backup/backup.sh` manually**, then `./backup/restore-test.sh`
      to confirm the full loop before trusting it.

## Day-to-day

- **Update Forgejo (patch/minor on the current major)**: `docker compose pull && docker compose up -d`
- **Logs**: `docker compose logs -f forgejo`
- **Manual backup**: `./backup/backup.sh`
- **List snapshots**: `set -a && . .env && set +a && restic snapshots`
- **Restore**: `./backup/restore.sh latest`

## fail2ban — check and manage bans

Three jails are deployed (config in `fail2ban/`, deployed to `/etc/fail2ban/`):

| Jail          | Source                                              | Protects                |
|---------------|-----------------------------------------------------|-------------------------|
| `sshd`        | `/var/log/auth.log`                                 | Host admin SSH (:2222)  |
| `forgejo-ssh` | `/var/lib/docker/containers/*/*-json.log`           | Forgejo container SSH (:22) |
| `forgejo-web` | `data/forgejo/gitea/log/gitea.log`                  | Forgejo web login       |

Policy: **10 failures within 10 min** → ban. First ban 1h, then ×4 each
repeat (1h → 4h → 16h → … capped at 30d). Tailscale CGNAT (`100.64.0.0/10`)
and loopback are whitelisted so you can't lock yourself out.

### Day-to-day commands

```
# Overview of all jails
sudo fail2ban-client status

# Details for one jail (currently failed, total failed, banned IPs)
sudo fail2ban-client status forgejo-web
sudo fail2ban-client status forgejo-ssh
sudo fail2ban-client status sshd

# Tail fail2ban's own log (ban/unban events)
sudo tail -f /var/log/fail2ban.log

# Manually unban an IP that got caught by mistake
sudo fail2ban-client set forgejo-web unbanip 1.2.3.4

# Manually ban an IP
sudo fail2ban-client set forgejo-web banip 1.2.3.4

# Reload after editing /etc/fail2ban/*
sudo systemctl reload fail2ban

# Validate a filter against the live log
sudo fail2ban-regex /srv/forgejo-config/data/forgejo/gitea/log/gitea.log \
    /etc/fail2ban/filter.d/forgejo-web.conf
```

### Updating fail2ban config

Source of truth lives in this repo under `fail2ban/`. After editing:

```
cd /srv/forgejo-config && git pull
sudo cp fail2ban/jail.local              /etc/fail2ban/jail.local
sudo cp fail2ban/jail.d/forgejo.local    /etc/fail2ban/jail.d/forgejo.local
sudo cp fail2ban/filter.d/forgejo-web.conf /etc/fail2ban/filter.d/forgejo-web.conf
sudo systemctl reload fail2ban
```

## Upgrading across a major (LTS to LTS)

Forgejo follows semver since 7.0: each major (`10` → `11` → … → `15`) can
contain breaking changes. Always read the release notes for every major you
cross. Direct jumps from any version > 10 to the current LTS are supported.

**Procedure on the VM:**

1. **Backup first** (non-negotiable):
   ```
   ./backup/backup.sh
   ```
   Verify the snapshot landed in R2 (`restic snapshots`).
2. **Pull the new images and recreate the containers** (the image tag is
   already pinned in `docker-compose.yml`):
   ```
   docker compose pull
   docker compose up -d
   ```
   Postgres is untouched; Forgejo runs its DB migrations on startup.
3. **Watch the logs** until the migration finishes and the healthcheck flips
   to healthy:
   ```
   docker compose logs -f forgejo
   ```
4. **Post-upgrade admin tasks** (Site Administration UI):
   - Run **"Sync missed branches from git data to databases"** (branches are
     mirrored in the DB since v11 to cut git process calls).
   - Check the runner shows up as **Idle** — bump its image tag in
     `docker-compose.yml` if the server major moved past its compat window
     (rule of thumb: keep the runner on a tag ≥ the server-required minimum).

### Notes specific to the v10 → v15 upgrade (current LTS)

- **All users will be re-logged out**: v15 renamed the default cookies to
  drop the legacy Gitea branding. To preserve existing sessions, set
  `FORGEJO__security__COOKIE_REMEMBER_NAME: gitea_incredible` in the compose
  env. Otherwise just expect to log back in.
- **Custom assets** (themes/CSS): if you ever drop files in
  `data/forgejo/gitea/custom/public/`, they must move under
  `…/custom/public/assets/` to be picked up. Not used here today.
- **Runner**: bump from `runner:6` to `runner:12` (already done in the
  compose). The existing `.runner` registration file is reused — no need to
  re-register.
- **Postgres**: stays on 16, supported. A 16 → 17 bump is a separate manual
  dump/restore.

## Ports / firewall

| Port | Where | Purpose |
|------|-------|---------|
| 22   | public | Forgejo SSH (git clone/push) |
| 2222 | Tailscale only | Host admin SSH |
| 80   | public | Caddy — HTTP→HTTPS redirect + ACME HTTP-01 |
| 443  | public | Caddy — HTTPS (Let's Encrypt) |

## Renovate

Add a `renovate.json` once the repo lives in Forgejo itself; for now,
manually `docker compose pull` monthly. Postgres major upgrades (16→17)
need a manual dump+restore — don't auto-bump that one.
