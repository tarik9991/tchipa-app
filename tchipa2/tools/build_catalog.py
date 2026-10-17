#!/usr/bin/env python3
"""Build the Tchipa 2 catalogue bundled in the APK.

Input : scraper/yupoo/apify_csv/<store>.json — Apify yupoo-catalog datasets
        (refresh with tools/fetch_apify.py).
Output: assets/catalog/products.json

Photos are NOT bundled: the app loads them from photo.yupoo.com
(`https://photo.yupoo.com/<store>/<hash>/{small,medium}.jpg`, Referer
required). Only the final USD price ships in the APK — never the supplier
CNY price (an APK is a zip, anyone can read its assets).

Usage (from tchipa2/):  python3 tools/build_catalog.py
"""
import json
import re
from pathlib import Path

# ============ PRICING ============
CNY_PER_USD = 7     # 1 USD = ~7 CNY
FIXED_FEE = 17      # $ added to the converted price
MULTIPLIER = 2      # price_usd = (cny / CNY_PER_USD + FIXED_FEE) * MULTIPLIER

MAX_PHOTOS = 5

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT.parent / 'scraper' / 'yupoo' / 'apify_csv'
OUT = ROOT / 'assets' / 'catalog' / 'products.json'
SITE_OUT = ROOT.parent / 'website' / 'tchipa2' / 'products.json'   # tchipa.co.uk/tchipa2/

# store -> fallback category when no keyword matches. Stores not listed are
# skipped (samluxuryfactory albums are mixed-product category albums whose
# "price" is actually a photo count).
STORES = {
    'tianjin-no1': 'Sneakers',
    'tmf001': 'Sneakers',
    'repsmaster': 'Sneakers',
    'oraclothing': 'T-shirts & Polos',
    'pandavault': 'Vestes & Doudounes',
    'cutykids': 'Enfants',
}

# First match wins. Matched against the raw title (lowercased).
CATEGORY_KEYWORDS = [
    ('Enfants', r'\bkids?\b|children|child|baby|bébé|童'),
    ('Maillots', r'jersey|\bx?s-[234]?xl\b|球衣|队'),
    ('Sacs', r'\bbag\b|keepall|tote|backpack|wallet|purse|handbag|包'),
    ('Vestes & Doudounes', r'jacket|\bdown\b|puffer|parka|coat|moncler|canada goose|\bvest\b|gilet|羽绒|外套'),
    ('Sweats & Hoodies', r'hoodie|sweatshirt|sweater|crewneck|cardigan|knit|zip-up|卫衣|毛衣'),
    ('T-shirts & Polos', r't-shirt|\btee\b|polo|shirt|短袖'),
    ('Pantalons & Shorts', r'\bpants?\b|trouser|jeans?|\bshorts\b|jogger|overalls|裤'),
    ('Sneakers', r'sneaker|shoe|air force|air max|kobe|nike|p-6000|\bnb\s?\d|\bad\b|\bboots?\b|slide|jordan|\baj\s?\d|af-?1|dunk|yeezy|new balance|asics|samba|鞋'),
    ('Accessoires', r'\bcap\b|\bhat\b|beanie|belt|scarf|sunglass|socks|bracelet|necklace|帽|围巾'),
]

