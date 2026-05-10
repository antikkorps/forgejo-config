# Forgejo on Hetzner

Self-hosted Forgejo behind Cloudflare Tunnel, with PostgreSQL,
encrypted restic backups to Cloudflare R2, and Tailscale-only admin SSH.

## Accessing the server

| Purpose | How |
|---------|-----|
| **Admin SSH** | `ssh -p 2222 root@<tailscale-name-or-ip>` (Tailscale only — port 2222 is closed on the public IP) |
| **Git over SSH** | `git clone git@git.fvienot.link:user/repo.git` (port 22, public) |
| **Web UI** | https://git.fvienot.link (Cloudflare Tunnel — no public 80/443) |

The host SSH daemon was moved from port 22 to **2222** during bootstrap so
that port 22 is free for Forgejo's built-in SSH server. Port 2222 is only
reachable via the Tailscale interface (`tailscale0`).

If you ever lose Tailscale access, recovery requires Hetzner console access
(VNC) to restore SSH.

## Architecture

```
                Internet
                   │
                   ▼
         Cloudflare (TLS edge)
                   │
        ┌──────────┴──────────┐
        │                     │
     git push                 ▼
     (SSH :22)        Cloudflare Tunnel
        │                     │
        ▼                     ▼
   ┌────────────────────────────────┐
   │  Hetzner VM (CX22)             │
   │                                │
   │  forgejo ── postgres           │
   │     │                          │
   │   caddy ◄── cloudflared        │
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
| `docker-compose.yml` | forgejo + postgres + caddy + cloudflared |
| `.env.example`       | secrets template — copy to `.env` |
| `caddy/Caddyfile`    | HTTP-only reverse proxy (TLS at CF edge) |
| `backup/backup.sh`   | nightly: pg_dump + restic → R2 |
| `backup/restore.sh`  | restore from a snapshot |
| `backup/crontab`     | cron schedule for backup + weekly check |
| `scripts/bootstrap.sh` | provisions a fresh Hetzner VM |

## Deploy (first time)

1. **Create Hetzner CX22**, Debian 12, attach a 20 GB volume mounted at `/opt/forgejo/data` (optional but recommended).
2. **Run bootstrap** as root: `bash scripts/bootstrap.sh`.
3. **Tailscale**: `tailscale up --ssh`, accept in browser.
4. **Cloudflare Tunnel** (Zero Trust → Networks → Tunnels):
   - Create tunnel, copy the docker token into `.env` as `CLOUDFLARE_TUNNEL_TOKEN`.
   - Public hostname: `git.fvienot.link` → service `http://caddy:80`.
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
   docker compose up -d forgejo postgres caddy cloudflared
   ```
2. Log in as admin → **Site Administration → Actions → Runners → Create new Runner** → copy the token.
3. Register the runner (writes `.runner` into `./data/runner`):
   ```
   docker run --rm -it \
     -v "$PWD/data/runner:/data" \
     code.forgejo.org/forgejo/runner:6 \
     forgejo-runner register \
       --no-interactive \
       --instance http://forgejo:3000 \
       --token <REGISTRATION_TOKEN> \
       --name vm-runner \
       --labels docker:docker://node:20-bookworm
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
- [ ] **Cloudflare WAF — geo-block outside France**
      Zero Trust → Cloudflare dashboard → your domain → **Security → WAF → Custom rules**:
      ```
      (ip.geoip.country ne "FR" and http.host eq "git.fvienot.link")
      → Block
      ```
      Add an exception if you travel: `or ip.src in {YOUR_HOME_IP}`.
      Also enable **Bot Fight Mode** (Security → Bots).
      Note: this does NOT block git SSH (port 22 bypasses Cloudflare).
- [ ] **R2 bucket hardening**
      - Use a **write-only token** for the VM (no `Object:Delete`).
      - Enable **Object Lock** (Compliance mode, 30 days) so even a compromised
        VM can't wipe your backups.
      - Keep a separate admin token *off the VM* for retention/restore.
- [ ] **Run `./backup/backup.sh` manually**, then `./backup/restore-test.sh`
      to confirm the full loop before trusting it.

## Day-to-day

- **Update Forgejo**: `docker compose pull && docker compose up -d`
- **Logs**: `docker compose logs -f forgejo`
- **Manual backup**: `./backup/backup.sh`
- **List snapshots**: `set -a && . .env && set +a && restic snapshots`
- **Restore**: `./backup/restore.sh latest`

## Ports / firewall

| Port | Where | Purpose |
|------|-------|---------|
| 22   | public | Forgejo SSH (git clone/push) |
| 2222 | Tailscale only | Host admin SSH |
| 80/443 | **closed** | All web traffic via Cloudflare Tunnel |

## Renovate

Add a `renovate.json` once the repo lives in Forgejo itself; for now,
manually `docker compose pull` monthly. Postgres major upgrades (16→17)
need a manual dump+restore — don't auto-bump that one.
