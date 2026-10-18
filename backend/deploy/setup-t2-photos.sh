#!/usr/bin/env bash
# Serves the Tchipa 2 photos stored on the VPS (idempotent). Run as root:
#   scp backend/deploy/t2-photos.conf backend/deploy/setup-t2-photos.sh root@76.13.255.239:/tmp/
#   ssh root@76.13.255.239 bash /tmp/setup-t2-photos.sh
# The photo tree itself is built by tchipa2/tools/vps_photos.cjs.
set -euo pipefail

SITE=/etc/nginx/sites-available/tchipa-api.conf
SNIPPET=/etc/nginx/snippets/t2-photos.conf

install -m 644 "$(dirname "$0")/t2-photos.conf" "$SNIPPET"

if ! grep -q 'snippets/t2-photos.conf' "$SITE"; then
    cp "$SITE" "$SITE.bak-t2"
    # Insert the include before "location / {" of the server block that listens on 443.
    python3 - "$SITE" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
blocks = re.split(r'(?=^server\s*\{)', s, flags=re.M)
for i, b in enumerate(blocks):
    if 'listen 443' in b and 'location / {' in b:
        blocks[i] = b.replace('location / {', 'include snippets/t2-photos.conf;\n\n    location / {', 1)
        break
else:
    sys.exit('no 443 server block with "location / {" found')
open(p, 'w').write(''.join(blocks))
PY
fi

if nginx -t; then
    systemctl reload nginx
    echo "OK — test: curl -sI https://api.tchipa.co.uk/t2/<store>/<albumId>/s.webp"
else
    echo "nginx -t a échoué — restauration" >&2
    [ -f "$SITE.bak-t2" ] && cp "$SITE.bak-t2" "$SITE"
    rm -f "$SNIPPET"
    nginx -t && systemctl reload nginx
    exit 1
fi