# Chinese -> French glossary, applied longest-first before CJK is stripped.
GLOSSARY = {
    '巴黎世家': ' Balenciaga ', '芬迪': ' Fendi ', '古驰': ' Gucci ', '普拉达': ' Prada ',
    '迪奥': ' Dior ', '香奈儿': ' Chanel ', '路易威登': ' Louis Vuitton ', '爱马仕': ' Hermès ',
    '麦昆': ' McQueen ', '范思哲': ' Versace ', '圣罗兰': ' Saint Laurent ', '巴宝莉': ' Burberry ',
    '博柏利': ' Burberry ', '蒙口': ' Moncler ', '加拿大鹅': ' Canada Goose ', '始祖鸟': ' Arc\'teryx ',
    '勃肯': ' Birkenstock ', '科比': ' Kobe ', '乔丹': ' Jordan ', '乔': ' Jordan ', '詹姆斯': ' LeBron ',
    '欧文': ' Kyrie ', '莫兰特': ' Ja Morant ', '杜兰特': ' KD ', '库里': ' Curry ', '东契奇': ' Luka ',
    '耐克': ' Nike ', '阿迪达斯': ' Adidas ', '阿迪': ' Adidas ', '新百伦': ' New Balance ',
    '亚瑟士': ' Asics ', '匡威': ' Converse ', '万斯': ' Vans ', '彪马': ' Puma ', '安踏': ' Anta ',
    '李宁': ' Li-Ning ', '萨洛蒙': ' Salomon ', '昂跑': ' On ', '霍卡': ' Hoka ', '椰子': ' Yeezy ',
    '藤原浩': ' Fragment ', '小脏鞋': ' Superstar ', '老爹鞋': ' dad shoes ', '按摩鞋': ' Mind ',
    '童鞋': ' enfant ', '儿童': ' enfant ', '高帮': ' montante ', '中帮': ' mi-montante ', '低帮': ' basse ',
    '联名': ' collab ', '厚底': ' semelle épaisse ', '拖鞋': ' claquettes ', '凉鞋': ' sandales ',
    '篮球鞋': ' basket ', '跑鞋': ' running ', '足球鞋': ' foot ', '板鞋': ' skate ', '球衣': ' maillot ',
    '加毛': ' fourrée ', '全包': ' fermée ', '皮面': ' cuir ', '麂皮': ' daim ', '漆皮': ' verni ',
    '刺客': ' Mercurial ', '特价': ' promo ', '复古': ' rétro ', '初代': ' OG ', '一代': ' 1 ', '二代': ' 2 ',
    '三代': ' 3 ', '四代': ' 4 ', '五代': ' 5 ', '六代': ' 6 ', '七代': ' 7 ', '八代': ' 8 ', '九代': ' 9 ',
    '男款': ' homme ', '女款': ' femme ', '情侣': ' unisexe ', '黑武士': ' triple black ',
    '熊猫': ' panda ', '黑曜石': ' obsidian ', '芝加哥': ' Chicago ', '摩卡': ' mocha ', '山茶花': ' camélia ',
    '湖人': ' Lakers ', '巴西队': ' Brésil ', '阿根廷': ' Argentine ', '法国': ' France ',
    '藏青': ' marine ', '酒红': ' bordeaux ', '军绿': ' kaki ', '卡其': ' kaki ', '奶白': ' crème ',
    '米白': ' beige ', '浅灰': ' gris clair ', '深灰': ' gris foncé ', '深蓝': ' bleu nuit ', '浅蓝': ' bleu ciel ',
    '黑': ' noir ', '白': ' blanc ', '灰': ' gris ', '红': ' rouge ', '蓝': ' bleu ', '绿': ' vert ',
    '粉': ' rose ', '黄': ' jaune ', '紫': ' violet ', '棕': ' marron ', '米': ' beige ', '橙': ' orange ',
    '银': ' argent ', '金': ' or ', '咖': ' café ', '沙': ' sable ',
}
GLOSSARY_RE = re.compile('|'.join(sorted(map(re.escape, GLOSSARY), key=len, reverse=True)))
COLORS = 'noir|blanc|gris|rouge|bleu|vert|rose|jaune|violet|marron|beige|orange|argent|or|café|sable|marine|bordeaux|kaki|crème'
COLOR_RUN = re.compile(rf'\b(?:{COLORS})(?:\s+(?:{COLORS})\b)+')

CATEGORY_NAMES = {name for name, _ in CATEGORY_KEYWORDS} | set(STORES.values())

CJK = re.compile(r'[　-〿㐀-鿿＀-￯]+')
PRICE_IN_TITLE = re.compile(r'【\s*(\d+)\s*(?:RMB|Y|yuan|元)[^】]*】|^\s*P?(\d+)\s*(?:Y|RMB|yuan)?\b', re.I)
STYLE_CODE = re.compile(r'\b([A-Z]{1,3}\d{3,5}-\d{3})')
PHOTO = re.compile(r'https://photo\.yupoo\.com/[^/]+/([0-9a-f]+)/')


def price_usd(cny: float) -> float:
    return round((cny / CNY_PER_USD + FIXED_FEE) * MULTIPLIER, 2)


def parse_cny(item) -> float | None:
    if item.get('priceCny'):
        return float(item['priceCny'])
    m = PRICE_IN_TITLE.search(item['title'])
    return float(next(g for g in m.groups() if g)) if m else None


