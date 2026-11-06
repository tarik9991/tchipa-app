#!/usr/bin/env python3
"""Yupoo gallery scraper for Tchipa 2.

Walks every album of a Yupoo store (https://<store>.x.yupoo.com), pulls the
album title, isolates a Yuan price when the title carries one, downloads all
photos into one folder per product and writes catalogue.csv in the format
read by backend/import_yupoo.js.

    pip install requests beautifulsoup4
    python3 yupoo_scraper.py https://<store>.x.yupoo.com --out ./yupoo_data
    python3 yupoo_scraper.py https://<store>.x.yupoo.com/categories/123 --max-albums 20

Re-running is incremental: albums already in catalogue.csv with every photo on
disk are skipped, so an interrupted run can just be started again.
"""
import argparse
import csv
import os
import re
import sys
import time
from urllib.parse import parse_qs, urljoin, urlparse

import requests
from bs4 import BeautifulSoup

USER_AGENT = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0 Safari/537.36')
DELAY_S = 1.0            # between page requests: Yupoo bans aggressive IPs
MAX_PAGES = 500          # safety stop for the album list
MAX_PHOTOS = 30          # per album
CSV_NAME = 'catalogue.csv'
CSV_COLUMNS = ['album_id', 'title', 'price_cny', 'category', 'album_url',
               'cover', 'images', 'photo_count']

# Price in the title, most explicit first. "P" prefix and 3-digit fallback are
# common Yupoo seller conventions ("P158 Nike ...", "Robe 💰168").
PRICE_PATTERNS = [
    re.compile(r'[¥￥]\s*(\d{2,5}(?:\.\d{1,2})?)'),
    re.compile(r'(\d{2,5}(?:\.\d{1,2})?)\s*(?:¥|￥|元|RMB|rmb|CNY|yuan)'),
    re.compile(r'(?<![A-Za-z0-9])[Pp]\s*(\d{2,5})(?!\d)'),
    re.compile(r'💰\s*(\d{2,5})'),
    re.compile(r'(?<![\d.\-/:#xX])(\d{3})(?![\d.\-/:%xX])'),   # bare 3-digit number
]


def extract_price(title):
    """Return (price_cny or None, title without the price token)."""
    for pat in PRICE_PATTERNS:
        m = pat.search(title)
        if m:
            clean = (title[:m.start()] + title[m.end():]).strip(' -_|,;:/')
            return float(m.group(1)), re.sub(r'\s{2,}', ' ', clean) or title
    return None, title


def safe_name(s, n=60):
    s = re.sub(r'[\\/:*?"<>|\x00-\x1f]', '_', s).strip(' .')
    return s[:n] or 'album'


class Yupoo:
    def __init__(self, base):
        u = urlparse(base if '://' in base else 'https://' + base)
        self.root = f'{u.scheme}://{u.netloc}'
        self.start = base if u.path not in ('', '/') else self.root + '/albums'
        self.s = requests.Session()
        self.s.headers.update({'User-Agent': USER_AGENT, 'Referer': self.root + '/',
                               'Accept-Language': 'en,zh;q=0.8'})

    def get(self, url, **kw):
        for attempt in range(4):
            try:
                r = self.s.get(url, timeout=30, **kw)
                if r.status_code == 200:
                    return r
                if r.status_code in (403, 404):
                    print(f'  ! HTTP {r.status_code} {url}', file=sys.stderr)
                    return None
            except requests.RequestException as e:
                print(f'  ! {e.__class__.__name__} {url}', file=sys.stderr)
            time.sleep(3 * (attempt + 1))
        return None

    def page_url(self, page):
        sep = '&' if '?' in self.start else '?'
        return f'{self.start}{sep}page={page}'

    def list_albums(self):
        """Yield (album_id, title, url) for every album, page after page."""
        seen = set()
        for page in range(1, MAX_PAGES + 1):
            r = self.get(self.page_url(page))
            if not r:
                return
            soup = BeautifulSoup(r.text, 'html.parser')
            # New layout: a.album__main ; old one: a.album3__main
            links = soup.select('a.album__main, a.album3__main') or \
                soup.select('a[href*="/albums/"]')
            new = 0
            for a in links:
                href = a.get('href', '')
                m = re.search(r'/albums/(\d+)', href)
                if not m or m.group(1) in seen:
                    continue
                seen.add(m.group(1))
                new += 1
                t = a.get('title') or ''
                if not t:
                    el = a.select_one('.album__title, .album3__title, .text_overflow')
                    t = el.get_text(' ', strip=True) if el else ''
                yield m.group(1), t.strip(), urljoin(self.root, href)
            print(f'[liste] page {page}: {new} albums', file=sys.stderr)
            if not new:      # past the last page Yupoo repeats the last one or shows none
                return
            time.sleep(DELAY_S)

    def album_photos(self, url):
        """Return (title, [absolute photo urls]) for one album."""
        r = self.get(url)
        if not r:
            return None, []
        soup = BeautifulSoup(r.text, 'html.parser')
        h = soup.select_one('.showalbum__headerTitle, .showalbumheader__gallerytitle, h1')
        title = h.get_text(' ', strip=True) if h else ''
        urls = []
        for img in soup.select('.showalbum__children img, .image__imagewrap img, img.autocover'):
            src = img.get('data-origin-src') or img.get('data-src') or img.get('src') or ''
            if 'photo.yupoo.com' not in src:
                continue
            src = urljoin('https:', src)
            # medium/small thumbnails -> full size
            src = re.sub(r'/(small|medium|square|thumb)\.(jpe?g|png|webp)$', r'/big.\2', src)
            if src not in urls:
                urls.append(src)
        return title, urls[:MAX_PHOTOS]

    def download(self, url, path):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return True
        r = self.get(url)
        if not r or not r.headers.get('Content-Type', '').startswith('image'):
            return False
        tmp = path + '.part'
        with open(tmp, 'wb') as f:
            f.write(r.content)
        os.replace(tmp, path)
        return True


