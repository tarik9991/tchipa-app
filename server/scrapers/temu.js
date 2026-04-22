'use strict';

const SCRAPINGBEE_URL = 'https://app.scrapingbee.com/api/v1/';

// --- HTML extraction helpers ------------------------------------------------

function extractJsonLd(html) {
  const matches = [...html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
  for (const m of matches) {
    try {
      const obj = JSON.parse(m[1]);
      const items = Array.isArray(obj) ? obj : [obj];
      for (const item of items) {
        if (item['@type'] === 'Product') return item;
      }
    } catch { /* skip malformed */ }
  }
  return null;
}

function extractMeta(html, property) {
  const m = html.match(new RegExp(`<meta[^>]+(?:property|name)=["']${property}["'][^>]+content=["']([^"']+)["']`, 'i'))
    || html.match(new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']${property}["']`, 'i'));
  return m ? m[1].trim() : null;
}

function extractNextData(html) {
  const m = html.match(/<script[^>]+id=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)<\/script>/i);
  if (!m) return null;
  try { return JSON.parse(m[1]); } catch { return null; }
}

function deepFind(obj, keys, depth = 0) {
  if (!obj || typeof obj !== 'object' || depth > 12) return undefined;
  for (const key of keys) {
    if (key in obj && obj[key] !== null && obj[key] !== undefined) return obj[key];
  }
  for (const v of Object.values(obj)) {
    const found = deepFind(v, keys, depth + 1);
    if (found !== undefined) return found;
  }
  return undefined;
}

function firstInlineJson(html) {
  const m = html.match(/window\.__(?:STORE|STATE|DATA|INITIAL_STATE)__\s*=\s*(\{[\s\S]*?\});\s*(?:window|<\/script>)/);
  if (!m) return null;
  try { return JSON.parse(m[1]); } catch { return null; }
}

// ---------------------------------------------------------------------------

function parseTemuHtml(html) {
  let name = null, price = null, image = null;

  // 1. JSON-LD structured data (most reliable)
  const ld = extractJsonLd(html);
  if (ld) {
    name  = ld.name  || null;
    image = Array.isArray(ld.image) ? ld.image[0] : ld.image || null;
    const offer = Array.isArray(ld.offers) ? ld.offers[0] : ld.offers;
    if (offer) price = String(offer.price || '');
  }

  // 2. Open Graph meta tags
  if (!name)  name  = extractMeta(html, 'og:title') || extractMeta(html, 'twitter:title');
  if (!image) image = extractMeta(html, 'og:image') || extractMeta(html, 'twitter:image');
  if (!price) {
    const ogPrice = extractMeta(html, 'product:price:amount') || extractMeta(html, 'og:price:amount');
    if (ogPrice) price = ogPrice;
  }

  // 3. __NEXT_DATA__ blob
  if (!name || !price || !image) {
    const nextData = extractNextData(html);
    if (nextData) {
      if (!name)  name  = deepFind(nextData, ['goodsName', 'productName', 'title', 'name']);
      if (!price) {
        const raw = deepFind(nextData, ['price', 'salePrice', 'displayPrice', 'originalPrice']);
        if (raw !== undefined) price = String(raw);
      }
      if (!image) image = deepFind(nextData, ['imgUrl', 'imageUrl', 'mainImage', 'coverImage', 'image']);
    }
  }

  // 4. Inline window.__STATE__ blobs
  if (!name || !price || !image) {
    const store = firstInlineJson(html);
    if (store) {
      if (!name)  name  = deepFind(store, ['goodsName', 'productName', 'title', 'name']);
      if (!price) {
        const raw = deepFind(store, ['price', 'salePrice', 'displayPrice']);
        if (raw !== undefined) price = String(raw);
      }
      if (!image) image = deepFind(store, ['imgUrl', 'imageUrl', 'mainImage', 'coverImage']);
    }
  }

  // 5. Regex fallbacks on raw HTML
  if (!name) {
    const m = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
    if (m) name = m[1].replace(/<[^>]+>/g, '').trim();
  }
  if (!price) {
    const m = html.match(/["']price["']\s*:\s*["']?([\d.,]+)["']?/);
    if (m) price = m[1];
  }
  if (!image) {
    const m = html.match(/<img[^>]+src=["'](https:\/\/img\.kwcdn\.com[^"']+)["']/i);
    if (m) image = m[1];
  }

  return { name, price, image };
}

// ---------------------------------------------------------------------------

async function scrapeTemu(url) {
  const apiKey = process.env.SCRAPINGBEE_API_KEY;
  if (!apiKey) throw new Error('SCRAPINGBEE_API_KEY environment variable is not set');

  const params = new URLSearchParams({
    api_key:   apiKey,
    url:       url,
    render_js: 'true',
  });

  console.log('[Temu/ScrapingBee] scraping:', url);

  const resp = await fetch(`${SCRAPINGBEE_URL}?${params}`, {
    signal: AbortSignal.timeout(120_000),
  });

  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`ScrapingBee ${resp.status}: ${text.slice(0, 300)}`);
  }

  const html = await resp.text();
  console.log('[Temu/ScrapingBee] got HTML, length:', html.length);

  const { name, price, image } = parseTemuHtml(html);

  if (!name && !price) {
    throw new Error('Could not extract product data from Temu page — selectors may need updating');
  }

  console.log('[Temu/ScrapingBee] extracted:', { name, price, image: image ? image.slice(0, 60) + '…' : null });
  return { name, price, image, sourceHtmlLength: html.length };
}

module.exports = { scrapeTemu };