def strip_count(title: str, count) -> str:
    # The scraper glues the album's photo count to the title ("Set8",
    # "CT8013-0109"); Apify's photoCount is that number or twice it.
    title = title.rstrip()
    n = int(count or 0)
    for c in sorted({str(n), str(n // 2), str((n + 1) // 2)} - {'0'}, key=len, reverse=True):
        if title.endswith(c):
            return title[:-len(c)]
    return title


def clean_title(title: str) -> str:
    t = re.sub(r'(?:^|(?<=\s)|(?<=】))\d+_', ' ', title)    # "6_" album index
    t = re.sub(r'【[^】]*】', ' ', t)                  # 【600RMB】【LJR】…
    t = re.sub(r'^\s*P?\d+\s*(?:Y|RMB|yuan)?\b\.?', '', t, flags=re.I)  # P170 / 150Y / "425."
    t = re.sub(r'[¥￥]\s*\d+', ' ', t)
    t = re.sub(r'[\[(]\s*\d+\s*RMB[^)\]]*[)\]]|\(\s*[A-Z]{1,3}\s*\)', ' ', t, flags=re.I)  # [160RMB/$24.06) (PH )
    t = t.replace('（', ' ').replace('）', ' ')
    t = re.sub(r'\b(?:TOP|WZ|BD|GX|D1)?\s*Batch\b|版', ' ', t, flags=re.I)
    t = re.sub(r'\b[a-z]+\d*_\d+_', ' ', t, flags=re.I)        # "yolo66_246307036_"
    t = re.sub(r'\b\d+\s*(?:Y|yuan)\b', ' ', t, flags=re.I)    # "330Y"
    t = re.sub(r'\d+\s*RMB\s*(?:/\s*\$\s*[\d.]+)?|\$\s*[\d.]+', ' ', t, flags=re.I)  # supplier prices
    t = re.sub(r'\b(?:PH|PE|PB|PK)(?:Batch)?\b|[\[\]()]', ' ', t)                  # factory tags, brackets
    t = STYLE_CODE.sub(' ', t)                         # shown separately
    t = GLOSSARY_RE.sub(lambda m: GLOSSARY[m.group(0)], t)
    t = re.sub(r'\[[A-Z]{1,3}\]', ' ', t)              # [G]
    t = re.sub(r'\b[A-Z]?\d{2,3}\b(?=\s+[A-Z][a-z])', ' ', t)  # internal refs like M255
    t = CJK.sub(' ', t)
    t = re.sub(r'\s+', ' ', t).strip(' -—,.|·/!_')
    t = COLOR_RUN.sub(lambda m: '/'.join(m.group(0).split()), t)
    if len(t) > 70 and '.' in t[:70]:                  # long supplier blurbs: first sentence
        t = t.split('.')[0]
    return t[:80].strip(' -—,.')


SHOE_STORES = {'tianjin-no1', 'tmf001', 'repsmaster'}


def category(store: str, title: str) -> str:
    low = title.lower()
    if store == 'cutykids':
        return 'Enfants'
    rules = CATEGORY_KEYWORDS
    if store in SHOE_STORES:   # shoe stores: everything is footwear unless it says kids/jersey
        rules = [r for r in CATEGORY_KEYWORDS if r[0] in ('Enfants', 'Maillots')]
    for name, pat in rules:
        if re.search(pat, low):
            return name
    if store == 'pandavault' and STYLE_CODE.search(title):   # mixed store: style codes are shoes
        return 'Sneakers'
    return STORES[store]


def photo_hashes(photos) -> list[str]:
    out = []
    for p in photos or []:
        m = PHOTO.match(p)
        if m and m.group(1) not in out:
            out.append(m.group(1))
    return out[:MAX_PHOTOS]


def main():
    products, seen = [], set()
    for store in STORES:
        path = SRC / f'{store}.json'
        if not path.exists():
            print(f'skip {store}: {path} manquant')
            continue
        kept = 0
        for item in json.loads(path.read_text(encoding='utf-8')):
            aid = str(item.get('albumId', '')).strip()
            raw = strip_count((item.get('title') or '').strip(), item.get('photoCount'))
            if not aid or aid in seen:
                continue
            if re.search(r'\d+\s*Y\s*-\s*\d+\s*Y|whatsapp|payment|how to order|hoobuy|superbuy|feedback|review|\bQC\b', raw, re.I):
                continue
            # The album's own photo count is glued to the title; 61+ photos
            # ("DUNK566", "GUCCI 65") means a whole-collection album, not a product.
            m = re.search(r'(?<![\d-])(\d{2,3})$', (item.get('title') or '').strip())
            if m and int(m.group(1)) > 60:
                continue
            cny = parse_cny({'priceCny': item.get('priceCny'), 'title': raw})
            name = clean_title(raw)
            m = STYLE_CODE.search(raw)
            code = m.group(1) if m else ''
            if not re.search(r'[A-Za-zÀ-ÿ]{3}', COLOR_RUN.sub('', re.sub(rf'\\b(?:{COLORS})\\b', '', name))):  # nothing but colors/numbers left
                name = f'{STORES[store] if store != "cutykids" else "Enfants"} {name}'.strip()
            photos = photo_hashes(item.get('photos'))
            if not cny or cny < 20 or not name or not photos:
                continue
            seen.add(aid)
            products.append({
                'id': aid,
                't': name,
                'c': category(store, raw),
                'p': price_usd(cny),
                's': store,
                'i': photos,
                **({'code': code} if code else {}),
            })
            kept += 1
        print(f'{store}: {kept} produits')

    # Named products first ("Jordan 12 noir/rouge" before a bare "Sneakers"),
    # store order kept otherwise (sort is stable).
    products.sort(key=lambda p: p['t'] in CATEGORY_NAMES or p['t'].split()[0] in CATEGORY_NAMES)
    data = json.dumps(products, ensure_ascii=False, separators=(',', ':'))
    for out in (OUT, SITE_OUT):
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(data, encoding='utf-8')
    cats = {}
    for p in products:
        cats[p['c']] = cats.get(p['c'], 0) + 1
    print(f'TOTAL {len(products)} produits, {OUT.stat().st_size / 1e6:.1f} Mo')
    print(dict(sorted(cats.items(), key=lambda kv: -kv[1])))


if __name__ == '__main__':
    main()
