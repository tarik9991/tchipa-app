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
    redeem_id          TEXT PRIMARY KEY,
    phone              TEXT NOT NULL,
    holder_name        TEXT,
    amount_usd         REAL NOT NULL,
    flow               TEXT NOT NULL DEFAULT 'activation', -- 'activation' | 'recharge'
    status             TEXT NOT NULL DEFAULT 'pending',    -- 'pending' | 'paid' | 'completed'
    redeem_link        TEXT,
    delivered_at       TEXT,                               -- set when client app has fetched it
    claim_code         TEXT,                               -- 4-digit code, agent relays it to user out-of-band
    claim_attempts     INTEGER NOT NULL DEFAULT 0,         -- wrong-code attempts; locks at >= 5
    agent_order_token  TEXT UNIQUE,                        -- opaque UUID exposed to agent in place of redeem_id
    created_at         TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at         TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_agent_phone  ON agent_orders(phone);
  CREATE INDEX IF NOT EXISTS idx_agent_status ON agent_orders(status);

  -- Client-owned PIN, tied to a verified email. Set ONCE at install time,
  -- before any agent transaction. The PIN is the secret that gates
  -- /cards/claim-with-pin; the email is the trust anchor that an agent
  -- must repeat at order time so a phone-only squat is ineffective.
  CREATE TABLE IF NOT EXISTS user_pins (
    phone           TEXT PRIMARY KEY,        -- normalizePhone()
    pin_hash        TEXT NOT NULL,           -- scrypt(pin, salt)
    pin_salt        TEXT NOT NULL,           -- hex
    email           TEXT,                    -- plain, lowercased; needed to send magic link
    email_hash      TEXT,                    -- sha256(lowercased) — what /paygate/create-vcc matches against
    device_id       TEXT,                    -- first device that completed setup; informational
    verified        INTEGER NOT NULL DEFAULT 0,  -- 1 once the magic link was clicked
    verify_token    TEXT,                    -- one-shot, cleared on verify or expiry
    verify_expires  TEXT,                    -- ISO; rows past expiry can re-setup
    pin_attempts    INTEGER NOT NULL DEFAULT 0,  -- global wrong-pin counter; UI can show lockout
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_user_pin_email ON user_pins(email_hash);
  CREATE INDEX IF NOT EXISTS idx_user_pin_token ON user_pins(verify_token);
`);

// In-place migration for existing DBs created before these columns existed.
// Inline PRAGMA check (no migration tool — see CLAUDE.md conventions).
// Runs BEFORE the agent_order_token index creation, so a pre-existing table
// without the column doesn't blow up at index-create time.
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
  if (!cols.includes('agent_order_token')) {
    db.exec("ALTER TABLE agent_orders ADD COLUMN agent_order_token TEXT");
    console.log('[db] migrated: agent_orders.agent_order_token added');
  }
  if (!cols.includes('protected_by_pin')) {
    db.exec("ALTER TABLE agent_orders ADD COLUMN protected_by_pin INTEGER NOT NULL DEFAULT 0");
    console.log('[db] migrated: agent_orders.protected_by_pin added');
  }
}
db.exec("CREATE INDEX IF NOT EXISTS idx_agent_token ON agent_orders(agent_order_token)");

// Cryptographically random UUID v4 — used as the agent's opaque order handle
// so the agent's app never sees the underlying redeem_id (which would let
// them call /paygate/check-status directly and bypass the claim-code gate).
const { randomUUID, scryptSync, randomBytes, createHash, timingSafeEqual } = require('crypto');

// PIN hashing: scrypt with per-row salt. Stored as hex; verifyPin uses
// timing-safe compare so wrong-PIN response time doesn't leak structure.
const PIN_HASH_BYTES = 32;
function hashPin(pin, saltHex) {
  return scryptSync(String(pin), Buffer.from(saltHex, 'hex'), PIN_HASH_BYTES).toString('hex');
}
function verifyPin(pin, saltHex, expectedHex) {
  const got = Buffer.from(hashPin(pin, saltHex), 'hex');
  const exp = Buffer.from(expectedHex, 'hex');
  if (got.length !== exp.length) return false;
  return timingSafeEqual(got, exp);
}
function normalizeEmail(raw) {
  if (raw == null) return null;
  const s = String(raw).trim().toLowerCase();
  // RFC-lite check — good enough for "is this plausibly an address"
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s)) return null;
  return s;
}
function hashEmail(emailNorm) {
  return createHash('sha256').update(emailNorm).digest('hex');
}

// Magic-link email. Transport priority:
//   1. Gmail SMTP (GMAIL_USER + GMAIL_APP_PASSWORD) — free, reliable
//   2. Brevo HTTP API (BREVO_API_KEY) — fallback if Gmail not configured
//   3. PM2 logs — last resort so the operator can ship the link manually
const APP_BASE_URL    = process.env.APP_BASE_URL || 'http://76.13.255.239:3000';
const MAIL_FROM_EMAIL = process.env.MAIL_FROM_EMAIL || 'no-reply@tchipa.co.uk';
const MAIL_FROM_NAME  = process.env.MAIL_FROM_NAME  || 'Tchipa';

const MAIL_HTML = (link) =>
  `<p>Bonjour,</p>` +
  `<p>Confirme ton email pour finaliser la création de ton PIN Tchipa :</p>` +
  `<p><a href="${link}">Confirmer mon email</a></p>` +
  `<p>Le lien expire dans 24h. Si tu n'es pas à l'origine de cette demande, ignore ce message.</p>` +
  `<p>— Tchipa</p>`;
const MAIL_SUBJECT = 'Tchipa — confirme ton email';

let _gmailTransporter = null;
function getGmailTransporter() {
  if (_gmailTransporter) return _gmailTransporter;
  const user = process.env.GMAIL_USER;
  const pass = (process.env.GMAIL_APP_PASSWORD || '').replace(/\s+/g, ''); // Google shows it with spaces; strip
  if (!user || !pass) return null;
  const nodemailer = require('nodemailer');
  _gmailTransporter = nodemailer.createTransport({
    service: 'gmail',
    auth: { user, pass },
  });
  return _gmailTransporter;
}

async function sendViaGmail(toEmail, link) {
  const tx = getGmailTransporter();
  if (!tx) return null;
  try {
    await tx.sendMail({
      from: `"${MAIL_FROM_NAME}" <${process.env.GMAIL_USER}>`,
      to:   toEmail,
      subject: MAIL_SUBJECT,
      html:    MAIL_HTML(link),
    });
    return { ok: true, transport: 'gmail' };
  } catch (e) {
    console.error('[mailer] Gmail SMTP error:', e.message);
    return { ok: false, transport: 'gmail', error: e.message };
  }
}

async function sendViaBrevo(toEmail, link) {
  const key = process.env.BREVO_API_KEY;
  if (!key) return null;
  try {
    const resp = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: {
        'accept': 'application/json',
        'content-type': 'application/json',
        'api-key': key,
      },
      body: JSON.stringify({
        sender:  { email: MAIL_FROM_EMAIL, name: MAIL_FROM_NAME },
        to:      [{ email: toEmail }],
        subject: MAIL_SUBJECT,
        htmlContent: MAIL_HTML(link),
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!resp.ok) {
      const txt = await resp.text().catch(() => '');
      console.error('[mailer] Brevo error', resp.status, txt.slice(0, 200));
      return { ok: false, transport: 'brevo', error: 'mail_send_failed' };
    }
    return { ok: true, transport: 'brevo' };
  } catch (e) {
    console.error('[mailer] Brevo throw', e.message);
    return { ok: false, transport: 'brevo', error: e.message };
  }
}

async function sendMagicLinkEmail(toEmail, token) {
  const link = `${APP_BASE_URL}/auth/verify-email?token=${encodeURIComponent(token)}`;
  const gmail = await sendViaGmail(toEmail, link);
  if (gmail && gmail.ok) return gmail;
  const brevo = await sendViaBrevo(toEmail, link);
  if (brevo && brevo.ok) return brevo;
  // Last resort: log the link so the operator can deliver it out-of-band.
  console.log(`[mailer] no transport succeeded — magic link for ${toEmail}: ${link}`);
  return { ok: true, transport: 'log', link };
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


// ============================================================
// /auth/* — client PIN setup + email magic-link verification
// ============================================================
// Threat model fixed here: an agent who knows the redeem_id (or the 4-digit
// claim_code, since the agent reads it on their screen) can steal the card
// before the client. The new flow moves the secret to the client: a PIN set
// at install time, bound to a verified email, and the agent must repeat the
// client's email at order time. Email is the trust anchor — squatting a
// phone with a stranger's email then breaks at /paygate/create-vcc's
// email-match check.

const PIN_RE = /^\d{4,6}$/; // 4–6 digits is enough for a memorable secret
const VERIFY_TOKEN_TTL_MS = 24 * 60 * 60 * 1000; // 24h

// POST /auth/setup-pin { phone, email, pin, device_id? }
// First-time setup OR re-setup of an unverified/expired row. If a verified
// row already exists for this phone, we refuse — the user must use
// /auth/change-pin (which requires the old PIN) or contact support to reset.
app.post('/auth/setup-pin', async (req, res) => {
  const { phone, email, pin, device_id } = req.body || {};
  const normPhone = normalizePhone(phone);
  const normEmail = normalizeEmail(email);
  if (!normPhone) return res.status(400).json({ error: 'Téléphone invalide' });
  if (!normEmail) return res.status(400).json({ error: 'Email invalide' });
  if (!pin || !PIN_RE.test(String(pin))) {
    return res.status(400).json({ error: 'PIN invalide (4 à 6 chiffres)' });
  }

  const existing = db.prepare('SELECT verified, verify_expires FROM user_pins WHERE phone = ?').get(normPhone);
  const stillPendingValid = existing && !existing.verified
    && existing.verify_expires && new Date(existing.verify_expires).getTime() > Date.now();
  if (existing && existing.verified) {
    return res.status(409).json({ error: 'PIN_ALREADY_SET', message: 'PIN déjà configuré pour ce numéro.' });
  }

  const salt    = randomBytes(16).toString('hex');
  const pinHash = hashPin(String(pin), salt);
  const emailHash = hashEmail(normEmail);
  const token = randomUUID();
  const expires = new Date(Date.now() + VERIFY_TOKEN_TTL_MS).toISOString();

  if (existing) {
    db.prepare(`
      UPDATE user_pins
         SET pin_hash=?, pin_salt=?, email=?, email_hash=?, device_id=?,
             verified=0, verify_token=?, verify_expires=?,
             pin_attempts=0, updated_at=datetime('now')
       WHERE phone=?
    `).run(pinHash, salt, normEmail, emailHash, device_id || null, token, expires, normPhone);
  } else {
    db.prepare(`
      INSERT INTO user_pins
        (phone, pin_hash, pin_salt, email, email_hash, device_id,
         verified, verify_token, verify_expires)
      VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
    `).run(normPhone, pinHash, salt, normEmail, emailHash, device_id || null, token, expires);
  }

  const mail = await sendMagicLinkEmail(normEmail, token);
  console.log(`[/auth/setup-pin] phone=${normPhone} email=${normEmail} mail=${mail.transport} ok=${mail.ok}${stillPendingValid ? ' (re-setup before expiry)' : ''}`);
  // On success we never echo the token in the response — only the email
  // inbox controller can prove they hold the address.
  return res.json({ ok: true, pendingVerification: true, mailTransport: mail.transport });
});

// GET /auth/verify-email?token=...
// Magic link landing. Marks the row verified and shows a simple HTML page.
app.get('/auth/verify-email', (req, res) => {
  const { token } = req.query;
  if (!token) return res.status(400).send('Token manquant');
  const row = db.prepare(
    'SELECT phone, verify_expires FROM user_pins WHERE verify_token = ?'
  ).get(String(token));
  if (!row) {
    return res.status(404).send('<h1>Lien invalide</h1><p>Ce lien a déjà été utilisé ou n\'existe pas.</p>');
  }
  if (row.verify_expires && new Date(row.verify_expires).getTime() < Date.now()) {
    return res.status(410).send('<h1>Lien expiré</h1><p>Recommence le setup PIN depuis l\'app Tchipa.</p>');
  }
  db.prepare(`
    UPDATE user_pins
       SET verified=1, verify_token=NULL, verify_expires=NULL, updated_at=datetime('now')
     WHERE phone=?
  `).run(row.phone);
  console.log(`[/auth/verify-email] verified phone=${row.phone}`);
  return res.send(`<!doctype html><html><head><meta charset="utf-8"><title>Tchipa — Email vérifié</title>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font-family:-apple-system,Segoe UI,sans-serif;background:#0a0e1a;color:#fff;text-align:center;padding:60px 24px}
    .ok{color:#22D3A1;font-size:64px}h1{margin:16px 0 8px}p{color:#9ca3af}</style></head>
    <body><div class="ok">✓</div><h1>Email vérifié</h1><p>Retourne dans l'app Tchipa pour continuer.</p></body></html>`);
});

