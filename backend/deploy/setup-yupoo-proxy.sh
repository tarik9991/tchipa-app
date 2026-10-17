#!/usr/bin/env bash
# Installs the Yupoo photo relay on the VPS (idempotent). Run as root:
#   scp backend/deploy/yupoo-proxy.conf backend/deploy/setup-yupoo-proxy.sh root@76.13.255.239:/tmp/
#   ssh root@76.13.255.239 bash /tmp/setup-yupoo-proxy.sh
set -euo pipefail

SITE=/etc/nginx/sites-available/tchipa-api.conf
SNIPPET=/etc/nginx/snippets/yupoo-proxy.conf
CACHE_CONF=/etc/nginx/conf.d/yupoo-cache.conf

install -m 644 "$(dirname "$0")/yupoo-proxy.conf" "$SNIPPET"

# 2 GB on-disk cache, entries dropped after 30 days without a hit.
mkdir -p /var/cache/nginx/yupoo
chown www-data: /var/cache/nginx/yupoo 2>/dev/null || true
echo 'proxy_cache_path /var/cache/nginx/yupoo levels=1:2 keys_zone=yupoo:20m max_size=2g inactive=30d use_temp_path=off;' > "$CACHE_CONF"

if ! grep -q 'snippets/yupoo-proxy.conf' "$SITE"; then
    cp "$SITE" "$SITE.bak-yupoo"
    # Insert the include before "location / {" of the server block that listens on 443.
    python3 - "$SITE" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
blocks = re.split(r'(?=^server\s*\{)', s, flags=re.M)
for i, b in enumerate(blocks):
    if 'listen 443' in b and 'location / {' in b:
        blocks[i] = b.replace('location / {', 'include snippets/yupoo-proxy.conf;\n\n    location / {', 1)
        break
else:
    sys.exit('no 443 server block with "location / {" found')
open(p, 'w').write(''.join(blocks))
PY
fi

if nginx -t; then
    systemctl reload nginx
    echo "OK — test: curl -sI https://api.tchipa.co.uk/yupoo/tmf001/408ce7e654/small.jpg"
else
    echo "nginx -t a échoué — restauration" >&2
    [ -f "$SITE.bak-yupoo" ] && cp "$SITE.bak-yupoo" "$SITE"
    rm -f "$CACHE_CONF"
    nginx -t && systemctl reload nginx
    exit 1
fi
