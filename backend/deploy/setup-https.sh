#!/usr/bin/env bash
# One-time VPS setup: nginx reverse proxy + Let's Encrypt cert for the Tchipa API.
#
# Run on the VPS (as root or with sudo). Idempotent — safe to re-run.
#
#   curl -sL https://raw.githubusercontent.com/tarik9991/tchipa-app/main/backend/deploy/setup-https.sh | bash
#
# or, if you SCP'd the deploy/ folder:
#
#   ADMIN_EMAIL=you@example.com bash /tmp/deploy/setup-https.sh

set -euo pipefail

DOMAIN="${DOMAIN:-api.tchipa.co.uk}"
BACKEND_PORT="${BACKEND_PORT:-3000}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@tchipa.co.uk}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NGINX_SRC="${SCRIPT_DIR}/nginx-api.conf"
NGINX_DST="/etc/nginx/sites-available/tchipa-api.conf"
NGINX_LINK="/etc/nginx/sites-enabled/tchipa-api.conf"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (or via sudo)."

# --------------------------------------------------------------------------
# 1. Install nginx + certbot
# --------------------------------------------------------------------------
if ! command -v nginx >/dev/null; then
    log "Installing nginx"
    apt-get update -y
    apt-get install -y nginx
else
    log "nginx already installed ($(nginx -v 2>&1))"
fi

if ! command -v certbot >/dev/null; then
    log "Installing certbot + nginx plugin"
    apt-get install -y certbot python3-certbot-nginx
else
    log "certbot already installed ($(certbot --version 2>&1))"
fi

# --------------------------------------------------------------------------
# 2. Verify the backend is reachable on localhost (warn, don't fail — port 80
#    is what certbot needs, not 3000).
# --------------------------------------------------------------------------
if curl -sfm 3 "http://127.0.0.1:${BACKEND_PORT}/" >/dev/null 2>&1 \
   || curl -sfm 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${BACKEND_PORT}/" 2>&1 | grep -qE '^(200|404|301|302)$'; then
    log "Backend responds on :${BACKEND_PORT} ✓"
else
    printf '\033[1;33mWARN: backend not responding on :%s. nginx will 502 until you start PM2.\033[0m\n' "$BACKEND_PORT"
fi

# --------------------------------------------------------------------------
# 3. Drop the nginx site config and enable it
# --------------------------------------------------------------------------
[[ -f "$NGINX_SRC" ]] || die "Missing $NGINX_SRC — SCP the whole deploy/ folder."

log "Installing nginx config → $NGINX_DST"
cp -f "$NGINX_SRC" "$NGINX_DST"
ln -sf "$NGINX_DST" "$NGINX_LINK"

# Remove default nginx welcome site so it doesn't catch requests first.
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    log "Removed default nginx site"
fi

log "Testing nginx config"
nginx -t

log "Reloading nginx"
systemctl reload nginx || systemctl restart nginx
systemctl enable nginx >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
# 4. Sanity-check DNS — certbot's HTTP-01 challenge will hit port 80 of
#    whatever IP DOMAIN resolves to.
# --------------------------------------------------------------------------
RESOLVED=$(dig +short A "$DOMAIN" | tail -n1 || true)
VPS_IP=$(curl -s4 https://api.ipify.org || true)
log "DNS check: $DOMAIN → ${RESOLVED:-<empty>}  (this VPS: ${VPS_IP:-<unknown>})"
if [[ -z "$RESOLVED" ]]; then
    die "$DOMAIN has no A record. In Cloudflare add: A api → $VPS_IP, proxy DNS only (grey cloud)."
fi
if [[ -n "$VPS_IP" && "$RESOLVED" != "$VPS_IP" ]]; then
    cat <<EOF
\033[1;33mWARN: $DOMAIN resolves to $RESOLVED but this VPS is $VPS_IP.
If you have Cloudflare set to 'Proxied' (orange cloud), flip it to 'DNS only'
(grey cloud) so certbot can reach the VPS directly, then re-run.
You can flip it back to Proxied after the cert is issued.\033[0m
EOF
fi

# --------------------------------------------------------------------------
# 5. Get / renew the cert via the nginx plugin. --redirect adds an 80→443
#    server block automatically.
# --------------------------------------------------------------------------
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    log "Cert already exists for $DOMAIN — running renewal dry-run"
    certbot renew --dry-run
else
    log "Requesting Let's Encrypt cert for $DOMAIN"
    certbot --nginx \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --email "$ADMIN_EMAIL" \
        --redirect \
        --no-eff-email
fi

# --------------------------------------------------------------------------
# 6. Make sure auto-renew is wired up (certbot package installs a systemd
#    timer on Debian/Ubuntu by default; we just verify).
# --------------------------------------------------------------------------
if systemctl list-timers --all | grep -q certbot; then
    log "Auto-renew timer active ✓"
    systemctl list-timers certbot.timer --no-pager || true
else
    printf '\033[1;33mWARN: no certbot systemd timer found. Add a cron:\n  0 3 * * * certbot renew --quiet\033[0m\n'
fi

# --------------------------------------------------------------------------
# 7. Done — verify end-to-end
# --------------------------------------------------------------------------
log "Smoke test"
set +e
curl -sf -o /dev/null -w 'HTTPS GET /  → %{http_code}\n' "https://${DOMAIN}/"
curl -sf -o /dev/null -w 'HTTPS GET /_nginx_health → %{http_code}\n' "https://${DOMAIN}/_nginx_health"
set -e

cat <<EOF

\033[1;32mDone.\033[0m  API is now live at: https://${DOMAIN}

Next:
  1. Set APP_BASE_URL=https://${DOMAIN} in /var/www/tchipa-api/.env
  2. pm2 restart tchipa-api
  3. The Flutter client already points at https://${DOMAIN} (lib/main.dart)
EOF
