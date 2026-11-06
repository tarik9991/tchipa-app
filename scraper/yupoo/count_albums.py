#!/usr/bin/env python3
"""Quick count of albums per Yupoo store/category (listing pages only)."""
import re, sys, time
from urllib.parse import urljoin, urlparse
import requests
from bs4 import BeautifulSoup

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

def count(url):
    u = urlparse(url if '://' in url else 'https://' + url)
    root = f'{u.scheme}://{u.netloc}'
    start = url if u.path not in ('', '/') else root + '/albums'
    s = requests.Session()
    s.headers.update({'User-Agent': UA, 'Referer': root + '/'})
    seen, page = set(), 0
    while page < 500:
        page += 1
        sep = '&' if '?' in start else '?'
        r = s.get(f'{start}{sep}page={page}', timeout=30)
        if r.status_code != 200:
            print(f'  ! HTTP {r.status_code} page {page}', file=sys.stderr)
            break
        soup = BeautifulSoup(r.text, 'html.parser')
        links = soup.select('a.album__main, a.album3__main') or soup.select('a[href*="/albums/"]')
        new = 0
        for a in links:
            m = re.search(r'/albums/(\d+)', a.get('href', ''))
            if m and m.group(1) not in seen:
                seen.add(m.group(1)); new += 1
        if not new:
            break
        time.sleep(0.6)
    return len(seen)

for url in sys.argv[1:]:
    n = count(url)
    print(f'{n:6d} albums  {url}')
