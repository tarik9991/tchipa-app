#!/usr/bin/env python3
"""Download the yupoo-catalog Apify datasets (metadata only, no photos).

Writes scraper/yupoo/apify_csv/<store>.json and <store>.csv. The token is read
from scraper/apify-actor/.env (APIFY_TOKEN=…) and never printed.

Usage (from tchipa2/):  python3 tools/fetch_apify.py
Then:                   python3 tools/build_catalog.py
"""
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV = ROOT / 'scraper' / 'apify-actor' / '.env'
OUT = ROOT / 'scraper' / 'yupoo' / 'apify_csv'

# store -> Apify run id (latest successful yupoo-catalog run per store)
RUNS = {
    'tianjin-no1': 'WoxpYJl8urX3crRO8',
    'cutykids': 'zb1l0LT3c1Gjwf9vy',
    'samluxuryfactory': 'rKH6Z84ZQHhmcgANl',
    'pandavault': 'EI1HgNRYHMCkMlEtB',
    'oraclothing': 'HJ0bZE6xgXOkGmoPb',
    'repsmaster': 'JAm110VYghgm2dqFy',
    'tmf001': 'EOgE0bKJBBbgt7dUe',
}


def token() -> str:
    for line in ENV.read_text().splitlines():
        if line.startswith('APIFY_TOKEN='):
            return line.split('=', 1)[1].strip()
    raise SystemExit(f'APIFY_TOKEN absent de {ENV}')


def get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=300) as r:
        return r.read()


def main():
    tok = token()
    OUT.mkdir(parents=True, exist_ok=True)
    for store, run in RUNS.items():
        meta = json.loads(get(f'https://api.apify.com/v2/actor-runs/{run}?token={tok}'))['data']
        ds = meta['defaultDatasetId']
        for fmt in ('json', 'csv'):
            data = get(f'https://api.apify.com/v2/datasets/{ds}/items?format={fmt}&clean=1&token={tok}')
            (OUT / f'{store}.{fmt}').write_bytes(data)
        n = len(json.loads((OUT / f'{store}.json').read_text(encoding='utf-8')))
        print(f'{store}: {n} albums ({meta["status"]})')


if __name__ == '__main__':
    main()
