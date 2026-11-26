#!/usr/bin/env bash
# One-time setup of tchipa2.tchipa.co.uk on the VPS (idempotent). Run as root,
# AFTER the DNS A record tchipa2 → 76.13.255.239 exists:
#   scp backend/deploy/tchipa2-site.conf backend/deploy/setup-tchipa2-site.sh root@76.13.255.239:/tmp/
#   ssh root@76.13.255.239 bash /tmp/setup-tchipa2-site.sh
set -euo pipefail
DOMAIN=tchipa2.tchipa.co.uk
CONF=/etc/nginx/sites-available/tchipa2-site.conf

mkdir -p /var/www/tchipa2-site
if [ ! -f "$CONF" ]; then
    install -m 644 "$(dirname "$0")/tchipa2-site.conf" "$CONF"
fi
ln -sf "$CONF" /etc/nginx/sites-enabled/tchipa2-site.conf
nginx -t
systemctl reload nginx
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect --keep-until-expiring \
    --register-unsafely-without-email
echo "OK — https://$DOMAIN"
