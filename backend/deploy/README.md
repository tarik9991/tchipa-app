# Tchipa API — HTTPS deploy

One-time setup to put the backend behind `https://api.tchipa.co.uk` instead of
the raw `http://76.13.255.239:3000`. Required for iOS (App Transport Security
blocks cleartext) and a good idea for Android too.

Architecture after setup:

```
client (Flutter / browser)
        │
        │ HTTPS  443
        ▼
┌────────────────────┐
│  nginx on VPS      │  ← Let's Encrypt cert, auto-renew via certbot.timer
│  api.tchipa.co.uk  │
└────────┬───────────┘
         │ HTTP  127.0.0.1:3000   (loopback only — never exposed)
         ▼
┌────────────────────┐
│  Node.js (PM2)     │  tchipa-api process
│  /var/www/tchipa-api │
└────────────────────┘
```

---

## Step 1 — Cloudflare DNS

Add this record in the Cloudflare dashboard for `tchipa.co.uk`:

| Type | Name | Content        | Proxy status        | TTL  |
|------|------|----------------|---------------------|------|
| A    | api  | 76.13.255.239  | **DNS only** (grey) | Auto |

> **Important**: keep it grey-cloud (DNS only) during the certbot run.
> The HTTP-01 challenge hits port 80 directly on the VPS; if Cloudflare's
> proxy is in front, the challenge will fail. After the cert is issued you can
> flip to orange-cloud (Proxied) if you want CF protection — see Step 4.

Wait ~30 s, then verify from your laptop:

```bash
dig +short A api.tchipa.co.uk
# → 76.13.255.239
```

## Step 2 — Copy the deploy folder to the VPS

```bash
scp -r backend/deploy root@76.13.255.239:/tmp/tchipa-deploy
```

## Step 3 — Run the setup script

```bash
ssh root@76.13.255.239
ADMIN_EMAIL=you@example.com bash /tmp/tchipa-deploy/setup-https.sh
```

The script is idempotent — safe to re-run. It will:

1. `apt install nginx certbot python3-certbot-nginx`
2. Drop `nginx-api.conf` into `/etc/nginx/sites-{available,enabled}/`
3. Test + reload nginx
4. Sanity-check that DNS resolves to this VPS
5. Run `certbot --nginx -d api.tchipa.co.uk --redirect` to get the cert
   and add the 80→443 redirect to the nginx config in-place
6. Verify `certbot.timer` is active so renewals happen automatically every
   ~60 days

Final smoke test (the script does this for you):

```bash
curl -i https://api.tchipa.co.uk/_nginx_health   # → 200 ok
curl -i https://api.tchipa.co.uk/                # → whatever the Node app returns
```

## Step 4 — Update the backend `.env` and restart PM2

Magic-link emails embed an absolute URL. Update the env so they use the new
host:

```bash
ssh root@76.13.255.239
nano /var/www/tchipa-api/.env
#   add or update:
#   APP_BASE_URL=https://api.tchipa.co.uk

pm2 restart tchipa-api
pm2 logs tchipa-api --lines 50
```

## Step 5 — (Optional) Turn Cloudflare proxy back on

If you want Cloudflare's DDoS protection / caching:

1. In CF dashboard, switch the `api` record to **Proxied** (orange cloud).
2. In CF → SSL/TLS → Overview, set the mode to **Full (strict)**. Anything
   else either breaks the connection or leaves it half-encrypted.
3. Test: `curl -i https://api.tchipa.co.uk/_nginx_health` from outside the
   VPS. Should still return 200.

If you ever need to re-run certbot (renewals are automatic but if you ever
add a new subdomain), flip the record back to grey-cloud first.

## Step 6 — Update the Flutter client

Already done in this same commit: `lib/main.dart`'s `kVpsBase` now points at
`https://api.tchipa.co.uk`. Push to `main` triggers a new APK release via
`.github/workflows/build.yml`.

---

## Renewals

certbot installs a systemd timer (`/lib/systemd/system/certbot.timer`) that
runs twice a day and renews the cert when it has under 30 days left. No
action needed. To verify it's active:

```bash
systemctl list-timers certbot.timer
systemctl status certbot.timer
```

Manual dry-run any time:

```bash
certbot renew --dry-run
```

## Rollback

If something breaks and you need to revert to plain HTTP on `:3000`:

```bash
ssh root@76.13.255.239
rm /etc/nginx/sites-enabled/tchipa-api.conf
systemctl reload nginx
# UFW / firewall — make sure port 3000 is still open:
ufw status
```

Then in the Flutter app revert `kVpsBase` to the old IP+port and rebuild.