def load_done(csv_path):
    if not os.path.exists(csv_path):
        return {}
    with open(csv_path, newline='', encoding='utf-8') as f:
        return {row['album_id']: row for row in csv.DictReader(f)}


def write_csv(csv_path, rows):
    tmp = csv_path + '.part'
    with open(tmp, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        w.writeheader()
        w.writerows(rows.values())
    os.replace(tmp, csv_path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('url', help='store, /albums or /categories/<id> URL')
    ap.add_argument('--out', default='yupoo_data')
    ap.add_argument('--category', default='', help='category stored in the CSV (e.g. Femme)')
    ap.add_argument('--max-albums', type=int, default=0, help='0 = all')
    args = ap.parse_args()

    y = Yupoo(args.url)
    store = urlparse(y.root).netloc.split('.')[0]
    out = os.path.join(args.out, store)
    os.makedirs(out, exist_ok=True)
    csv_path = os.path.join(out, CSV_NAME)
    rows = load_done(csv_path)

    count = 0
    for album_id, list_title, url in y.list_albums():
        if args.max_albums and count >= args.max_albums:
            break
        count += 1
        done = rows.get(album_id)
        if done and all(os.path.exists(os.path.join(out, p)) for p in done['images'].split('|') if p):
            continue
        title, photos = y.album_photos(url)
        title = title or list_title
        if not photos:
            print(f'[{album_id}] aucune photo, ignoré', file=sys.stderr)
            continue
        price, _ = extract_price(title)
        folder = f'{album_id}_{safe_name(title, 40)}'
        os.makedirs(os.path.join(out, folder), exist_ok=True)
        saved = []
        for i, src in enumerate(photos, 1):
            ext = os.path.splitext(urlparse(src).path)[1] or '.jpg'
            rel = f'{folder}/{i:02d}{ext}'
            if y.download(src, os.path.join(out, rel)):
                saved.append(rel)
            time.sleep(DELAY_S / 4)
        if not saved:
            continue
        rows[album_id] = {
            'album_id': album_id, 'title': title,
            'price_cny': '' if price is None else f'{price:g}',
            'category': args.category or (parse_qs(urlparse(url).query).get('referrercate', [''])[0]),
            'album_url': url.split('?')[0], 'cover': saved[0], 'images': '|'.join(saved),
            'photo_count': len(saved),
        }
        write_csv(csv_path, rows)       # after each album: a crash loses nothing
        print(f'[{album_id}] {len(saved)} photos, prix {price if price is not None else "?"} ¥ — {title[:60]}')
        time.sleep(DELAY_S)

    print(f'\n{len(rows)} produits dans {csv_path}')


if __name__ == '__main__':
    main()
