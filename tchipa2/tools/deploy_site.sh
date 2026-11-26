#!/usr/bin/env bash
# Pushes tchipa2/site/ (index.html, products.json, logo) to tchipa2.tchipa.co.uk.
# Run after build_catalog.py or any edit of the page. The VPS has no rsync → tar | ssh.
set -euo pipefail
cd "$(dirname "$0")/../site"
tar czf - . | ssh root@76.13.255.239 'mkdir -p /var/www/tchipa2-site && tar xzf - -C /var/www/tchipa2-site --no-same-owner && chmod -R a+rX /var/www/tchipa2-site'
echo "OK — https://tchipa2.tchipa.co.uk/"
