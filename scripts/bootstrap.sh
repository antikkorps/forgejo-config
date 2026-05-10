#!/usr/bin/env bash
# One-shot server bootstrap for a fresh Hetzner Debian 12 / Ubuntu 24.04 VM.
# Run as root: bash bootstrap.sh

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
	echo "run as root"
	exit 1
fi

# --- packages
apt-get update
apt-get upgrade -y
apt-get install -y \
	curl ca-certificates gnupg ufw fail2ban restic cron \
	apt-transport-https lsb-release

# --- docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
	-o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
	"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
	> /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
	docker-buildx-plugin docker-compose-plugin

# --- tailscale
curl -fsSL https://tailscale.com/install.sh | sh
echo "==> Run: tailscale up --ssh"
echo "    (then close port 22 publicly — see UFW step below)"

# --- move host SSH to port 2222 so port 22 is free for Forgejo SSH
sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

# --- firewall: allow Forgejo Git SSH (22) + HTTP-only via cloudflared (no 80/443 needed)
#     Admin SSH (2222) is restricted to the Tailscale interface only.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'forgejo git ssh'
ufw allow in on tailscale0 to any port 2222 proto tcp comment 'admin ssh via tailscale'
ufw --force enable

# --- fail2ban basic ssh jail
systemctl enable --now fail2ban

# --- deploy directory
mkdir -p /opt/forgejo

# --- ensure UID/GID 1000 exists for the forgejo container.
#     The Forgejo image runs as 1000:1000 by default and chowns its volumes
#     to that UID. If the host has no user 1000, file ownership becomes
#     orphan-numeric — works but confuses other tooling. We create a
#     dedicated `forgejo` system user matching the container.
if ! id -u 1000 >/dev/null 2>&1; then
	groupadd -g 1000 forgejo
	useradd -u 1000 -g 1000 -M -s /usr/sbin/nologin forgejo
fi
chown -R 1000:1000 /opt/forgejo

cat <<EOF

============================================================
Bootstrap done. Next steps:

1. tailscale up --ssh           # auth in browser
2. Move/clone this repo to /opt/forgejo
3. cp .env.example .env && edit secrets
4. In Cloudflare Zero Trust > Networks > Tunnels:
     - create a tunnel, copy the token into CLOUDFLARE_TUNNEL_TOKEN
     - add a public hostname: git.fvienot.link -> http://caddy:80
5. cd /opt/forgejo && docker compose up -d
6. Open https://git.fvienot.link, create the admin user
7. crontab backup/crontab        (after editing paths)

After verifying Tailscale SSH works, reconnect on port 2222
through Tailscale, then you can drop the public 22 admin
access entirely.
============================================================
EOF
