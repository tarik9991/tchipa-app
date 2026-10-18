#!/usr/bin/env python3
"""Cover the JMDY marks in tianjin-no1 photos with a Tchipa patch (VPS only).

Two marks, both found from their green (hue ~65-70; a teal shoe detail is ~85):
- plaque: a physical green/white "JMDY" acrylic plaque in front of the shoes,
  on the first photos of most albums. Position and size vary per photo.
- corner: a digital "JMDY KICKS / Snkrs Shoe Studio" sticker in the top-right
  corner of the RETAIL-vs-batch comparison photos.
Green shoes, grass and tables also match the colour, so every candidate is
checked against the real mark's green shape (jmdy_plaque.png / jmdy_corner.png,
normalized correlation of the green masks): real plaques score >= 0.73, the
false hits seen in a 48-photo sample <= 0.54.

Files are rewritten IN PLACE (same inode): /var/www/tchipa2-photos/... are hard
links to yupoo_data/..., so both stay identical and vps_photos.cjs keeps its
links. A patched photo no longer matches, so reruns are idempotent. When photo 1
changes, the grid cover s.webp is rebuilt.

Usage (on the VPS):
  python3 jmdy_patch.py [--dry] [--limit N] [--sample DIR]
Needs: opencv-python-headless, pillow, numpy; tchipa_logo.png, jmdy_plaque.png
and jmdy_corner.png next to this script.
"""
import argparse, io, json, os, sys
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = '/var/www/tchipa2-photos/tianjin-no1'
LOGO = os.path.join(HERE, 'tchipa_logo.png')
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
LOG = '/var/www/tchipa2-photos/jmdy_patched.json'
THUMB_WIDTH = 400
MIN_SCORE = 0.65
CORNER_MIN_SCORE = 0.55   # the sticker's place is fixed, so a looser shape check is enough (seen 0.65-0.86)

CYAN = (0, 212, 255)     # kCyan
VIOLET = (139, 92, 246)  # kViolet
BG = (13, 17, 23)        # kBg


def green(im):
    return cv2.inRange(cv2.cvtColor(im, cv2.COLOR_BGR2HSV), (58, 60, 110), (78, 255, 255))


_tpl = {}


def template(name):
    if name not in _tpl:
        _tpl[name] = cv2.imread(os.path.join(HERE, f'jmdy_{name}.png'))
    return _tpl[name]


