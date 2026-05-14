require('dotenv').config({ path: '/var/www/tchipa-api/.env' });
const forwarder = require('./forwarder');
const path = require("path");
const express = require('express');
const app = express();
const PORT = 3000;
app.use(express.json());
forwarder.init().catch(console.error);

// ============================================================
// Orders database (SQLite via better-sqlite3)
// ============================================================
const Database = require('better-sqlite3');
const DB_PATH  = path.join(__dirname, 'orders.db');
const db       = new Database(DB_PATH);
db.exec(`
  CREATE TABLE IF NOT EXISTS orders (
    id           TEXT PRIMARY KEY,
    product_name TEXT NOT NULL DEFAULT 'Commande Tchipa',
    total_usdt   REAL NOT NULL,
    status       TEXT NOT NULL DEFAULT 'pending',
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS transactions (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ref              TEXT,
    amount_expected  REAL,
    amount_received  REAL,
    currency         TEXT,
    tx_hash          TEXT,
    polygon_address  TEXT,
    status           TEXT,
    raw_payload      TEXT,
    received_at      TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_tx_ref ON transactions(ref);

  -- Bridge between agent-created orders and the client app:
  -- agent creates with phone X → row inserted here →
  -- client app polls /cards/for-phone/:X → fetches issued cards.
  -- Agents never see card details: redeem_link is only ever shared
  -- with the client device whose phone matches.
  CREATE TABLE IF NOT EXISTS agent_orders (
    redeem_id      TEXT PRIMARY KEY,
    phone          TEXT NOT NULL,
    holder_name    TEXT,
    amount_usd     REAL NOT NULL,
    flow           TEXT NOT NULL DEFAULT 'activation', -- 'activation' | 'recharge'
    status         TEXT NOT NULL DEFAULT 'pending',    -- 'pending' | 'paid' | 'completed'
    redeem_link    TEXT,
    delivered_at   TEXT,                               -- set when client app has fetched it
    claim_code     TEXT,                               -- 4-digit code, agent relays it to user out-of-band
    claim_attempts INTEGER NOT NULL DEFAULT 0,         -- wrong-code attempts; locks at >= 5
    created_at     TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_agent_phone  ON agent_orders(phone);
  CREATE INDEX IF NOT EXISTS idx_agent_status ON agent_orders(status);
`);

// In-place migration for existing DBs created before claim_code existed.
// Inline PRAGMA check (no migration tool — see CLAUDE.md conventions).
{
  const cols = db.prepare("PRAGMA table_info(agent_orders)").all().map(c => c.name);
  if (!cols.includes('claim_code')) {
    db.exec("ALTER TABLE agent_orders ADD COLUMN claim_code TEXT");
    console.log('[db] migrated: agent_orders.claim_code added');
  }
  if (!cols.includes('claim_attempts')) {
    db.exec("ALTER TABLE agent_orders ADD COLUMN claim_attempts INTEGER NOT NULL DEFAULT 0");
    console.log('[db] migrated: agent_orders.claim_attempts added');
  }
}

// Normalize a phone for stable lookup: keep leading '+', strip everything non-digit.
// '+213 555-12 34 56' → '+213555123456'. Used by both write (agent) and read (client).
function normalizePhone(raw) {
  if (raw == null) return null;
  const s = String(raw).trim();
  if (!s) return null;
  const hasPlus = s.startsWith('+');
  const digits  = s.replace(/\D/g, '');
  if (digits.length < 6) return null;
  return (hasPlus ? '+' : '') + digits;
}
console.log('[db] Orders DB ready at', DB_PATH);





// ---------------------------------------------------------------------------
// PayGate.to integration
// ---------------------------------------------------------------------------

const PAYGATE_ADDRESS    = '0xF1d2574F796d59Fb1289A5E32950F0FbF1227f9F';
const PAYGATE_WALLET_URL = 'https://api.paygate.to/control/wallet.php';

