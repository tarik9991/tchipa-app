#!/usr/bin/env bash
# check_apify.sh — vérifie le plan/crédit Apify et l'état des runs, sans exposer le token.
# Usage: bash check_apify.sh            -> plan + usage
#        bash check_apify.sh runs       -> derniers runs de l'acteur yupoo-catalog
set -euo pipefail
cd "$(dirname "$0")"

# charge le .env dans l'environnement du processus python (le token n'apparaît jamais dans la sortie)
python3 - <<'EOF'
import json, os, sys, urllib.request

tok = None
for line in open('.env'):
    if line.startswith('APIFY_TOKEN='):
        tok = line.split('=', 1)[1].strip()
if not tok:
    sys.exit('.env sans APIFY_TOKEN — demande à l\'utilisateur de le créer')

def api(path):
    with urllib.request.urlopen(f'https://api.apify.com/v2/{path}&token={tok}', timeout=30) as r:
        return json.load(r)['data']

me = api('users/me?limit=0')
prof = me.get('profile', {})
print('user        :', me.get('username'))
print('plan        :', prof.get('plan'))
print('usage du mois (USD):', prof.get('monthlyUsageUsd'))
print('limite plan (USD)  :', prof.get('planFeeUsd', prof.get('maxMonthlyUsageUsd')))

if len(sys.argv) > 1 and sys.argv[1] == 'runs':
    print('\n--- derniers runs ---')
    runs = api('acts/yupoo-catalog/runs?limit=5&status=SUCCEEDED,FAILED,ABORTED,RUNNING') if False else \
           api('acts~yupoo-catalog/runs?limit=5')
    # si l'acteur n'est pas poussé sur le cloud, lister les runs du compte
    try:
        for r in runs.get('data', {}).get('items', runs.get('items', [])):
            print(f"{r.get('id')}  {r.get('status'):10s}  {r.get('startedAt')}  act={r.get('actId')}")
    except Exception as e:
        print('(pas de runs listés:', e, ')')
EOF