def shape_score(im, box, name):
    """Best correlation between the green mask around box and the template's."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    H, W = im.shape[:2]
    px, py = int(w * .15), int(h * .3)
    roi = green(im[max(0, y0 - py):min(H, y1 + py), max(0, x0 - px):min(W, x1 + px)]).astype(np.float32)
    best = -1.0
    for s in (.85, .95, 1.05, 1.15):
        t = green(cv2.resize(template(name), (max(8, int(w * s)), max(4, int(h * s))))).astype(np.float32)
        if t.shape[0] > roi.shape[0] or t.shape[1] > roi.shape[1] or t.std() == 0:
            continue
        best = max(best, float(cv2.matchTemplate(roi, t, cv2.TM_CCOEFF_NORMED).max()))
    return best


def find_marks(im):
    """[(kind, (x0, y0, x1, y1))] of the JMDY marks in the photo."""
    H, W = im.shape[:2]
    hsv = cv2.cvtColor(im, cv2.COLOR_BGR2HSV)
    g = green(im)
    k = max(3, W // 120)
    gd = cv2.dilate(g, np.ones((k, k), np.uint8))
    plaque, corner = None, None
    for x, y, w, h, a in cv2.connectedComponentsWithStats(gd)[2][1:]:
        x, y, w, h = int(x), int(y), int(w), int(h)
        if w < W * 0.04 or h < H * 0.02 or w > W * 0.5 or not 1.0 < w / h < 3.5:
            continue
        # corner sticker: the green blob is the "JMDY" letters, top right
        if x > W * .6 and y + h < H * .25:
            box = (x, y, x + w, y + h)
            sc = shape_score(im, box, 'corner')
            if sc >= CORNER_MIN_SCORE and (not corner or sc > corner[0]):
                corner = (sc, (max(0, x - int(.12 * w)), max(0, y - int(.7 * h)),
                               min(W, x + int(1.12 * w)), min(H, y + int(1.95 * h))))
            continue
        # plaque: green stripes followed by the white "MDY" letters, always in
        # front of the shoes, i.e. in the lower part (seen at 0.64-0.84 of H)
        if y < H * .45:
            continue
        fill = g[y:y + h, x:x + w].mean() / 255
        if not 0.12 < fill < 0.75:
            continue
        band = hsv[y:y + h, x + w:min(W, x + int(w * 3.4))]
        if band.size == 0 or ((band[..., 1] < 60) & (band[..., 2] > 170)).mean() < 0.10:
            continue
        box = (max(0, x - int(.2 * w)), max(0, y - int(.25 * h)),
               min(W, x + int(3.45 * w)), min(H, y + int(1.3 * h)))
        sc = shape_score(im, box, 'plaque')
        if sc >= MIN_SCORE and (not plaque or sc > plaque[0]):
            plaque = (sc, box)
    return [(kind, m[1]) for kind, m in (('plaque', plaque), ('corner', corner)) if m]


def gradient(w, h):
    t = np.linspace(0, 1, w)[None, :, None]
    row = (1 - t) * np.array(CYAN) + t * np.array(VIOLET)
    return Image.fromarray(np.repeat(row, h, axis=0).astype(np.uint8), 'RGB')


_logo = None


def fit_font(text, max_w, max_h):
    size = max(6, int(max_h))
    font = ImageFont.truetype(FONT, size)
    while size > 6 and font.getbbox(text)[2] > max_w:
        size -= 2
        font = ImageFont.truetype(FONT, size)
    return font


def patch(w, h):
    """Tchipa badge of exactly w x h (RGBA): dark rounded box, gradient border,
    logo + TCHIPA side by side (wide box) or stacked (square box)."""
    global _logo
    if _logo is None:
        lg = Image.open(LOGO).convert('RGBA')
        _logo = lg.crop(lg.getchannel('A').getbbox())
    s = 3  # supersample for clean edges
    W, H = w * s, h * s
    short = min(W, H)
    r, b = short // 3, max(2 * s, short // 14)
    mask = Image.new('L', (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, W - 1, H - 1), r, fill=255)
    inner = Image.new('L', (W, H), 0)
    ImageDraw.Draw(inner).rounded_rectangle((b, b, W - 1 - b, H - 1 - b), max(1, r - b), fill=255)
    out = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    out.paste(gradient(W, H), (0, 0), mask)          # border
    out.paste(Image.new('RGB', (W, H), BG), (0, 0), inner)
    tmask = Image.new('L', (W, H), 0)
    if W >= 2 * H:   # plaque: logo left, word right
        lh = int(H * .62)
        lw = int(_logo.width * lh / _logo.height)
        pad = int(H * .22)
        out.alpha_composite(_logo.resize((lw, lh), Image.LANCZOS), (pad, (H - lh) // 2))
        tx = pad + lw + int(H * .12)
        room_w = W - tx - pad
        font = fit_font('TCHIPA', room_w, H * .5)
        bx0, by0, bx1, by1 = font.getbbox('TCHIPA')
        ImageDraw.Draw(tmask).text((tx + (room_w - (bx1 - bx0)) // 2 - bx0, (H - (by1 - by0)) // 2 - by0),
                                   'TCHIPA', font=font, fill=255)
    else:            # corner sticker: logo on top, word below
        pad = int(short * .12)
        lh = int(H * .48)
        lw = int(_logo.width * lh / _logo.height)
        if lw > W - 2 * pad:
            lw = W - 2 * pad
            lh = int(_logo.height * lw / _logo.width)
        out.alpha_composite(_logo.resize((lw, lh), Image.LANCZOS), ((W - lw) // 2, pad))
        font = fit_font('TCHIPA', W - 2 * pad, H * .22)
        bx0, by0, bx1, by1 = font.getbbox('TCHIPA')
        ty = pad + lh + (H - pad - lh - pad - (by1 - by0)) // 2
        ImageDraw.Draw(tmask).text(((W - (bx1 - bx0)) // 2 - bx0, ty - by0), 'TCHIPA', font=font, fill=255)
    out.paste(gradient(W, H), (0, 0), tmask)
    return out.resize((w, h), Image.LANCZOS)


def apply(path):
    im = cv2.imread(path)
    if im is None:
        return None
    marks = find_marks(im)
    if not marks:
        return None
    pil = Image.open(path).convert('RGB')
    for _, (x0, y0, x1, y1) in marks:
        p = patch(x1 - x0, y1 - y0)
        pil.paste(p, (x0, y0), p)
    return pil, marks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry', action='store_true', help='detect only')
    ap.add_argument('--limit', type=int, default=0, help='stop after N albums')
    ap.add_argument('--sample', help='write patched copies here instead of in place')
    a = ap.parse_args()
    done = json.load(open(LOG)) if os.path.exists(LOG) else {}
    albums = sorted(os.listdir(ROOT))
    if a.limit:
        albums = albums[:a.limit]
    n = 0
    for k, aid in enumerate(albums):
        adir = os.path.join(ROOT, aid)
        for f in sorted(os.listdir(adir)):
            if not f.endswith('.webp') or not f[:-5].isdigit():
                continue
            path = os.path.join(adir, f)
            res = apply(path)
            if not res:
                continue
            pil, marks = res
            n += 1
            if a.dry:
                print(aid, f, json.dumps(marks))
                continue
            if a.sample:
                pil.save(os.path.join(a.sample, f'{aid}_{f[:-5]}.jpg'), quality=85)
                continue
            # same inode: truncate + rewrite, keeps the hard link to yupoo_data
            buf = io.BytesIO()
            pil.save(buf, 'WEBP', quality=80)
            with open(path, 'r+b') as fh:
                fh.write(buf.getvalue())
                fh.truncate()
            if f == '1.webp':
                t = pil.copy()
                t.thumbnail((THUMB_WIDTH, 10 ** 6))
                t.save(os.path.join(adir, 's.webp'), 'WEBP', quality=70)
            done[f'{aid}/{f}'] = marks
        if not a.dry and not a.sample and k % 100 == 99:
            json.dump(done, open(LOG, 'w'))
            print(f'{k + 1}/{len(albums)} albums, {n} photos patchées', flush=True)
    if not a.dry and not a.sample:
        json.dump(done, open(LOG, 'w'))
    print(f'terminé: {n} photos patchées sur {len(albums)} albums')


if __name__ == '__main__':
    sys.exit(main())