app.post('/paygate/create-wallet', async (req, res) => {
  const { callback, orderId } = req.body || {};

  let callbackUrl = callback;
  if (!callbackUrl && orderId) {
    callbackUrl = `https://api.tchipa.com/paygate/callback?order_id=${encodeURIComponent(orderId)}`;
  }
  if (!callbackUrl) {
    return res.status(400).json({ error: 'Missing required field: callback (or orderId to auto-generate one)' });
  }

  try { new URL(callbackUrl); } catch {
    return res.status(400).json({ error: 'Invalid callback URL format' });
  }

  const params = new URLSearchParams({
    address:  PAYGATE_ADDRESS,
    callback: callbackUrl,
  });

  const url = `${PAYGATE_WALLET_URL}?${params}`;
  console.log('[/paygate/create-wallet] calling:', url);

  try {
    const resp = await fetch(url, { signal: AbortSignal.timeout(30_000) });
    const body = await resp.json();

    if (!resp.ok) {
      console.error('[/paygate/create-wallet] PayGate error:', resp.status, body);
      return res.status(502).json({ error: 'PayGate.to returned an error', status: resp.status, details: body });
    }

    console.log('[/paygate/create-wallet] success, polygon_address_in:', body.polygon_address_in);
    return res.json({
      address_in:         body.address_in,
      polygon_address_in: body.polygon_address_in,
      callback_url:       body.callback_url,
      ipn_token:          body.ipn_token,
    });
  } catch (err) {
    console.error('[/paygate/create-wallet] fetch error:', err.message);
    return res.status(502).json({ error: 'Failed to reach PayGate.to: ' + err.message });
  }
});


// ============================================================
// GET /orders/:id  — fetch order details for AgentScreen
// ============================================================
app.get('/orders/:id', (req, res) => {
  const { id } = req.params;
  const row = db.prepare('SELECT * FROM orders WHERE id = ?').get(id);
  if (!row) {
    return res.status(404).json({ error: 'Commande introuvable', orderId: id });
  }
  return res.json({
    orderId:     row.id,
    productName: row.product_name,
    totalUsdt:   row.total_usdt,
    status:      row.status,
    createdAt:   row.created_at,
  });
});

// ============================================================
// POST /orders  — create or update an order (called by the app at checkout)
// ============================================================
app.post('/orders', (req, res) => {
  const { orderId, productName, totalUsdt, status } = req.body || {};
  if (!orderId || totalUsdt == null) {
    return res.status(400).json({ error: 'Champs requis: orderId, totalUsdt' });
  }
  db.prepare(`
    INSERT INTO orders (id, product_name, total_usdt, status)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      product_name = excluded.product_name,
      total_usdt   = excluded.total_usdt,
      status       = excluded.status
  `).run(
    orderId,
    productName || 'Commande Tchipa',
    parseFloat(totalUsdt),
    status || 'pending'
  );
  const row = db.prepare('SELECT * FROM orders WHERE id = ?').get(orderId);
  return res.status(201).json({
    orderId:     row.id,
    productName: row.product_name,
    totalUsdt:   row.total_usdt,
    status:      row.status,
    createdAt:   row.created_at,
  });
});


// ============================================================
// POST /paygate/generate-vcc
// Body: { amount, orderId?, vccRef? }
// Creates a PayGate wallet for VCC generation and returns
// the deposit address + a ready-to-use checkout URL.
// ============================================================
app.post('/paygate/generate-vcc', async (req, res) => {
  const { amount, orderId, vccRef } = req.body || {};

  const amountUsdt = parseFloat(amount);
  if (!amount || isNaN(amountUsdt) || amountUsdt <= 0) {
    return res.status(400).json({ error: 'Champ requis: amount (USDT > 0)' });
  }

  const amountStr   = amountUsdt.toFixed(2);
  const ref         = vccRef || orderId || `vcc-${Date.now()}`;
  const callbackUrl = `https://api.tchipa.com/paygate/vcc-callback?ref=${encodeURIComponent(ref)}&amount=${amountStr}`;

  const params = new URLSearchParams({
    address:  PAYGATE_ADDRESS,
    callback: callbackUrl,
  });

  console.log(`[/paygate/generate-vcc] amount=${amountStr} ref=${ref}`);

  try {
    const resp = await fetch(
      `${PAYGATE_WALLET_URL}?${params}`,
      { signal: AbortSignal.timeout(30_000) }
    );
    const body = await resp.json();

    if (!resp.ok) {
      console.error('[/paygate/generate-vcc] PayGate error:', resp.status, body);
      return res.status(502).json({ error: 'PayGate.to error', details: body });
    }

    const polygonAddress = body.polygon_address_in;
    const ipnToken       = decodeURIComponent(body.ipn_token  || '');
    const addressIn      = decodeURIComponent(body.address_in || '');

    // Hosted checkout page — open in WebView or browser
    const checkoutUrl = `https://paygate.to/checkout?${new URLSearchParams({
      address:  polygonAddress,
      amount:   amountStr,
      currency: 'USDT_POLYGON',
      ref,
    })}`;

    console.log(`[/paygate/generate-vcc] ok polygon=${polygonAddress}`);

    return res.json({
      ref,
      amountUsdt:    amountUsdt,
      walletAddress: polygonAddress,
      addressIn,
      checkoutUrl,
      callbackUrl:   body.callback_url || callbackUrl,
      ipnToken,
    });

  } catch (err) {
    console.error('[/paygate/generate-vcc] fetch error:', err.message);
    return res.status(502).json({ error: 'Failed to reach PayGate.to: ' + err.message });
  }
});