// GET /auth/pin-status?phone=+213...
// Used by the client app to poll whether the email has been verified yet.
app.get('/auth/pin-status', (req, res) => {
  const normPhone = normalizePhone(req.query.phone);
  if (!normPhone) return res.status(400).json({ error: 'Téléphone invalide' });
  const row = db.prepare(
    'SELECT verified, email FROM user_pins WHERE phone = ?'
  ).get(normPhone);
  if (!row) return res.json({ exists: false, verified: false });
  return res.json({ exists: true, verified: !!row.verified, email: row.email });
});

// POST /auth/change-pin { phone, old_pin, new_pin }
app.post('/auth/change-pin', (req, res) => {
  const { phone, old_pin, new_pin } = req.body || {};
  const normPhone = normalizePhone(phone);
  if (!normPhone) return res.status(400).json({ error: 'Téléphone invalide' });
  if (!new_pin || !PIN_RE.test(String(new_pin))) {
    return res.status(400).json({ error: 'Nouveau PIN invalide (4 à 6 chiffres)' });
  }
  const row = db.prepare(
    'SELECT pin_hash, pin_salt, verified FROM user_pins WHERE phone = ?'
  ).get(normPhone);
  if (!row || !row.verified) return res.status(404).json({ error: 'PIN_NOT_SET' });
  if (!verifyPin(String(old_pin || ''), row.pin_salt, row.pin_hash)) {
    return res.status(403).json({ error: 'Ancien PIN incorrect' });
  }
  const salt = randomBytes(16).toString('hex');
  const pinHash = hashPin(String(new_pin), salt);
  db.prepare(`
    UPDATE user_pins SET pin_hash=?, pin_salt=?, pin_attempts=0, updated_at=datetime('now')
     WHERE phone=?
  `).run(pinHash, salt, normPhone);
  return res.json({ ok: true });
});


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
  const { amount, cardType = 'mastercard', holderName, phone, paypalEmail, fromAddress, flow, source, clientEmail } = req.body || {};
  const parsed = parseFloat(amount);
  if (!parsed || isNaN(parsed) || parsed < 5) {
    return res.status(400).json({ error: 'amount doit etre >= 5 USD' });
  }

  // Agent flow: gate creation on the client having a verified PIN+email
  // that matches what the agent typed. We fail BEFORE hitting PayGate so
  // a bad email doesn't burn an order / a USDT round-trip.
  const normPhonePre = normalizePhone(phone);
  let pinRow = null;
  if (normPhonePre && source === 'agent') {
    const inputEmail = normalizeEmail(clientEmail);
    if (!inputEmail) {
      return res.status(400).json({ error: 'CLIENT_EMAIL_REQUIRED', message: 'Email du client requis (le client doit l\'avoir configuré dans son app).' });
    }
    pinRow = db.prepare(
      'SELECT email_hash, verified FROM user_pins WHERE phone = ?'
    ).get(normPhonePre);
    if (!pinRow) {
      return res.status(400).json({ error: 'CLIENT_NO_PIN', message: 'Le client doit installer Tchipa et configurer son PIN avant que tu crées la commande.' });
    }
    if (!pinRow.verified) {
      return res.status(400).json({ error: 'CLIENT_EMAIL_NOT_VERIFIED', message: 'Le client n\'a pas encore confirmé son email. Demande-lui de cliquer le lien reçu.' });
    }
    if (pinRow.email_hash !== hashEmail(inputEmail)) {
      return res.status(400).json({ error: 'PHONE_EMAIL_MISMATCH', message: 'Ce numéro est lié à un autre email. Vérifie l\'email auprès du client.' });
    }
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
    // source='agent' with a verified PIN row (pinRow != null) → protected_by_pin path,
    // no claim_code generated (the client's own PIN is the secret).
    // source missing (legacy app build) → fall back to claim_code flow so we
    // don't brick older clients that don't know about PINs yet.
    const normPhone = normalizePhone(phone);
    const isAgentBridge = !!normPhone && source !== 'self';
    let claimCode = null;
    let agentOrderToken = null;
    let protectedByPin = 0;
    if (isAgentBridge) {
      agentOrderToken = randomUUID();
      if (source === 'agent' && pinRow) {
        protectedByPin = 1; // PIN gate, no per-order code
      } else {
        claimCode = String(Math.floor(1000 + Math.random() * 9000));
      }
      try {
        db.prepare(`
          INSERT INTO agent_orders
            (redeem_id, phone, holder_name, amount_usd, flow, status, claim_code, agent_order_token, protected_by_pin)
          VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?)
        `).run(data.redeem_id, normPhone, holderName || null,
               parseFloat(String(data.card_value || parsed)),
               flow === 'recharge' ? 'recharge' : 'activation',
               claimCode, agentOrderToken, protectedByPin);
        console.log('[/paygate/create-vcc] agent_order recorded for phone=' + normPhone +
          (protectedByPin ? ' (pin-gated)' : ' (code-gated, legacy)'));
      } catch (e) {
        console.error('[/paygate/create-vcc] agent_orders insert error:', e.message);
      }
    }

    // For agent flow we deliberately omit redeem_id from the response — the
    // agent only needs agentOrderToken to track status, and not knowing the
    // redeem_id prevents them from calling /paygate/check-status directly
    // (which would bypass the claim-code gate).
    return res.json({
      redeemId:         isAgentBridge ? null : data.redeem_id,
      agentOrderToken,  // null for self-serve
      cryptoAddress:    forwarder.getAddress(),
      amountUsdt:       clientAmount.toFixed(6),
      qrCode:           null,
      cardValue:        parseFloat(String(data.card_value || parsed)),
      cardCurrency:     data.card_currency || 'USD',
      cardType:         provider,
      holderName:       holderName || null,
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

// GET /paygate/check-status?redeem_id=XXX  (self-serve client polling — full response with link)
// Refuses to operate on redeem_ids that belong to an agent-flow order, so that
// even a leaked redeem_id can't be turned into a redeem_link without going
// through /cards/claim-with-code (which enforces the 4-digit gate).
app.get('/paygate/check-status', async (req, res) => {
  const { redeem_id } = req.query;
  if (!redeem_id) return res.status(400).json({ error: 'Parametre redeem_id manquant' });
  console.log('[/paygate/check-status]', redeem_id);
  const guarded = db.prepare(`
    SELECT 1 FROM agent_orders
     WHERE redeem_id = ? AND agent_order_token IS NOT NULL
  `).get(String(redeem_id));
  if (guarded) {
    return res.status(403).json({ error: 'Cette carte doit etre recuperee via l app client (code requis).' });
  }
  try {
    return res.json(await fetchPayGateStatus(String(redeem_id)));
  } catch (err) {
    console.error('[/paygate/check-status] error:', err.message);
    return res.status(502).json({ error: 'Verification echouee: ' + err.message });
  }
});

// GET /agent/order-status?token=UUID  (preferred — agent's opaque handle)
// GET /agent/order-status?redeem_id=XXX  (legacy, only for rows without a token)
// Strips redeem_link / paymentStatus regardless. Agents must never receive
// card-recovery URLs, and the redeem_id itself is treated as a secret for
// rows that have a token (otherwise the agent could just curl
// /paygate/check-status to bypass the gate).
app.get('/agent/order-status', async (req, res) => {
  const { redeem_id, token } = req.query;
  if (!redeem_id && !token) {
    return res.status(400).json({ error: 'Parametre token (ou redeem_id legacy) requis' });
  }
  // Token path: look up the real redeem_id from the token.
  let resolvedRedeemId = null;
  let agentRow = null;
  if (token) {
    agentRow = db.prepare(`
      SELECT redeem_id, phone, holder_name, delivered_at
        FROM agent_orders WHERE agent_order_token = ?
    `).get(String(token));
    if (!agentRow) return res.status(404).json({ error: 'Commande introuvable' });
    resolvedRedeemId = agentRow.redeem_id;
  } else {
    // Legacy redeem_id path — only allowed if no token is set on that row
    // (otherwise we'd be re-exposing the secret we just hid from the agent).
    agentRow = db.prepare(`
      SELECT redeem_id, phone, holder_name, delivered_at, agent_order_token
        FROM agent_orders WHERE redeem_id = ?
    `).get(String(redeem_id));
    if (agentRow && agentRow.agent_order_token) {
      return res.status(403).json({ error: 'Utiliser le token' });
    }
    resolvedRedeemId = String(redeem_id);
  }
  try {
    const s = await fetchPayGateStatus(resolvedRedeemId);
    return res.json({
      // Echo only what the agent already knows. Do not return redeem_id.
      agentOrderToken: token ? String(token) : null,
      state:           s.isReady ? 'completed' : (s.isPaid ? 'paid' : 'pending'),
      isPaid:          s.isPaid,
      isReady:         s.isReady,
      delivered:       !!(agentRow && agentRow.delivered_at),
      phone:           agentRow ? agentRow.phone : null,
      holderName:      agentRow ? agentRow.holder_name : null,
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
           created_at, delivered_at, claim_code, agent_order_token, protected_by_pin
      FROM agent_orders
     WHERE phone = ? AND status = 'completed' AND redeem_link IS NOT NULL
     ORDER BY created_at DESC
  `).all(phone);

  // Locked cards (agent flow, secret not yet validated) expose ONLY an
  // opaque cardToken — not redeem_id, not redeem_link. Two lock modes:
  //   - PIN-gated (protected_by_pin=1) → unlock via /cards/claim-with-pin
  //   - Code-gated (legacy, claim_code set) → unlock via /cards/claim-with-code
  // Delivered rows keep redeemId exposed so the legitimate device can
  // mark-delivered / re-display.
  return res.json({
    phone,
    count: rows.length,
    cards: rows.map(r => {
      const pinLocked  = !!r.protected_by_pin && !r.delivered_at;
      const codeLocked = !pinLocked && !!r.claim_code && !r.delivered_at;
      const locked     = pinLocked || codeLocked;
      return {
        redeemId:     locked ? null : r.redeem_id,
        cardToken:    r.agent_order_token,
        holderName:   r.holder_name,
        cardValue:    r.amount_usd,
        flow:         r.flow,
        redeemLink:   locked ? null : r.redeem_link,
        requiresPin:  pinLocked,
        requiresCode: codeLocked,
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

// POST /cards/claim-with-code { phone, card_token, code }
//   (legacy fallback: { phone, redeem_id, code } — only for rows without a token)
// Unlocks the redeem_link for a code-gated agent order. Phone must match the
// order's recorded phone, AND the 4-digit code must match what was issued to
// the agent. Returns redeemLink + redeemId on success so the legitimate
// client device can later call /cards/mark-delivered.
const CLAIM_MAX_ATTEMPTS = 5;
app.post('/cards/claim-with-code', (req, res) => {
  const { phone, card_token, redeem_id, code } = req.body || {};
  const normPhone = normalizePhone(phone);
  if (!normPhone || (!card_token && !redeem_id) || !code) {
    return res.status(400).json({ error: 'phone, card_token (ou redeem_id legacy) et code requis' });
  }
  const row = card_token
    ? db.prepare(`
        SELECT redeem_id, phone, redeem_link, claim_code, claim_attempts, delivered_at, agent_order_token
          FROM agent_orders
         WHERE agent_order_token = ?
      `).get(String(card_token))
    : db.prepare(`
        SELECT redeem_id, phone, redeem_link, claim_code, claim_attempts, delivered_at, agent_order_token
          FROM agent_orders
         WHERE redeem_id = ?
      `).get(String(redeem_id));
  if (!row || row.phone !== normPhone) {
    return res.status(404).json({ error: 'Commande introuvable' });
  }
  // If the row has a token, only token-based lookup is honored — otherwise
  // a leaked redeem_id could bypass the indirection we just introduced.
  if (!card_token && row.agent_order_token) {
    return res.status(403).json({ error: 'Utiliser card_token' });
  }
  if (!row.redeem_link) {
    return res.status(409).json({ error: 'Carte pas encore prete' });
  }
  if (!row.claim_code) {
    // Legacy row with no code — link is already public via /cards/for-phone.
    return res.json({ redeemLink: row.redeem_link, redeemId: row.redeem_id });
  }
  if (row.claim_attempts >= CLAIM_MAX_ATTEMPTS) {
    return res.status(429).json({ error: 'Trop de tentatives. Demandez un nouveau code a l agent.' });
  }
  if (String(code).trim() !== row.claim_code) {
    db.prepare(`
      UPDATE agent_orders
         SET claim_attempts = claim_attempts + 1, updated_at = datetime('now')
       WHERE redeem_id = ?
    `).run(row.redeem_id);
    const remaining = Math.max(0, CLAIM_MAX_ATTEMPTS - (row.claim_attempts + 1));
    return res.status(403).json({ error: 'Code invalide', attemptsRemaining: remaining });
  }
  // Success: burn the code so the link is no longer gated for this row.
  // delivered_at is left to /cards/mark-delivered (called after extraction).
  db.prepare(`
    UPDATE agent_orders
       SET claim_code = NULL, updated_at = datetime('now')
     WHERE redeem_id = ?
  `).run(row.redeem_id);
  return res.json({ redeemLink: row.redeem_link, redeemId: row.redeem_id });
});

// POST /cards/claim-with-pin { phone, card_token, pin }
// Unlocks a PIN-protected agent order. The PIN is the client's own secret
// (set at install via /auth/setup-pin), so even a malicious agent — who has
// the phone and the card_token — cannot claim. Lockout shared with the
// code path via agent_orders.claim_attempts.
app.post('/cards/claim-with-pin', (req, res) => {
  const { phone, card_token, pin } = req.body || {};
  const normPhone = normalizePhone(phone);
  if (!normPhone || !card_token || !pin) {
    return res.status(400).json({ error: 'phone, card_token et pin requis' });
  }
  const row = db.prepare(`
    SELECT redeem_id, phone, redeem_link, claim_attempts, delivered_at,
           protected_by_pin
      FROM agent_orders
     WHERE agent_order_token = ?
  `).get(String(card_token));
  if (!row || row.phone !== normPhone) {
    return res.status(404).json({ error: 'Commande introuvable' });
  }
  if (!row.protected_by_pin) {
    return res.status(409).json({ error: 'Cette carte n\'utilise pas le PIN' });
  }
  if (!row.redeem_link) {
    return res.status(409).json({ error: 'Carte pas encore prete' });
  }
  if (row.claim_attempts >= CLAIM_MAX_ATTEMPTS) {
    return res.status(429).json({ error: 'Trop de tentatives. Contacte le support.' });
  }
  const userRow = db.prepare(
    'SELECT pin_hash, pin_salt, verified FROM user_pins WHERE phone = ?'
  ).get(normPhone);
  if (!userRow || !userRow.verified) {
    return res.status(409).json({ error: 'PIN non configuré pour ce numéro' });
  }
  if (!verifyPin(String(pin), userRow.pin_salt, userRow.pin_hash)) {
    db.prepare(`
      UPDATE agent_orders
         SET claim_attempts = claim_attempts + 1, updated_at = datetime('now')
       WHERE redeem_id = ?
    `).run(row.redeem_id);
    const remaining = Math.max(0, CLAIM_MAX_ATTEMPTS - (row.claim_attempts + 1));
    return res.status(403).json({ error: 'PIN invalide', attemptsRemaining: remaining });
  }
  // Clear the protection flag so subsequent reads of /cards/for-phone return
  // the link directly (the legitimate device can re-display after restart).
  db.prepare(`
    UPDATE agent_orders
       SET protected_by_pin = 0, claim_attempts = 0, updated_at = datetime('now')
     WHERE redeem_id = ?
  `).run(row.redeem_id);
  return res.json({ redeemLink: row.redeem_link, redeemId: row.redeem_id });
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
