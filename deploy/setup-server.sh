#!/usr/bin/env bash
# One-time setup of the server (Deploy Step 5, docs/deploy.md §10): Ubuntu 24.04 on Oracle
# Cloud's Always Free ARM VM. Run it from the cloned repo, as root:
#     sudo deploy/setup-server.sh codetutor.duckdns.org
# Safe to run again. It installs Docker, gVisor and Caddy, opens ports 80 and 443, and turns on
# the nightly database backup. It does not start the app: that is `make prod-build prod-up`.
set -euo pipefail

DOMAIN="${1:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_USER="${SUDO_USER:-ubuntu}"
BACKUP_DIR="/var/backups/codetutor"

if [ "$(id -u)" -ne 0 ]; then
    echo "run this as root: sudo $0 <domain>" >&2
    exit 1
fi
if ! [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "usage: sudo $0 <domain>   (for example codetutor.duckdns.org)" >&2
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [ "$ID" != "ubuntu" ]; then
    echo "written for Ubuntu, this is $PRETTY_NAME" >&2
    exit 1
fi

step() { echo; echo "== $*"; }

step "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl git make zstd gnupg iptables-persistent \
    debian-keyring debian-archive-keyring apt-transport-https

step "Docker (from Docker's own apt repository)"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc]" \
    "https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$APP_USER"

step "gVisor (the grading sandbox's own kernel)"
if docker info --format '{{json .Runtimes}}' | grep -q '"runsc"'; then
    echo "runsc is already registered"
else
    "$REPO/deploy/install-gvisor.sh"
fi

step "Caddy (HTTPS in front of the app)"
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    -o /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
apt-get install -y -q caddy
install -d -o caddy -g caddy /var/log/caddy
sed "s/CODETUTOR_DOMAIN/$DOMAIN/" "$REPO/deploy/Caddyfile" > /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable caddy
systemctl reload-or-restart caddy

step "firewall: ports 80 and 443"
# Oracle's Ubuntu image rejects everything but SSH in iptables (on top of the cloud's own
# security list). Add the two ports before its REJECT rule, now and in the saved rules file.
# The file is edited by hand on purpose: `netfilter-persistent save` would also save Docker's
# own rules, which Docker writes again at every start.
for port in 80 443; do
    rule=(-p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT)
    if ! iptables -C INPUT "${rule[@]}" 2>/dev/null; then
        reject="$(iptables -L INPUT --line-numbers -n | awk '$2 == "REJECT" {print $1; exit}')"
        if [ -n "$reject" ]; then
            iptables -I INPUT "$reject" "${rule[@]}"
        else
            iptables -A INPUT "${rule[@]}"
        fi
    fi
    saved="-A INPUT ${rule[*]}"
    if [ -f /etc/iptables/rules.v4 ] && ! grep -qF -- "$saved" /etc/iptables/rules.v4; then
        if grep -q '^-A INPUT -j REJECT' /etc/iptables/rules.v4; then
            sed -i "0,/^-A INPUT -j REJECT/s//$saved\n&/" /etc/iptables/rules.v4
        else
            sed -i "/^COMMIT/i $saved" /etc/iptables/rules.v4
        fi
    fi
done

step "nightly database backup (03:30 UTC, the newest 7 kept)"
install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "$BACKUP_DIR"
install -m 0640 -o "$APP_USER" -g "$APP_USER" /dev/null /var/log/codetutor-backup.log
cat > /etc/cron.d/codetutor-backup <<EOF
# Written by deploy/setup-server.sh. A database dump every night (deploy/backup.sh).
30 3 * * * $APP_USER cd $REPO && BACKUP_DIR=$BACKUP_DIR deploy/backup.sh >> /var/log/codetutor-backup.log 2>&1
EOF
chmod 0644 /etc/cron.d/codetutor-backup

step "done"
cat <<EOF
Next, as $APP_USER (log out and back in first, so the docker group applies):
  cd $REPO
  cp .env.prod.example .env.prod      # fill it in; SANDBOX_RUNTIME=runsc on this server
  make prod-build prod-up
  make prod-demo-data prod-demo-up    # optional: the public /demo (~13 min once)
Then open https://$DOMAIN and, from your own computer:
  deploy/check-proxy-ip.sh https://$DOMAIN
EOF