// ============================================================
// POST /paygate/vcc-callback
// Called by PayGate.to when a USDT payment is confirmed.
// Query params: ?ref=<orderId>&amount=<expected>
// Body: PayGate IPN payload (JSON or form-encoded)
// ============================================================
app.post('/paygate/vcc-callback', express.urlencoded({ extended: true }), (req, res) => {
  // PayGate sends either JSON or form-encoded — merge both
  const payload = Object.assign({}, req.query, req.body);

  const ref             = payload.ref             || payload.order_id  || null;
  const amountExpected  = parseFloat(payload.amount)                   || null;
  const amountReceived  = parseFloat(payload.amount_paid ?? payload.amount_received ?? payload.value) || null;
  const currency        = payload.currency        || payload.coin      || 'USDT_POLYGON';
  const txHash          = payload.hash            || payload.tx_hash   || payload.txid || null;
  const polygonAddress  = payload.address_in      || payload.polygon_address_in       || null;
  const status          = payload.status          || 'confirmed';
  const rawPayload      = JSON.stringify(payload);

  console.log(`[/paygate/vcc-callback] ref=${ref} amount_received=${amountReceived} status=${status} tx=${txHash}`);

  // Log the transaction
  const insertTx = db.prepare(`
    INSERT INTO transactions
      (ref, amount_expected, amount_received, currency, tx_hash, polygon_address, status, raw_payload)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  try {
    const info = insertTx.run(ref, amountExpected, amountReceived, currency, txHash, polygonAddress, status, rawPayload);
    console.log(`[/paygate/vcc-callback] logged tx id=${info.lastInsertRowid}`);
  } catch (dbErr) {
    console.error('[/paygate/vcc-callback] DB insert error:', dbErr.message);
  }

  // Update matching order status to 'paid'
  if (ref) {
    const order = db.prepare('SELECT id FROM orders WHERE id = ?').get(ref);
    if (order) {
      db.prepare("UPDATE orders SET status = 'paid' WHERE id = ?").run(ref);
      console.log(`[/paygate/vcc-callback] order ${ref} marked as paid`);
    }
  }

  // PayGate expects a 200 with plain text "OK"
  res.status(200).send('OK');
});

// GET /paygate/vcc-callback/transactions — list recent transactions (debug)
app.get('/paygate/vcc-callback/transactions', (req, res) => {
  const rows = db.prepare(
    'SELECT id, ref, amount_expected, amount_received, currency, tx_hash, status, received_at FROM transactions ORDER BY id DESC LIMIT 50'
  ).all();
  res.json({ count: rows.length, transactions: rows });
});



// ---------------------------------------------------------------------------
// PayGate.to VCC (Virtual Credit Card) — Crypto Cards API
// Docs: https://github.com/paygate-to/anonymous-virtual-credit-card
// ---------------------------------------------------------------------------

const PAYGATE_VCC_WALLET = 'https://api.paygate.to/crypto/cards/wallet.php';
const PAYGATE_VCC_STATUS = 'https://api.paygate.to/crypto/cards/status.php';
const TCHIPA_MARGIN = 0.10; // 10% majoration sur le prix PayGate

// POST /paygate/create-vcc
// Body: { amount, cardType?, holderName?, phone?, paypalEmail?, flow? }
// cardType: 'mastercard' (5-499 USD) | 'visa' (5-1000 USD) | 'paypal' (5-1000 USD)
// flow (only with phone): 'activation' (default) | 'recharge'
app.post('/paygate/create-vcc', async (req, res) => {
  const { amount, cardType = 'mastercard', holderName, phone, paypalEmail, fromAddress, flow, source } = req.body || {};
  const parsed = parseFloat(amount);
  if (!parsed || isNaN(parsed) || parsed < 5) {
    return res.status(400).json({ error: 'amount doit etre >= 5 USD' });
  }
  // Validation optionnelle de fromAddress (adresse Ethereum)
  let fromAddr = null;
  if (fromAddress) {
    const fa = String(fromAddress).trim();
    if (!/^0x[a-fA-F0-9]{40}$/.test(fa)) {
      return res.status(400).json({ error: 'fromAddress invalide (attendu: 0x + 40 hex)' });
    }
    fromAddr = fa.toLowerCase();
  }
  const provider = String(cardType).toLowerCase();
  let url = PAYGATE_VCC_WALLET + '?provider=' + provider + '&amount=' + parsed.toFixed(2);
  if (provider === 'paypal') {
    if (!paypalEmail) return res.status(400).json({ error: 'paypalEmail requis pour PayPal' });
    url += '&paypal_email=' + encodeURIComponent(paypalEmail);
  }
  console.log('[/paygate/create-vcc]', url, fromAddr ? ('from=' + fromAddr) : '(no fromAddress)');
  try {
    const resp = await fetch(url, { signal: AbortSignal.timeout(30_000) });
    const data = await resp.json();
    if (!data.address_in || !data.redeem_id) {
      throw new Error(data.error || 'PayGate VCC API error (status ' + resp.status + ')');
    }
    console.log('[/paygate/create-vcc] ok, redeem_id:', data.redeem_id);
    const paygateAmount = parseFloat(data.amount || parsed);
    const baseClient    = parseFloat((paygateAmount * (1 + TCHIPA_MARGIN)).toFixed(2));
    const { clientAmount, suffix } = forwarder.buildUniqueClientAmount(baseClient);
    forwarder.addOrder(data.redeem_id, clientAmount, paygateAmount, data.address_in, fromAddr);
    console.log('[/paygate/create-vcc] paygate=' + paygateAmount + ' client=' + clientAmount.toFixed(6) + ' USDT (base=' + baseClient + ', suffix=' + suffix + ')');

    // Bridge row in agent_orders is only useful when an agent creates a card
    // FOR someone else — the client app then discovers it via /cards/for-phone.
    // For self-serve (user paying for their own card), the redeem_id is held
    // privately by the creator's device, so no bridge row is needed; writing
    // one would actually leak the redeem_id to anyone who knows the user's
    // phone (they could pull it from /cards/for-phone and bypass the code
    // challenge via /paygate/check-status).
    //
    // source: 'self' → skip insert. 'agent' or missing (legacy clients) → insert.
    const normPhone = normalizePhone(phone);
    const isAgentBridge = !!normPhone && source !== 'self';
    let claimCode = null;
    if (isAgentBridge) {
      claimCode = String(Math.floor(1000 + Math.random() * 9000));
      try {
        db.prepare(`
          INSERT INTO agent_orders (redeem_id, phone, holder_name, amount_usd, flow, status, claim_code)
          VALUES (?, ?, ?, ?, ?, 'pending', ?)
        `).run(data.redeem_id, normPhone, holderName || null,
               parseFloat(String(data.card_value || parsed)),
               flow === 'recharge' ? 'recharge' : 'activation',
               claimCode);
        console.log('[/paygate/create-vcc] agent_order recorded for phone=' + normPhone + ' (code set)');
      } catch (e) {
        console.error('[/paygate/create-vcc] agent_orders insert error:', e.message);
      }
    }

    return res.json({
      redeemId:      data.redeem_id,
      cryptoAddress: forwarder.getAddress(),
      amountUsdt:    clientAmount.toFixed(6),
      qrCode:        null,
      cardValue:     parseFloat(String(data.card_value || parsed)),
      cardCurrency:  data.card_currency || 'USD',
      cardType:      provider,
      holderName:    holderName || null,
      claimCode,
    });
  } catch (err) {
    console.error('[/paygate/create-vcc] error:', err.message);
    return res.status(502).json({ error: 'Erreur PayGate VCC: ' + err.message });
  }
});

// Shared helper: hit PayGate status + sync any agent_orders bridge row.
async function fetchPayGateStatus(redeemId) {
  const url = PAYGATE_VCC_STATUS + '?redeem_id=' + encodeURIComponent(redeemId);
  const resp = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  const data = await resp.json();
  if (!data.payment_status) throw new Error('redeem_id invalide ou erreur PayGate');
  const redeemLink = (data.redeem_link && data.redeem_link !== 'N/A') ? data.redeem_link : null;
  const isPaid     = data.payment_status === 'paid';
  const isReady    = data.card_issuer_status === 'completed';

  // Mirror progress into agent_orders if this redeem_id was created via the agent flow.
  const agentRow = db.prepare('SELECT status FROM agent_orders WHERE redeem_id = ?').get(redeemId);
  if (agentRow) {
    const newStatus = isReady ? 'completed' : (isPaid ? 'paid' : 'pending');
    if (newStatus !== agentRow.status || (isReady && redeemLink)) {
      db.prepare(`
        UPDATE agent_orders
           SET status = ?, redeem_link = COALESCE(?, redeem_link), updated_at = datetime('now')
         WHERE redeem_id = ?
      `).run(newStatus, redeemLink, redeemId);
    }
  }

  return {
    paymentStatus: data.payment_status,
    cardStatus:    data.card_issuer_status || 'pending',
    redeemLink,
    isPaid,
    isReady,
  };
}

// GET /paygate/check-status?redeem_id=XXX  (client-side polling — full response with link)
app.get('/paygate/check-status', async (req, res) => {
  const { redeem_id } = req.query;
  if (!redeem_id) return res.status(400).json({ error: 'Parametre redeem_id manquant' });
  console.log('[/paygate/check-status]', redeem_id);
  try {
    return res.json(await fetchPayGateStatus(String(redeem_id)));
  } catch (err) {
    console.error('[/paygate/check-status] error:', err.message);
    return res.status(502).json({ error: 'Verification echouee: ' + err.message });
  }
});

// GET /agent/order-status?redeem_id=XXX
// Same upstream call as /paygate/check-status but STRIPS redeem_link / paymentStatus,
// returning only a coarse state. Used by the agent app — agents must never
// receive card-recovery URLs (anti-theft).
app.get('/agent/order-status', async (req, res) => {
  const { redeem_id } = req.query;
  if (!redeem_id) return res.status(400).json({ error: 'Parametre redeem_id manquant' });
  try {
    const s = await fetchPayGateStatus(String(redeem_id));
    const agentRow = db.prepare('SELECT phone, holder_name, delivered_at FROM agent_orders WHERE redeem_id = ?').get(String(redeem_id));
    return res.json({
      redeemId:   String(redeem_id),
      state:      s.isReady ? 'completed' : (s.isPaid ? 'paid' : 'pending'),
      isPaid:     s.isPaid,
      isReady:    s.isReady,
      delivered:  !!(agentRow && agentRow.delivered_at),
      phone:      agentRow ? agentRow.phone : null,
      holderName: agentRow ? agentRow.holder_name : null,
    });
  } catch (err) {
    console.error('[/agent/order-status] error:', err.message);
    return res.status(502).json({ error: 'Verification echouee: ' + err.message });
  }
});

// GET /cards/for-phone/:phone
// Returns any completed agent_orders for this phone that haven't been marked
// delivered yet. The client app polls this on startup and pull-to-refresh to
// discover cards generated for it by an agent.
app.get('/cards/for-phone/:phone', async (req, res) => {
  const phone = normalizePhone(req.params.phone);
  if (!phone) return res.status(400).json({ error: 'Numero invalide' });

  // First pass: refresh any pending rows from PayGate so a freshly-paid card
  // can be delivered without waiting for the next agent-side poll.
  const pendingRows = db.prepare(
    "SELECT redeem_id FROM agent_orders WHERE phone = ? AND status != 'completed'"
  ).all(phone);
  for (const r of pendingRows) {
    try { await fetchPayGateStatus(r.redeem_id); } catch (_) {}
  }

  const rows = db.prepare(`
    SELECT redeem_id, holder_name, amount_usd, flow, redeem_link,
           created_at, delivered_at, claim_code
      FROM agent_orders
     WHERE phone = ? AND status = 'completed' AND redeem_link IS NOT NULL
     ORDER BY created_at DESC
  `).all(phone);

  // For code-gated, undelivered cards: hide redeem_link. The app must call
  // /cards/claim-with-code with the 4-digit secret to obtain it. Already-
  // delivered cards keep the link exposed so the legitimate device can still
  // re-open them locally (the link is single-use upstream anyway).
  return res.json({
    phone,
    count: rows.length,
    cards: rows.map(r => {
      const locked = !!r.claim_code && !r.delivered_at;
      return {
        redeemId:     r.redeem_id,
        holderName:   r.holder_name,
        cardValue:    r.amount_usd,
        flow:         r.flow,
        redeemLink:   locked ? null : r.redeem_link,
        requiresCode: locked,
        createdAt:    r.created_at,
        delivered:    !!r.delivered_at,
      };
    }),
  });
});

// POST /cards/mark-delivered { redeem_id }
// Called by the client app once it has successfully extracted card data, so
// that subsequent polls don't keep re-surfacing the same card.
app.post('/cards/mark-delivered', (req, res) => {
  const { redeem_id } = req.body || {};
  if (!redeem_id) return res.status(400).json({ error: 'redeem_id requis' });
  const r = db.prepare(`
    UPDATE agent_orders SET delivered_at = datetime('now'), updated_at = datetime('now')
     WHERE redeem_id = ?
  `).run(String(redeem_id));
  return res.json({ ok: true, changes: r.changes });
});

// POST /cards/claim-with-code { phone, redeem_id, code }
// Unlocks the redeem_link for a code-gated agent order. Phone must match the
// order's recorded phone (so a leaked redeem_id alone isn't enough), and the
// 4-digit code must match what was returned to the agent on creation.
// Locks the row after 5 wrong attempts — agent must reissue.
const CLAIM_MAX_ATTEMPTS = 5;
app.post('/cards/claim-with-code', (req, res) => {
  const { phone, redeem_id, code } = req.body || {};
  const normPhone = normalizePhone(phone);
  if (!normPhone || !redeem_id || !code) {
    return res.status(400).json({ error: 'phone, redeem_id et code requis' });
  }
  const row = db.prepare(`
    SELECT phone, redeem_link, claim_code, claim_attempts, delivered_at
      FROM agent_orders
     WHERE redeem_id = ?
  `).get(String(redeem_id));
  if (!row || row.phone !== normPhone) {
    return res.status(404).json({ error: 'Commande introuvable' });
  }
  if (!row.redeem_link) {
    return res.status(409).json({ error: 'Carte pas encore prete' });
  }
  if (!row.claim_code) {
    // Legacy row with no code — link is already public via /cards/for-phone.
    return res.json({ redeemLink: row.redeem_link });
  }
  if (row.claim_attempts >= CLAIM_MAX_ATTEMPTS) {
    return res.status(429).json({ error: 'Trop de tentatives. Demandez un nouveau code a l agent.' });
  }
  if (String(code).trim() !== row.claim_code) {
    db.prepare(`
      UPDATE agent_orders
         SET claim_attempts = claim_attempts + 1, updated_at = datetime('now')
       WHERE redeem_id = ?
    `).run(String(redeem_id));
    const remaining = Math.max(0, CLAIM_MAX_ATTEMPTS - (row.claim_attempts + 1));
    return res.status(403).json({ error: 'Code invalide', attemptsRemaining: remaining });
  }
  // Success: burn the code so the link is no longer gated for this row.
  // delivered_at is left to /cards/mark-delivered (called after extraction).
  db.prepare(`
    UPDATE agent_orders
       SET claim_code = NULL, updated_at = datetime('now')
     WHERE redeem_id = ?
  `).run(String(redeem_id));
  return res.json({ redeemLink: row.redeem_link });
});

// POST /paygate/request-recharge — alias create-vcc pour compat Flutter
app.post('/paygate/request-recharge', async (req, res) => {
  const { amount, amountUsd, phone } = req.body || {};
  const parsed = parseFloat(amount || amountUsd);
  if (!parsed || isNaN(parsed) || parsed < 5) {
    return res.status(400).json({ error: 'amount doit etre >= 5 USD' });
  }
  const url = PAYGATE_VCC_WALLET + '?provider=mastercard&amount=' + parsed.toFixed(2);
  try {
    const resp = await fetch(url, { signal: AbortSignal.timeout(30_000) });
    const data = await resp.json();
    if (!data.address_in || !data.redeem_id) throw new Error(data.error || 'API error');
    return res.json({
      redeemId:      data.redeem_id,
      cryptoAddress: data.address_in,
      amountUsdt:    String(data.amount || parsed),
      qrCode:        data.qr_code || null,
      cardValue:     parseFloat(String(data.card_value || parsed)),
      cardType:      'mastercard',
    });
  } catch (err) {
    return res.status(502).json({ error: 'Erreur recharge: ' + err.message });
  }
});

// GET /paygate/vcc-balance/:cardId — balance via redeem link (pas d API directe PayGate VCC)
app.get('/paygate/vcc-balance/:cardId', (req, res) => {
  return res.json({ balance: 0, note: 'Consultez votre lien de carte PayGate pour le solde' });
});


// ============================================================
// Admin endpoints (gestion manuelle VCC)
// ============================================================

// GET /admin/pending-orders — liste les ordres en attente de paiement
app.get('/admin/pending-orders', (req, res) => {
  const orders = forwarder.getPendingOrders();
  res.json({ count: orders.length, orders });
});

// GET /admin/recent-vcc — les derniers redeem_id créés (depuis les logs PM2 via DB)
app.get('/admin/recent-vcc', (req, res) => {
  const rows = db.prepare(`
    SELECT * FROM pending_orders ORDER BY created_at DESC LIMIT 20
  `).all();
  res.json({ count: rows.length, orders: rows });
});

// POST /admin/manual-forward
// Body: { redeem_id }  — force l'envoi vers PayGate pour un ordre bloqué
app.post('/admin/manual-forward', async (req, res) => {
  const { redeem_id } = req.body || {};
  if (!redeem_id) return res.status(400).json({ error: 'redeem_id requis' });
  console.log(`[admin] manual-forward demandé pour ${redeem_id}`);
  const result = await forwarder.manualForward(redeem_id);
  res.status(result.ok ? 200 : 500).json(result);
});

// POST /admin/re-add-order
// Body: { redeem_id, client_amount, paygate_amount, paygate_address }
// Recrée un ordre perdu (ex: après un redémarrage PM2)
app.post('/admin/re-add-order', (req, res) => {
  const { redeem_id, client_amount, paygate_amount, paygate_address } = req.body || {};
  if (!redeem_id || !client_amount || !paygate_amount || !paygate_address)
    return res.status(400).json({ error: 'Champs requis: redeem_id, client_amount, paygate_amount, paygate_address' });
  forwarder.addOrder(redeem_id, client_amount, paygate_amount, paygate_address);
  res.json({ ok: true, message: `Ordre ${redeem_id} réenregistré` });
});

// GET /admin/orphan-payments — paiements recus mais non matches a un ordre
app.get('/admin/orphan-payments', (req, res) => {
  const limit = parseInt(req.query.limit, 10) || 50;
  const orphans = forwarder.getOrphanPayments(limit);
  res.json({ count: orphans.length, orphans });
});

// GET /admin/recent-txs — historique recent des transferts traites
app.get('/admin/recent-txs', (req, res) => {
  const limit = parseInt(req.query.limit, 10) || 50;
  const txs = forwarder.getRecentTxs(limit);
  res.json({ count: txs.length, txs });
});

// GET /wallet-address — adresse fixe du wallet VPS (pour les agents)
app.get('/wallet-address', async (req, res) => {
  const balance = await forwarder.getBalance();
  return res.json({ address: forwarder.getAddress(), network: 'Polygon', token: 'USDT', balance });
});

app.listen(PORT, () => {
  console.log(`Tchipa API actif sur http://localhost:${PORT}`);
});
