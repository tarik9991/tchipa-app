'use strict';

const express = require('express');
const WebSocket = require('ws');

const app = express();
app.use(express.json());

const OPENCLAW_WS    = 'ws://localhost:57723';
const OPENCLAW_TOKEN = 'Obb6pSBDs3jtPoVZGNzTbjHCak8dJ9H2';
const SCRAPINGBEE_URL = 'https://app.scrapingbee.com/api/v1/';
const SCRAPINGBEE_KEY = process.env.SCRAPINGBEE_API_KEY || 'LLYGCNEEO45XFQOXLWBVT5DGM1UJR1A90LOR8RCK210JPEHSLKIYXL63NP1UGRQY9LI8703CHJUC2HPQ';

// ---------------------------------------------------------------------------
// OpenClaw helper (used by /browse)
// ---------------------------------------------------------------------------

function browseWithOpenClaw(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(OPENCLAW_WS, {
      headers: { Authorization: `Bearer ${OPENCLAW_TOKEN}` }
    });

    const timeout = setTimeout(() => {
      ws.terminate();
      reject(new Error('OpenClaw WebSocket timeout after 30s'));
    }, 30000);

    ws.on('open', () => {
      ws.send(JSON.stringify({
        type: 'navigate',
        url,
        token: OPENCLAW_TOKEN,
        extract: ['title', 'price', 'image']
      }));
    });

    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === 'error') {
          clearTimeout(timeout);
          ws.close();
          return reject(new Error(msg.message || 'OpenClaw returned error'));
        }
        if (msg.type === 'result' || msg.type === 'page' || msg.url || msg.title) {
          clearTimeout(timeout);
          ws.close();
          const productName = msg.title || msg.productName || msg.name || null;
          const rawPrice    = msg.price || msg.priceUSD || msg.cost || null;
          const priceUSD    = rawPrice ? parseFloat(String(rawPrice).replace(/[^0-9.]/g, '')) || rawPrice : null;
          const imageUrl    = msg.image || msg.imageUrl || msg.thumbnail || null;
          resolve({ productName, priceUSD, imageUrl });
        }
      } catch (e) {
        clearTimeout(timeout);
        ws.close();
        reject(new Error('Failed to parse OpenClaw response: ' + e.message));
      }
    });

    ws.on('error', (err) => {
      clearTimeout(timeout);
      reject(new Error('OpenClaw WebSocket error: ' + err.message));
    });

    ws.on('close', (code, reason) => {
      clearTimeout(timeout);
      if (code !== 1000 && code !== undefined) {
        reject(new Error(`OpenClaw connection closed unexpectedly: ${code} ${reason}`));
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Temu HTML parsing helpers (used by /check-product via ScrapingBee)
// ---------------------------------------------------------------------------

function extractJsonLd(html) {
  const matches = [...html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
  for (const m of matches) {
    try {
      const obj   = JSON.parse(m[1]);
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

function parseTemuHtml(html) {
  let name = null, price = null, image = null;

  // 1. JSON-LD structured data
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

  // 5. Temu-specific meta tags (name="title" not og:title)
  if (!name) {
    const m = html.match(/<meta[^>]+name="title"[^>]+content="([^"]+)"/i)
      || html.match(/<meta[^>]+content="([^"]+)"[^>]+name="title"/i);
    if (m && !m[1].toLowerCase().includes('discontinued')) name = m[1].replace(/\s*[-|]\s*temu\s*$/i, '').trim();
  }

  // 6. Regex fallbacks
  if (!name) {
    const m = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
    if (m) name = m[1].replace(/<[^>]+>/g, '').trim();
  }
  if (!price) {
    const m = html.match(/["'](?:retail|sale|display)?[Pp]rice["']\s*:\s*["']?([\d.]+)["']?/)
      || html.match(/["']price["']\s*:\s*["']?([\d.,]+)["']?/);
    if (m) price = m[1];
  }
  // Match any kwcdn subdomain image URL
  if (!image) {
    const m = html.match(/<img[^>]+src=["'](https:\/\/(?:img|aimg|rewimg)[^.]*\.kwcdn\.com[^"']+)["']/i)
      || html.match(/["'](https:\/\/(?:img|aimg|rewimg)[^.]*\.kwcdn\.com\/product\/[^"'?]+)["']/i);
    if (m) image = m[1];
  }

  return { name, price, image };
}

async function scrapeTemu(url) {
  const params = new URLSearchParams({
    api_key:        SCRAPINGBEE_KEY,
    url:            url,
    render_js:      'true',
    stealth_proxy:  'true',
    country_code:   'us',
    wait:           '5000',
    block_resources:'false',
  });

  console.log('[Temu/ScrapingBee] scraping:', url);

  const resp = await fetch(`${SCRAPINGBEE_URL}?${params}`, {
    signal: AbortSignal.timeout(150_000),
  });

  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(`ScrapingBee ${resp.status}: ${body.slice(0, 300)}`);
  }

  const html = await resp.text();
  console.log('[Temu/ScrapingBee] got HTML, length:', html.length);

  const { name, price, image } = parseTemuHtml(html);

  if (!name && !price) {
    throw new Error('Could not extract product data from Temu page');
  }

  console.log('[Temu/ScrapingBee] extracted:', { name, price, image: image ? image.slice(0, 60) + '…' : null });
  return { name, price, image };
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

app.get('/browse', async (req, res) => {
  const { url } = req.query;
  if (!url) return res.status(400).json({ error: 'Missing required query parameter: url' });
  try { new URL(url); } catch { return res.status(400).json({ error: 'Invalid URL format' }); }

  try {
    const result = await browseWithOpenClaw(url);
    return res.json({ productName: result.productName, priceUSD: result.priceUSD, imageUrl: result.imageUrl });
  } catch (err) {
    console.error('[/browse] Error:', err.message);
    return res.status(502).json({ error: err.message });
  }
});

app.post('/browse', async (req, res) => {
  const { url } = req.body;
  if (!url) return res.status(400).json({ error: 'Missing required field: url' });
  try { new URL(url); } catch { return res.status(400).json({ error: 'Invalid URL format' }); }

  try {
    const result = await browseWithOpenClaw(url);
    return res.json({ productName: result.productName, priceUSD: result.priceUSD, imageUrl: result.imageUrl });
  } catch (err) {
    console.error('[/browse] Error:', err.message);
    return res.status(502).json({ error: err.message });
  }
});

app.post('/check-product', async (req, res) => {
  const { url } = req.body;
  if (!url) return res.status(400).json({ error: 'Missing required field: url' });
  try { new URL(url); } catch { return res.status(400).json({ error: 'Invalid URL format' }); }

  try {
    const { name, price, image } = await scrapeTemu(url);
    return res.json({ name, price, image_url: image });
  } catch (err) {
    console.error('[/check-product] Error:', err.message);
    return res.status(502).json({ error: err.message, message: 'Erreur lors de la récupération du produit' });
  }
});

// ---------------------------------------------------------------------------
// /analyze-screenshot — Ollama moondream vision
// ---------------------------------------------------------------------------

const OLLAMA_URL = 'http://127.0.0.1:32768';

app.post('/analyze-screenshot', async (req, res) => {
  const { imageBase64 } = req.body;
  if (!imageBase64) return res.status(400).json({ error: 'Missing imageBase64' });

  const prompt =
    'This is a Temu product screenshot. Extract the product name, variant (size/color/style if shown), and price. ' +
    'Reply with ONLY a raw JSON object — no markdown, no code block, no explanation. ' +
    'Use exactly these keys: {"name":"...","variant":"...","price":"..."}. ' +
    'For price use only digits and a dot (e.g. "12.99"). If a field is unknown use an empty string.';

  try {
    const ollamaResp = await fetch(`${OLLAMA_URL}/api/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'moondream',
        prompt,
        images: [imageBase64],
        stream: false,
      }),
      signal: AbortSignal.timeout(90_000),
    });

    if (!ollamaResp.ok) {
      const errText = await ollamaResp.text();
      throw new Error(`Ollama ${ollamaResp.status}: ${errText.slice(0, 300)}`);
    }

    const ollamaData = await ollamaResp.json();
    const rawText = (ollamaData.response || '').trim();
    console.log('[/analyze-screenshot] raw model output:', rawText.slice(0, 200));

    // Try to find a JSON object anywhere in the response
    let parsed = null;
    const jsonMatch = rawText.match(/\{[\s\S]*?\}/);
    if (jsonMatch) {
      try { parsed = JSON.parse(jsonMatch[0]); } catch { /* fall through */ }
    }

    // Fallback: try the whole text as JSON
    if (!parsed) {
      try { parsed = JSON.parse(rawText); } catch { /* fall through */ }
    }

    if (!parsed || !parsed.name) {
      return res.status(422).json({
        error: 'Could not extract product data from image',
        raw: rawText.slice(0, 400),
      });
    }

    return res.json({
      name:    parsed.name    || '',
      variant: parsed.variant || '',
      price:   String(parsed.price || '').replace(/[^0-9.]/g, ''),
    });
  } catch (err) {
    console.error('[/analyze-screenshot] Error:', err.message);
    return res.status(502).json({ error: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`tchipa-api listening on port ${PORT}`);
});
