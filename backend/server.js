require('dotenv').config({ path: '/var/www/tchipa-api/.env' });
const forwarder = require('./forwarder');
const path = require("path");
const express = require('express');
const cors = require('cors');
const app = express();
const PORT = 3000;
// CORS: the Tchipa iPhone PWA (tchipa-pwa repo, served from GitHub Pages) calls
// this API from the browser, so it needs Access-Control-* headers. The native
// Android APK doesn't care about CORS. Allowlist the PWA origins; '*' would also
// work since no cookies/credentials are used.
app.use(cors({
  origin: [
    'https://tarik9991.github.io',
    'https://tchipa.co.uk',
    'https://www.tchipa.co.uk',
  ],
}));
app.use(express.json());

// /admin/* was open to the whole internet (found 2026-09-28): anyone could
// POST /admin/re-add-order with their own address, then /admin/manual-forward
// to make the forwarder send the VPS wallet's USDT to it. Every admin route now
// needs the ADMIN_TOKEN header; without ADMIN_TOKEN in .env they are all closed.
// The two routes the app itself calls stay open until per-agent accounts exist.
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || '';
const ADMIN_APP_ROUTES = [/^\/admin\/client-cards\b/, /^\/admin\/threeds\//];
app.use('/admin', (req, res, next) => {
  if (ADMIN_APP_ROUTES.some(r => r.test(req.originalUrl))) return next();
  const given = String(req.get('x-admin-token') || '');
  const ok = ADMIN_TOKEN.length >= 24 && given.length === ADMIN_TOKEN.length &&
             require('crypto').timingSafeEqual(Buffer.from(given), Buffer.from(ADMIN_TOKEN));
  if (!ok) return res.status(401).json({ error: 'admin token requis' });
  next();
});
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

  -- Gas loans for the self-custody Tchipa Wallet app (separate product).
  -- A wallet with USDT but no POL can't pay gas; /gas/loan drips a little POL
  -- from the VPS wallet so the app can broadcast, and the app immediately
  -- repays the POL value back in USDT. One row per loan; used for cooldown.
  CREATE TABLE IF NOT EXISTS gas_loans (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    address     TEXT NOT NULL,           -- lowercased recipient wallet
    pol_amount  REAL NOT NULL,
    fee_usdt    REAL NOT NULL,
    tx_hash     TEXT,
    created_at  INTEGER NOT NULL         -- Date.now() ms
  );
  CREATE INDEX IF NOT EXISTS idx_gas_loans_addr ON gas_loans(address, created_at);

  -- Referral / affiliate program (1% of every card a referred user activates).
  -- Phone is the join key here too (same normalizePhone() as everywhere else).
  --   referral_codes  : each phone's own shareable code (1 per phone).
  --   referrals       : who referred whom — set ONCE per referred phone.
  --   referral_earnings: one commission row per completed card (redeem_id is the
  --                      PK so crediting is idempotent — fetchPayGateStatus can
  --                      run many times without double-paying).
  CREATE TABLE IF NOT EXISTS referral_codes (
    phone       TEXT PRIMARY KEY,        -- normalizePhone()
    code        TEXT NOT NULL UNIQUE,    -- 6-char A–Z/2–9, ambiguous chars removed
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS referrals (
    phone           TEXT PRIMARY KEY,    -- the REFERRED user (normalizePhone)
    referrer_phone  TEXT NOT NULL,       -- who invited them
    referrer_code   TEXT NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_referrals_referrer ON referrals(referrer_phone);
  CREATE TABLE IF NOT EXISTS referral_earnings (
    redeem_id       TEXT PRIMARY KEY,    -- 1 commission per card order (idempotent)
    referrer_phone  TEXT NOT NULL,
    referred_phone  TEXT NOT NULL,
    card_amount     REAL NOT NULL,
    commission      REAL NOT NULL,       -- REFERRAL_RATE * card_amount, in USDT
    status          TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'paying' | 'paid'
    payout_id       INTEGER,             -- referral_payouts.id once batched into a payout
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    paid_at         TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_earnings_referrer ON referral_earnings(referrer_phone);

  -- Where a referrer wants their USDT paid. Set/changed ONLY via the PIN-gated
  -- /referral/set-payout-address (theft vector otherwise). Lowercased 0x… Polygon.
  CREATE TABLE IF NOT EXISTS referral_payout_addresses (
    phone       TEXT PRIMARY KEY,
    address     TEXT NOT NULL,
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
  -- One on-chain payout batch. The forwarder (sole USDT sender) drives the
  -- 'sending' → 'confirmed'/'failed' state machine; see forwarder.js.
  CREATE TABLE IF NOT EXISTS referral_payouts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    referrer_phone  TEXT NOT NULL,
    address         TEXT NOT NULL,
    amount          REAL NOT NULL,
    tx_hash         TEXT,
    status          TEXT NOT NULL DEFAULT 'sending',  -- 'sending' | 'confirmed' | 'failed'
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    confirmed_at    TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_payouts_referrer ON referral_payouts(referrer_phone);
  CREATE INDEX IF NOT EXISTS idx_payouts_status   ON referral_payouts(status);
`);

// Defensive migration: add payout_id if an earlier build created referral_earnings without it.
try {
  const cols = db.prepare("PRAGMA table_info(referral_earnings)").all().map(c => c.name);
  if (cols.length && !cols.includes('payout_id')) {
    db.exec("ALTER TABLE referral_earnings ADD COLUMN payout_id INTEGER");
    console.log('[db] migrated: referral_earnings.payout_id added');
  }
} catch (_) { /* table may not exist yet on a truly fresh DB — created above */ }

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
const APP_BASE_URL    = process.env.APP_BASE_URL || 'https://api.tchipa.co.uk';
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

// Normalize a phone for stable lookup. Used by both write (agent) and read
// (client) paths, so every format a person may type must land on ONE key:
// clients and agents wrote 0555…, 555…, 213555…, 00213555… and +213555… for
// the same Algerian mobile (seen in prod 2026-10-03), and an agent credit was
// refused whenever the two sides didn't type it the same way.
// - '+' or '00' prefix → international: '+' + digits ('+213 0555…' drops the 0)
// - Algerian mobile without country code (0[5-7]XXXXXXXX, [5-7]XXXXXXXX,
//   213[5-7]XXXXXXXX) → '+213…'
// - anything else without a prefix stays digits-only, as before (we can't
//   guess the country of a foreign number written locally).
// Idempotent: normalizePhone(normalizePhone(x)) === normalizePhone(x).
function normalizePhone(raw) {
  if (raw == null) return null;
  const s = String(raw).trim();
  if (!s) return null;
  let digits = s.replace(/\D/g, '');
  let intl = s.startsWith('+');
  if (!intl && digits.startsWith('00')) { digits = digits.slice(2); intl = true; }
  if (digits.length < 6) return null;
  if (intl) {
    if (/^2130[5-7]\d{8}$/.test(digits)) digits = '213' + digits.slice(4);
    return '+' + digits;
  }
  if (/^0[5-7]\d{8}$/.test(digits))     return '+213' + digits.slice(1);
  if (/^[5-7]\d{8}$/.test(digits))      return '+213' + digits;
  if (/^213[5-7]\d{8}$/.test(digits))   return '+' + digits;
  return digits;
}
console.log('[db] Orders DB ready at', DB_PATH);

// ============================================================
// Referral / affiliate program — 1% of every referred activation
// ============================================================
const REFERRAL_RATE = 0.01; // 1% of the card amount, credited to the referrer
// No I/O/O/1/0 to keep codes unambiguous when spoken/typed.
const REF_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

function genReferralCode() {
  let c = '';
  for (let i = 0; i < 6; i++) c += REF_ALPHABET[Math.floor(Math.random() * REF_ALPHABET.length)];
  return c;
}

// Idempotent per phone: returns the existing code or mints a new unique one.
function getOrCreateReferralCode(phone) {
  const existing = db.prepare('SELECT code FROM referral_codes WHERE phone = ?').get(phone);
  if (existing) return existing.code;
  for (let attempt = 0; attempt < 6; attempt++) {
    const code = genReferralCode();
    try {
      db.prepare('INSERT INTO referral_codes (phone, code) VALUES (?, ?)').run(phone, code);
      return code;
    } catch (e) {
      // UNIQUE collision on code OR a concurrent insert on phone — re-check phone.
      const now = db.prepare('SELECT code FROM referral_codes WHERE phone = ?').get(phone);
      if (now) return now.code;
      // else: code collided, loop and try another code
    }
  }
  throw new Error('could not allocate referral code');
}

// Credit the referrer 1% when a referred user's card is actually issued.
// Called from fetchPayGateStatus on completion. INSERT OR IGNORE keyed on
// redeem_id means repeated status polls never double-credit.
function creditReferral(redeemId, referredPhone, cardAmount) {
  if (!referredPhone) return;
  const ref = db.prepare('SELECT referrer_phone, referrer_code FROM referrals WHERE phone = ?').get(referredPhone);
  if (!ref) return; // this user wasn't referred by anyone
  const amt = parseFloat(cardAmount) || 0;
  if (amt <= 0) return;
  const commission = parseFloat((amt * REFERRAL_RATE).toFixed(6));
  const info = db.prepare(`
    INSERT OR IGNORE INTO referral_earnings
      (redeem_id, referrer_phone, referred_phone, card_amount, commission, status)
    VALUES (?, ?, ?, ?, ?, 'pending')
  `).run(redeemId, ref.referrer_phone, referredPhone, amt, commission);
  if (info.changes > 0) {
    console.log('[referral] +' + commission + ' USDT to ' + ref.referrer_phone +
      ' (referred ' + referredPhone + ' activated $' + amt + ')');
  }
}


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

// ── Gas-loan tunables (Tchipa Wallet app) ──────────────────────────────────
const GAS_LOAN_POL      = 0.1;   // POL dripped per loan from the VPS wallet
const GAS_FEE_USDT      = 0.40;  // flat USDT the app repays to the VPS wallet
const GAS_THRESHOLD_POL = 0.02;  // a wallet under this POL "needs" a loan
const GAS_LOAN_COOLDOWN_MS = 5 * 60 * 1000; // one loan per address / 5 min
const { isAddress } = require('ethers');

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

// PayGate answers some failures as PLAIN TEXT with HTTP 200 instead of JSON
// ("Out of stock!", "Invalid amount!", "Invalid or expired redeem_id"). Feeding
// that to resp.json() is what produced the useless
//   Unexpected token 'O', "Out of stock!" is not valid JSON
// that agents stared at for the whole July-2026 issuer outage — the app looked
// broken when the upstream was simply out of cards. Parse defensively.
const PAYGATE_TEXT_ERRORS = [
  { match: 'out of stock', code: 'CARDS_OUT_OF_STOCK', status: 503,
    message: "Cartes indisponibles chez le fournisseur. N'encaisse aucun paiement — passe en émission manuelle." },
  { match: 'invalid amount', code: 'AMOUNT_OUT_OF_RANGE', status: 400,
    message: 'Montant hors limites du fournisseur (Mastercard 5–499 USD, Visa/PayPal 5–1000 USD).' },
  { match: 'unsupported provider', code: 'UNSUPPORTED_PROVIDER', status: 400,
    message: 'Type de carte non supporté par le fournisseur.' },
  { match: 'invalid or expired', code: 'REDEEM_ID_EXPIRED', status: 410,
    message: 'Commande expirée chez le fournisseur — elle ne peut plus être payée.' },
];

class PayGateError extends Error {
  constructor({ code, status, message, raw }) {
    super(message);
    this.name = 'PayGateError';
    this.code = code; this.status = status; this.raw = raw;
  }
}

async function paygateFetchJson(url, timeoutMs = 30_000) {
  const resp = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
  const text = (await resp.text()).trim();
  try {
    return JSON.parse(text);
  } catch (_) {
    const low   = text.toLowerCase();
    const known = PAYGATE_TEXT_ERRORS.find(e => low.includes(e.match));
    if (known) throw new PayGateError({ ...known, raw: text.slice(0, 200) });
    throw new PayGateError({
      code: 'PAYGATE_BAD_RESPONSE', status: 502,
      message: 'Réponse inattendue du fournisseur de cartes.',
      raw: text.slice(0, 200),
    });
  }
}

// Uniform body so the app can branch on `error` (code) and show `message`
// (already French, already agent-facing).
function sendPayGateError(res, err, fallbackPrefix) {
  if (err instanceof PayGateError) {
    return res.status(err.status).json({ error: err.code, message: err.message, detail: err.raw });
  }
  return res.status(502).json({ error: fallbackPrefix + err.message });
}

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
    return sendPayGateError(res, err, 'Erreur PayGate VCC: ');
  }
});

// ---------------------------------------------------------------------------
// MANUAL ISSUANCE — provider-independent path
//
// Written after the July-2026 Swype/PayGate outage killed automated issuance
// for three weeks. The lesson: Tchipa must never again be unable to sell
// because one upstream API is down.
//
// Here the agent buys a card by hand on ANY provider dashboard (FlexCard,
// Kripicard, whatever is alive today) and pastes it in. The client sees the
// exact same flow as before — same phone join key, same PIN gate, same
// WebView — so nothing changes on their side.
//
// Storage rule: prefer a one-time LINK (card_link). Only store PAN/CVV when
// the provider gives no link, and then encrypted + purged on delivery, so we
// keep card data out of the database wherever possible.
// ---------------------------------------------------------------------------

// AES-256-GCM at rest for the rare case where we must hold PAN/CVV.
// Key comes from the same .env as the wallet key; without it, manual issuance
// refuses PAN input entirely and only accepts links.
const { createCipheriv, createDecipheriv } = require('crypto');

const CARD_ENC_KEY = process.env.CARD_ENC_KEY
  ? createHash('sha256').update(process.env.CARD_ENC_KEY).digest()
  : null;

function encryptCardBlob(plain) {
  if (!CARD_ENC_KEY) throw new Error('CARD_ENC_KEY absent: saisie PAN refusee');
  const iv  = randomBytes(12);
  const c   = createCipheriv('aes-256-gcm', CARD_ENC_KEY, iv);
  const enc = Buffer.concat([c.update(JSON.stringify(plain), 'utf8'), c.final()]);
  return [iv.toString('hex'), c.getAuthTag().toString('hex'), enc.toString('hex')].join(':');
}

function decryptCardBlob(blob) {
  if (!CARD_ENC_KEY) throw new Error('CARD_ENC_KEY absent');
  const [ivHex, tagHex, dataHex] = String(blob).split(':');
  const d = createDecipheriv('aes-256-gcm', CARD_ENC_KEY, Buffer.from(ivHex, 'hex'));
  d.setAuthTag(Buffer.from(tagHex, 'hex'));
  return JSON.parse(Buffer.concat([d.update(Buffer.from(dataHex, 'hex')), d.final()]).toString('utf8'));
}

// Extra columns on agent_orders for the manual path (idempotent migration).
try {
  const cols = db.prepare(`PRAGMA table_info(agent_orders)`).all().map(c => c.name);
  const add = (name, decl) => {
    if (!cols.includes(name)) {
      db.exec(`ALTER TABLE agent_orders ADD COLUMN ${name} ${decl}`);
      console.log('[migration] agent_orders.' + name + ' added');
    }
  };
  add('provider',         `TEXT`); // 'paygate' | 'flexcard' | 'manual:<name>'
  add('card_blob',        `TEXT`); // AES-GCM PAN/CVV/exp, purged on delivery
  add('issued_by',        `TEXT`); // free-text agent marker, for audit
  // The card's id ON THE PROVIDER's side. Without it the agent cannot find
  // which upstream card to top up once they have more than a few clients —
  // and top-ups are where the margin is (issuance fee is paid once, recharges
  // only cost the deposit %), so this field is what makes the business work.
  add('provider_card_id', `TEXT`);
} catch (e) {
  console.error('[migration] agent_orders:', e.message);
}

// Recharges are bookkeeping events: the card itself never changes, the client
// already holds it. We record them separately from the issuance amount so that
// "how much has this client actually put through" stays answerable.
db.exec(`
  CREATE TABLE IF NOT EXISTS manual_recharges (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    redeem_id   TEXT NOT NULL,
    amount_usd  REAL NOT NULL,
    issued_by   TEXT,
    note        TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_recharge_redeem ON manual_recharges(redeem_id);
`);

// 3DS relay: the OTP lands on the ACCOUNT OWNER's side (agent), never on the
// client's phone — that is inherent to reselling. Each request is bound to one
// card so an agent handling several clients at once knows which code goes
// where. TTL is deliberately short: an OTP that arrives late is worse than
// none, because the checkout page has already expired.
db.exec(`
  CREATE TABLE IF NOT EXISTS threeds_requests (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    redeem_id     TEXT NOT NULL,       -- agent_orders.redeem_id (which card)
    phone         TEXT NOT NULL,       -- normalizePhone(), who asked
    merchant      TEXT,                -- 'AliExpress', 'Temu'… client-supplied
    status        TEXT NOT NULL DEFAULT 'pending', -- pending|answered|expired|cancelled
    code          TEXT,                -- the OTP, written by the agent
    requested_at  TEXT NOT NULL DEFAULT (datetime('now')),
    answered_at   TEXT,
    expires_at    TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_3ds_status ON threeds_requests(status);
  CREATE INDEX IF NOT EXISTS idx_3ds_phone  ON threeds_requests(phone);
`);

const THREEDS_TTL_SEC = 300; // 5 min — matches typical OTP validity

function expireStale3ds() {
  const info = db.prepare(`
    UPDATE threeds_requests SET status = 'expired'
     WHERE status = 'pending' AND expires_at < datetime('now')
  `).run();
  return info.changes;
}

// POST /cards/manual-issue  (agent)
// Body: { phone, amountUsd, flow?, provider?, cardLink?, pan?, cvv?, exp?, holderName?, issuedBy? }
// Mirrors the agent branch of /paygate/create-vcc: same agent_orders row shape,
// same PIN/claim-code gating, so /cards/for-phone and the claim endpoints work
// unchanged. Difference: status goes straight to 'completed' — the agent has
// the card in hand, there is no upstream payment to wait for.
app.post('/cards/manual-issue', (req, res) => {
  const { phone, amountUsd, flow, provider, cardLink, pan, cvv, exp,
          holderName, issuedBy, providerCardId } = req.body || {};

  const normPhone = normalizePhone(phone);
  if (!normPhone) return res.status(400).json({ error: 'phone requis' });

  const amount = parseFloat(amountUsd);
  if (!amount || isNaN(amount) || amount <= 0) {
    return res.status(400).json({ error: 'amountUsd doit etre > 0' });
  }

  const link = cardLink ? String(cardLink).trim() : null;
  if (link && !/^https:\/\//i.test(link)) {
    return res.status(400).json({ error: 'cardLink doit etre une URL https' });
  }
  const hasPan = !!(pan && cvv && exp);
  if (!link && !hasPan) {
    return res.status(400).json({
      error: 'CARD_PAYLOAD_REQUIRED',
      message: 'Fournis soit cardLink (préférable), soit pan + cvv + exp.',
    });
  }

  // Same gate as the automated path: a client with a verified PIN gets the
  // PIN lock; otherwise fall back to a 4-digit claim code the agent relays.
  const pinRow = db.prepare(
    'SELECT verified FROM user_pins WHERE phone = ?'
  ).get(normPhone);
  const protectedByPin = pinRow && pinRow.verified ? 1 : 0;
  const claimCode = protectedByPin ? null : String(Math.floor(1000 + Math.random() * 9000));

  let cardBlob = null;
  if (!link) {
    try {
      cardBlob = encryptCardBlob({ pan: String(pan), cvv: String(cvv), exp: String(exp) });
    } catch (e) {
      return res.status(503).json({
        error: 'CARD_ENC_UNAVAILABLE',
        message: 'Stockage chiffré indisponible — utilise cardLink, ou configure CARD_ENC_KEY.',
      });
    }
  }

  const redeemId = 'man_' + randomUUID().replace(/-/g, '').slice(0, 22);
  const token    = randomUUID();

  try {
    db.prepare(`
      INSERT INTO agent_orders
        (redeem_id, phone, holder_name, amount_usd, flow, status, redeem_link,
         claim_code, agent_order_token, protected_by_pin, provider, card_blob,
         issued_by, provider_card_id)
      VALUES (?, ?, ?, ?, ?, 'completed', ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(redeemId, normPhone, holderName || null, amount,
           flow === 'recharge' ? 'recharge' : 'activation',
           link, claimCode, token, protectedByPin,
           provider ? String(provider).slice(0, 40) : 'manual',
           cardBlob, issuedBy ? String(issuedBy).slice(0, 60) : null,
           providerCardId ? String(providerCardId).slice(0, 80) : null);
  } catch (e) {
    console.error('[/cards/manual-issue] insert error:', e.message);
    return res.status(500).json({ error: 'Enregistrement impossible: ' + e.message });
  }

  console.log('[/cards/manual-issue] ' + redeemId + ' phone=' + normPhone +
    ' $' + amount + ' provider=' + (provider || 'manual') +
    (link ? ' (link)' : ' (pan, encrypted)') +
    (protectedByPin ? ' pin-gated' : ' code-gated'));

  // The automated path credits the referrer when PayGate flips the order to
  // completed. Manual issuance jumps straight to completed, so it has to do it
  // here or referrers silently stop earning.
  try { creditReferral(redeemId, normPhone, amount); }
  catch (e) { console.error('[manual-issue] referral:', e.message); }

  // redeem_id is never returned to the agent — same anti-card-theft rule as
  // the automated path. The agent tracks the order via the opaque token.
  return res.json({
    ok: true,
    agentOrderToken: token,
    claimCode,                 // null when PIN-gated
    protectedByPin: !!protectedByPin,
    deliveredVia: link ? 'link' : 'card_data',
  });
});

// GET /admin/client-cards?phone=  (agent)
// Everything the agent needs to top a client up: which upstream card, on which
// provider, how much has already gone through it. Deliberately NOT exposing
// redeem_link or card data — the agent has no business reading either.
app.get('/admin/client-cards', (req, res) => {
  const normPhone = normalizePhone(req.query.phone);
  if (!normPhone) return res.status(400).json({ error: 'phone requis' });

  const rows = db.prepare(`
    SELECT a.redeem_id, a.agent_order_token, a.holder_name, a.amount_usd,
           a.flow, a.provider, a.provider_card_id, a.created_at, a.delivered_at,
           COALESCE((SELECT SUM(r.amount_usd) FROM manual_recharges r
                      WHERE r.redeem_id = a.redeem_id), 0) AS recharged_usd,
           (SELECT COUNT(*) FROM manual_recharges r
             WHERE r.redeem_id = a.redeem_id)              AS recharge_count
      FROM agent_orders a
     WHERE a.phone = ? AND a.status = 'completed'
     ORDER BY a.created_at DESC
  `).all(normPhone);

  return res.json({
    phone: normPhone,
    count: rows.length,
    cards: rows.map(r => ({
      cardToken:      r.agent_order_token,
      holderName:     r.holder_name,
      issuedUsd:      r.amount_usd,
      rechargedUsd:   r.recharged_usd,
      totalUsd:       r.amount_usd + r.recharged_usd,
      rechargeCount:  r.recharge_count,
      provider:       r.provider,
      providerCardId: r.provider_card_id,   // what the agent types upstream
      flow:           r.flow,
      createdAt:      r.created_at,
      delivered:      !!r.delivered_at,
    })),
  });
});

// POST /cards/manual-recharge  (agent)
// Body: { cardToken, amountUsd, issuedBy?, note?, providerCardId? }
// The agent already topped the card up on the provider dashboard; this only
// records it. The card in the client's hands is unchanged — no new PAN, no
// re-delivery, which is exactly why recharges are so much cheaper than a new
// card and why this is the path that actually earns.
app.post('/cards/manual-recharge', (req, res) => {
  const { cardToken, amountUsd, issuedBy, note, providerCardId } = req.body || {};
  if (!cardToken) return res.status(400).json({ error: 'cardToken requis' });

  const amount = parseFloat(amountUsd);
  if (!amount || isNaN(amount) || amount <= 0) {
    return res.status(400).json({ error: 'amountUsd doit etre > 0' });
  }

  const card = db.prepare(`
    SELECT redeem_id, phone, provider_card_id FROM agent_orders
     WHERE agent_order_token = ? AND status = 'completed'
  `).get(String(cardToken));
  if (!card) return res.status(404).json({ error: 'Carte introuvable' });

  // Backfill the upstream id if it was missing when the card was issued.
  if (providerCardId && !card.provider_card_id) {
    db.prepare('UPDATE agent_orders SET provider_card_id = ? WHERE redeem_id = ?')
      .run(String(providerCardId).slice(0, 80), card.redeem_id);
  }

  const info = db.prepare(`
    INSERT INTO manual_recharges (redeem_id, amount_usd, issued_by, note)
    VALUES (?, ?, ?, ?)
  `).run(card.redeem_id, amount,
         issuedBy ? String(issuedBy).slice(0, 60) : null,
         note ? String(note).slice(0, 200) : null);

  db.prepare(`UPDATE agent_orders SET updated_at = datetime('now') WHERE redeem_id = ?`)
    .run(card.redeem_id);

  console.log('[/cards/manual-recharge] #' + info.lastInsertRowid +
              ' ' + card.redeem_id + ' +$' + amount + ' phone=' + card.phone);

  // Referral commission applies to recharges too — the referrer earns on the
  // client's whole lifetime, not just the first card.
  try { creditReferral(card.redeem_id + ':r' + info.lastInsertRowid, card.phone, amount); }
  catch (e) { console.error('[manual-recharge] referral:', e.message); }

  return res.json({ ok: true, rechargeId: info.lastInsertRowid });
});

// GET /cards/recharges/:cardToken  (client app — its own history)
app.get('/cards/recharges/:cardToken', (req, res) => {
  const card = db.prepare(
    'SELECT redeem_id, amount_usd FROM agent_orders WHERE agent_order_token = ?'
  ).get(String(req.params.cardToken));
  if (!card) return res.status(404).json({ error: 'Carte introuvable' });
  const rows = db.prepare(`
    SELECT amount_usd, created_at FROM manual_recharges
     WHERE redeem_id = ? ORDER BY created_at DESC
  `).all(card.redeem_id);
  const total = rows.reduce((a, r) => a + r.amount_usd, 0);
  return res.json({
    issuedUsd: card.amount_usd,
    rechargedUsd: total,
    totalUsd: card.amount_usd + total,
    recharges: rows,
  });
});

// POST /threeds/request  (client app)
// Body: { phone, cardToken, merchant? }
// The client is mid-checkout and needs the OTP. Creates a pending request
// bound to that specific card so the agent knows which code to relay.
app.post('/threeds/request', (req, res) => {
  expireStale3ds();
  const { phone, cardToken, merchant } = req.body || {};
  const normPhone = normalizePhone(phone);
  if (!normPhone || !cardToken) {
    return res.status(400).json({ error: 'phone et cardToken requis' });
  }

  const card = db.prepare(`
    SELECT redeem_id FROM agent_orders
     WHERE agent_order_token = ? AND phone = ? AND status = 'completed'
  `).get(cardToken, normPhone);
  if (!card) return res.status(404).json({ error: 'Carte introuvable pour ce numéro' });

  // One live request per card: a second checkout attempt supersedes the first.
  db.prepare(`
    UPDATE threeds_requests SET status = 'cancelled'
     WHERE redeem_id = ? AND status = 'pending'
  `).run(card.redeem_id);

  const info = db.prepare(`
    INSERT INTO threeds_requests (redeem_id, phone, merchant, expires_at)
    VALUES (?, ?, ?, datetime('now', '+${THREEDS_TTL_SEC} seconds'))
  `).run(card.redeem_id, normPhone, merchant ? String(merchant).slice(0, 60) : null);

  console.log('[/threeds/request] #' + info.lastInsertRowid + ' phone=' + normPhone +
              ' merchant=' + (merchant || '?'));
  return res.json({ ok: true, requestId: info.lastInsertRowid, ttlSeconds: THREEDS_TTL_SEC });
});

// GET /threeds/status/:id  (client app, polled)
app.get('/threeds/status/:id', (req, res) => {
  expireStale3ds();
  const row = db.prepare(`
    SELECT id, status, code, merchant, requested_at, answered_at, expires_at
      FROM threeds_requests WHERE id = ?
  `).get(req.params.id);
  if (!row) return res.status(404).json({ error: 'Demande introuvable' });
  return res.json({
    requestId: row.id,
    status:    row.status,
    code:      row.status === 'answered' ? row.code : null,
    merchant:  row.merchant,
    expiresAt: row.expires_at,
  });
});

// POST /threeds/ingest  (Telegram bridge — takes the agent out of the loop)
// Body: { cardRef, code, secret }
//
// The provider's own Telegram bot posts 3DS codes into a private group. Our
// bot sits in that group (privacy mode OFF so it can read messages), parses
// the code plus the card reference, and calls this endpoint. Attribution works
// ONLY because the agent names each card with its Tchipa order ref when
// creating it upstream — that ref comes back inside the 3DS message, so we
// know which client is waiting without a human reading anything.
//
// The manual /admin/threeds/answer path stays as the fallback for when the
// bridge is down or the provider changes its message format.
const THREEDS_INGEST_SECRET = process.env.THREEDS_INGEST_SECRET || null;

app.post('/threeds/ingest', (req, res) => {
  if (!THREEDS_INGEST_SECRET) {
    return res.status(503).json({ error: 'INGEST_DISABLED', message: 'THREEDS_INGEST_SECRET non configuré.' });
  }
  const { cardRef, code, secret } = req.body || {};
  const given    = Buffer.from(String(secret || ''), 'utf8');
  const expected = Buffer.from(THREEDS_INGEST_SECRET, 'utf8');
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) {
    return res.status(401).json({ error: 'BAD_SECRET' });
  }
  if (!cardRef || !code) return res.status(400).json({ error: 'cardRef et code requis' });
  const clean = String(code).trim();
  if (!/^[0-9]{4,10}$/.test(clean)) return res.status(400).json({ error: 'code invalide' });

  expireStale3ds();

  // cardRef is what the agent typed as the card title upstream. We match it
  // against issued_by/redeem_id so either convention works.
  const ref  = String(cardRef).trim();
  const card = db.prepare(`
    SELECT redeem_id, phone FROM agent_orders
     WHERE (redeem_id = ? OR issued_by = ?) AND status = 'completed'
     ORDER BY created_at DESC LIMIT 1
  `).get(ref, ref);
  if (!card) {
    console.warn('[/threeds/ingest] ref inconnue: ' + ref);
    return res.status(404).json({ error: 'CARD_REF_UNKNOWN', message: 'Aucune carte pour ref ' + ref });
  }

  const pending = db.prepare(`
    SELECT id FROM threeds_requests
     WHERE redeem_id = ? AND status = 'pending'
     ORDER BY requested_at DESC LIMIT 1
  `).get(card.redeem_id);

  if (pending) {
    db.prepare(`
      UPDATE threeds_requests
         SET status = 'answered', code = ?, answered_at = datetime('now')
       WHERE id = ?
    `).run(clean, pending.id);
    console.log('[/threeds/ingest] #' + pending.id + ' auto-relayed for ' + ref);
    return res.json({ ok: true, requestId: pending.id, matched: 'pending_request' });
  }

  // Code arrived before the client pressed "I need my code" (common — the
  // provider pushes as soon as the merchant challenges). Park it as an
  // already-answered row so the client's next poll finds it immediately.
  const info = db.prepare(`
    INSERT INTO threeds_requests (redeem_id, phone, merchant, status, code, answered_at, expires_at)
    VALUES (?, ?, 'auto', 'answered', ?, datetime('now'), datetime('now', '+${THREEDS_TTL_SEC} seconds'))
  `).run(card.redeem_id, card.phone, clean);
  console.log('[/threeds/ingest] #' + info.lastInsertRowid + ' pre-delivered for ' + ref);
  return res.json({ ok: true, requestId: info.lastInsertRowid, matched: 'pre_delivered' });
});

// GET /threeds/latest?phone=&cardToken=  (client app)
// Returns the freshest un-expired code for that card, whether it came from the
// bridge ahead of time or from the agent after a request.
app.get('/threeds/latest', (req, res) => {
  expireStale3ds();
  const normPhone = normalizePhone(req.query.phone);
  const cardToken = req.query.cardToken;
  if (!normPhone || !cardToken) return res.status(400).json({ error: 'phone et cardToken requis' });

  const row = db.prepare(`
    SELECT t.id, t.code, t.answered_at, t.expires_at
      FROM threeds_requests t
      JOIN agent_orders a ON a.redeem_id = t.redeem_id
     WHERE a.agent_order_token = ? AND a.phone = ?
       AND t.status = 'answered' AND t.expires_at > datetime('now')
     ORDER BY t.answered_at DESC LIMIT 1
  `).get(cardToken, normPhone);

  if (!row) return res.json({ available: false });
  return res.json({ available: true, requestId: row.id, code: row.code, expiresAt: row.expires_at });
});

// GET /admin/threeds/pending  (agent panel)
// Shows which client is waiting, on which card, for how long — the attribution
// the FlexCard Telegram feed cannot give you when several clients buy at once.
app.get('/admin/threeds/pending', (req, res) => {
  expireStale3ds();
  const rows = db.prepare(`
    SELECT t.id, t.phone, t.merchant, t.requested_at, t.expires_at,
           a.amount_usd, a.provider, a.holder_name,
           CAST((julianday(t.expires_at) - julianday('now')) * 86400 AS INTEGER) AS seconds_left
      FROM threeds_requests t
      JOIN agent_orders a ON a.redeem_id = t.redeem_id
     WHERE t.status = 'pending'
     ORDER BY t.requested_at ASC
  `).all();
  return res.json({ count: rows.length, requests: rows });
});

// POST /admin/threeds/answer  (agent panel)
// Body: { id, code }
app.post('/admin/threeds/answer', (req, res) => {
  expireStale3ds();
  const { id, code } = req.body || {};
  if (!id || !code) return res.status(400).json({ error: 'id et code requis' });
  const clean = String(code).trim();
  if (!/^[0-9]{4,10}$/.test(clean)) {
    return res.status(400).json({ error: 'code invalide (4 à 10 chiffres)' });
  }
  const row = db.prepare('SELECT status FROM threeds_requests WHERE id = ?').get(id);
  if (!row) return res.status(404).json({ error: 'Demande introuvable' });
  if (row.status !== 'pending') {
    return res.status(409).json({
      error: 'REQUEST_NOT_PENDING',
      message: 'Demande déjà ' + row.status + ' — le client doit en relancer une.',
    });
  }
  db.prepare(`
    UPDATE threeds_requests
       SET status = 'answered', code = ?, answered_at = datetime('now')
     WHERE id = ?
  `).run(clean, id);
  console.log('[/admin/threeds/answer] #' + id + ' relayed');
  return res.json({ ok: true });
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
  const agentRow = db.prepare('SELECT status, phone, amount_usd FROM agent_orders WHERE redeem_id = ?').get(redeemId);
  if (agentRow) {
    const newStatus = isReady ? 'completed' : (isPaid ? 'paid' : 'pending');
    if (newStatus !== agentRow.status || (isReady && redeemLink)) {
      db.prepare(`
        UPDATE agent_orders
           SET status = ?, redeem_link = COALESCE(?, redeem_link), updated_at = datetime('now')
         WHERE redeem_id = ?
      `).run(newStatus, redeemLink, redeemId);
    }
    // Referral payout: the card is now actually issued → credit the referrer 1%.
    // Idempotent (redeem_id PK), so repeated status polls are safe.
    if (isReady) {
      try { creditReferral(redeemId, agentRow.phone, agentRow.amount_usd); }
      catch (e) { console.error('[referral] credit error:', e.message); }
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
           protected_by_pin, card_blob
      FROM agent_orders
     WHERE agent_order_token = ?
  `).get(String(card_token));
  if (!row || row.phone !== normPhone) {
    return res.status(404).json({ error: 'Commande introuvable' });
  }
  if (!row.protected_by_pin) {
    return res.status(409).json({ error: 'Cette carte n\'utilise pas le PIN' });
  }
  // Manually-issued cards carry either a one-time link OR an encrypted
  // PAN blob — both count as "ready".
  if (!row.redeem_link && !row.card_blob) {
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

  // PAN path: decrypt once, hand it to the verified device, then WIPE it from
  // the database. The card lives on the client's phone from here — we keep no
  // copy, which is what keeps Tchipa out of PCI scope for stored card data.
  let card = null;
  if (!row.redeem_link && row.card_blob) {
    try {
      card = decryptCardBlob(row.card_blob);
      db.prepare(`
        UPDATE agent_orders
           SET card_blob = NULL, delivered_at = datetime('now'), updated_at = datetime('now')
         WHERE redeem_id = ?
      `).run(row.redeem_id);
      console.log('[/cards/claim-with-pin] card data delivered + purged for ' + row.redeem_id);
    } catch (e) {
      console.error('[/cards/claim-with-pin] decrypt failed:', e.message);
      return res.status(500).json({ error: 'Données de carte illisibles. Contacte le support.' });
    }
  }

  return res.json({
    redeemLink: row.redeem_link,
    redeemId:   row.redeem_id,
    card,       // { pan, cvv, exp } — one shot only, never returned twice
  });
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
// Referral / affiliate endpoints (client app)
// ============================================================

// GET /referral/code/:phone — the caller's own shareable code (minted on first ask).
app.get('/referral/code/:phone', (req, res) => {
  const phone = normalizePhone(req.params.phone);
  if (!phone) return res.status(400).json({ error: 'phone invalide' });
  try {
    const code = getOrCreateReferralCode(phone);
    res.json({ code, link: 'https://tchipa.co.uk/?ref=' + code });
  } catch (e) {
    console.error('[/referral/code] error:', e.message);
    res.status(500).json({ error: 'could not allocate code' });
  }
});

// POST /referral/claim { phone, code } — the caller says "I was referred by <code>".
// Set once, immutable afterwards. Can't refer yourself; code must exist.
app.post('/referral/claim', (req, res) => {
  const { phone, code } = req.body || {};
  const normPhone = normalizePhone(phone);
  const normCode  = String(code || '').trim().toUpperCase();
  if (!normPhone) return res.status(400).json({ error: 'phone invalide' });
  if (!/^[A-Z2-9]{6}$/.test(normCode)) return res.status(400).json({ error: 'BAD_CODE', message: 'Code invalide.' });

  const existing = db.prepare('SELECT referrer_code FROM referrals WHERE phone = ?').get(normPhone);
  if (existing) return res.status(409).json({ error: 'ALREADY_REFERRED', message: 'Un code de parrainage est déjà lié à ce compte.', referrerCode: existing.referrer_code });

  const owner = db.prepare('SELECT phone FROM referral_codes WHERE code = ?').get(normCode);
  if (!owner) return res.status(404).json({ error: 'CODE_NOT_FOUND', message: 'Ce code n\'existe pas.' });
  if (owner.phone === normPhone) return res.status(400).json({ error: 'SELF_REFERRAL', message: 'Tu ne peux pas utiliser ton propre code.' });

  db.prepare('INSERT INTO referrals (phone, referrer_phone, referrer_code) VALUES (?, ?, ?)')
    .run(normPhone, owner.phone, normCode);
  console.log('[referral] ' + normPhone + ' referred by ' + owner.phone + ' (' + normCode + ')');
  res.json({ ok: true, referrerCode: normCode });
});

// POST /referral/set-payout-address { phone, pin, address }
// PIN-gated so nobody can redirect another user's earnings (the only theft
// vector for auto-payout). Reuses the client's own verified PIN (user_pins).
app.post('/referral/set-payout-address', (req, res) => {
  const { phone, pin, address } = req.body || {};
  const normPhone = normalizePhone(phone);
  if (!normPhone || !pin || !address) return res.status(400).json({ error: 'phone, pin et address requis' });
  const addr = String(address).trim();
  if (!/^0x[a-fA-F0-9]{40}$/.test(addr)) {
    return res.status(400).json({ error: 'BAD_ADDRESS', message: 'Adresse Polygon invalide (0x + 40 caractères hex).' });
  }
  const userRow = db.prepare('SELECT pin_hash, pin_salt, verified FROM user_pins WHERE phone = ?').get(normPhone);
  if (!userRow || !userRow.verified) {
    return res.status(409).json({ error: 'PIN_NOT_SET', message: 'Configure ton PIN Tchipa (Profil) avant d\'ajouter une adresse de retrait.' });
  }
  if (!verifyPin(String(pin), userRow.pin_salt, userRow.pin_hash)) {
    return res.status(403).json({ error: 'BAD_PIN', message: 'PIN invalide.' });
  }
  db.prepare(`
    INSERT INTO referral_payout_addresses (phone, address, updated_at)
    VALUES (?, ?, datetime('now'))
    ON CONFLICT(phone) DO UPDATE SET address = excluded.address, updated_at = datetime('now')
  `).run(normPhone, addr.toLowerCase());
  console.log('[referral] payout address set for ' + normPhone + ' -> ' + addr.toLowerCase());
  res.json({ ok: true, address: addr.toLowerCase() });
});

// GET /referral/summary/:phone — my code, my referrals count, my earnings.
app.get('/referral/summary/:phone', (req, res) => {
  const phone = normalizePhone(req.params.phone);
  if (!phone) return res.status(400).json({ error: 'phone invalide' });
  const code = getOrCreateReferralCode(phone);
  const referredCount = db.prepare('SELECT COUNT(*) n FROM referrals WHERE referrer_phone = ?').get(phone).n;
  const totals = db.prepare(`
    SELECT
      COALESCE(SUM(commission), 0) total,
      COALESCE(SUM(CASE WHEN status IN ('pending','paying') THEN commission ELSE 0 END), 0) pending,
      COALESCE(SUM(CASE WHEN status = 'paid'                THEN commission ELSE 0 END), 0) paid
    FROM referral_earnings WHERE referrer_phone = ?
  `).get(phone);
  const earnings = db.prepare(`
    SELECT card_amount, commission, status, created_at
      FROM referral_earnings WHERE referrer_phone = ?
     ORDER BY created_at DESC LIMIT 50
  `).all(phone);
  const mine = db.prepare('SELECT referrer_code FROM referrals WHERE phone = ?').get(phone);
  const addrRow = db.prepare('SELECT address FROM referral_payout_addresses WHERE phone = ?').get(phone);
  const payouts = db.prepare(`
    SELECT amount, tx_hash, status, created_at
      FROM referral_payouts WHERE referrer_phone = ?
     ORDER BY created_at DESC LIMIT 20
  `).all(phone);
  res.json({
    code,
    link: 'https://tchipa.co.uk/?ref=' + code,
    referrerCode:  mine ? mine.referrer_code : null,  // whose code I used, if any
    referredCount,
    totalEarned:   +(+totals.total).toFixed(6),
    pendingEarned: +(+totals.pending).toFixed(6),
    paidEarned:    +(+totals.paid).toFixed(6),
    payoutAddress:   addrRow ? addrRow.address : null,
    payoutThreshold: forwarder.PAYOUT_THRESHOLD,
    payoutDailyCap:  forwarder.PAYOUT_DAILY_CAP,
    payouts,
    earnings,
  });
});

// ============================================================
// Admin endpoints (gestion manuelle VCC)
// ============================================================

// GET /admin/referral-earnings?status=pending — payout worklist for the operator.
app.get('/admin/referral-earnings', (req, res) => {
  const status = req.query.status;
  const rows = status
    ? db.prepare('SELECT * FROM referral_earnings WHERE status = ? ORDER BY created_at DESC').all(String(status))
    : db.prepare('SELECT * FROM referral_earnings ORDER BY created_at DESC').all();
  const byReferrer = db.prepare(`
    SELECT referrer_phone,
           COALESCE(SUM(CASE WHEN status='pending' THEN commission ELSE 0 END),0) pending,
           COALESCE(SUM(commission),0) total
      FROM referral_earnings GROUP BY referrer_phone ORDER BY pending DESC
  `).all();
  res.json({ count: rows.length, rows, byReferrer });
});

// POST /admin/referral-mark-paid { redeem_id? , referrer_phone? }
// Mark one earning (by redeem_id) or all pending earnings of a referrer as paid.
app.post('/admin/referral-mark-paid', (req, res) => {
  const { redeem_id, referrer_phone } = req.body || {};
  let info;
  if (redeem_id) {
    info = db.prepare("UPDATE referral_earnings SET status='paid', paid_at=datetime('now') WHERE redeem_id = ? AND status='pending'").run(String(redeem_id));
  } else if (referrer_phone) {
    info = db.prepare("UPDATE referral_earnings SET status='paid', paid_at=datetime('now') WHERE referrer_phone = ? AND status='pending'").run(normalizePhone(referrer_phone));
  } else {
    return res.status(400).json({ error: 'redeem_id ou referrer_phone requis' });
  }
  res.json({ ok: true, marked: info.changes });
});

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

// POST /debug/webview-snippet { snippet, url }
// Logs the first ~400 chars of Swype's rendered DOM when in-app card-data
// extraction times out, so we can iterate on selectors without needing
// adb logcat from end users. Best-effort: never fails the caller.
app.post('/debug/webview-snippet', (req, res) => {
  try {
    const snippet = String(req.body?.snippet || '').slice(0, 600);
    const url     = String(req.body?.url || '').slice(0, 200);
    console.log(`[webview-extract-failed] url=${url}\n  snippet=${snippet.replace(/\n/g, ' ').slice(0, 500)}`);
  } catch (_) {}
  return res.json({ ok: true });
});

// GET /wallet-address — adresse fixe du wallet VPS (pour les agents)
app.get('/wallet-address', async (req, res) => {
  const balance = await forwarder.getBalance();
  return res.json({ address: forwarder.getAddress(), network: 'Polygon', token: 'USDT', balance });
});

// ── Gas loan for the Tchipa Wallet app ─────────────────────────────────────
// A self-custody wallet that holds USDT but no POL can't pay gas. We drip a
// little POL from the VPS wallet so the app can broadcast; the app then repays
// the value in USDT (GAS_FEE_USDT) in the same flow. Anti-abuse: only fund a
// wallet that already holds USDT (so it can repay), only when it actually
// lacks POL, and at most one loan per address per cooldown window.
app.post('/gas/loan', async (req, res) => {
  try {
    const address = String((req.body && req.body.address) || '').trim();
    if (!isAddress(address)) {
      return res.status(400).json({ error: 'Adresse invalide.' });
    }
    const addrLc = address.toLowerCase();

    const usdt = await forwarder.getUsdtBalance(address);
    if (usdt < GAS_FEE_USDT) {
      return res.status(400).json({
        error: `Le wallet doit détenir au moins ${GAS_FEE_USDT} USDT pour un prêt de gas.`,
      });
    }

    const pol = await forwarder.getPolBalance(address);
    if (pol >= GAS_THRESHOLD_POL) {
      return res.json({
        funded: false, reason: 'POL suffisant', pol,
        repayTo: forwarder.getAddress(), feeUsdt: GAS_FEE_USDT,
      });
    }

    const last = db.prepare(
      'SELECT created_at FROM gas_loans WHERE address = ? ORDER BY created_at DESC LIMIT 1'
    ).get(addrLc);
    if (last && (Date.now() - last.created_at) < GAS_LOAN_COOLDOWN_MS) {
      return res.status(429).json({ error: 'Prêt déjà accordé récemment. Réessayez dans quelques minutes.' });
    }

    const txHash = await forwarder.sendPol(address, GAS_LOAN_POL);
    db.prepare(
      'INSERT INTO gas_loans (address, pol_amount, fee_usdt, tx_hash, created_at) VALUES (?,?,?,?,?)'
    ).run(addrLc, GAS_LOAN_POL, GAS_FEE_USDT, txHash, Date.now());

    console.log(`[/gas/loan] ${GAS_LOAN_POL} POL -> ${address} tx=${txHash}`);
    return res.json({
      funded: true, txHash, polAmount: GAS_LOAN_POL,
      repayTo: forwarder.getAddress(), feeUsdt: GAS_FEE_USDT,
    });
  } catch (e) {
    console.error('[/gas/loan]', e.message);
    return res.status(500).json({ error: 'Échec du prêt de gas.' });
  }
});

// ── Exchange rates (scraped from squareportsaid.com) ─────────────────────────
// The page is statically rendered Astro: the live rates ride along in the
// `props` attribute of the Calculator island as HTML-entity-encoded JSON, where
// every value is wrapped Astro-style as [typeCode, payload]. We decode the
// entities, slice out the balanced `latestRates` block, then de-Astro it.
// Cached in-process so we hit the source at most once per RATES_CACHE_TTL_MS —
// the parallel market only moves a few times a day.
const RATES_SOURCE_URL   = 'https://www.squareportsaid.com';
const RATES_CACHE_TTL_MS  = 10 * 60 * 1000;
// USDT first (it's what the wallet holds), then the rest in source order.
const RATES_ORDER = ['USDT', 'EUR', 'USD', 'GBP', 'CAD', 'CHF', 'TRY', 'CNY', 'SAR', 'AED', 'TND', 'MAD'];
let _ratesCache = { at: 0, data: null };

function htmlDecode(s) {
  return s.replace(/&quot;/g, '"').replace(/&#39;/g, "'")
          .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}

// Astro serializes each value as [typeCode, payload]; 1 = array, 0 = object/scalar.
function deAstro(v) {
  if (!Array.isArray(v)) return v;
  const [code, payload] = v;
  if (code === 1) return payload.map(deAstro);
  if (code === 0 && payload && typeof payload === 'object' && !Array.isArray(payload)) {
    const o = {};
    for (const k of Object.keys(payload)) o[k] = deAstro(payload[k]);
    return o;
  }
  return payload;
}

// Return the balanced [...] substring beginning at the first '[' on/after `from`.
function balancedSlice(str, from) {
  const start = str.indexOf('[', from);
  if (start < 0) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < str.length; i++) {
    const c = str[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
    } else if (c === '"') inStr = true;
    else if (c === '[' || c === '{') depth++;
    else if (c === ']' || c === '}') { if (--depth === 0) return str.slice(start, i + 1); }
  }
  return null;
}

function parseRatesFromHtml(html) {
  const decoded = htmlDecode(html);
  const at = decoded.indexOf('"latestRates":');
  if (at < 0) throw new Error('latestRates introuvable dans la page source');
  const slice = balancedSlice(decoded, at);
  if (!slice) throw new Error('bloc latestRates illisible');
  const flat = deAstro(JSON.parse(slice)); // { date, EUR:{buy,sell}, ..., USDT:{buy,sell} }
  const rates = [];
  for (const code of RATES_ORDER) {
    const r = flat[code];
    if (r && typeof r.buy === 'number' && typeof r.sell === 'number') {
      rates.push({ code, buy: r.buy, sell: r.sell });
    }
  }
  if (rates.length === 0) throw new Error('aucun taux exploitable');
  return { date: flat.date || null, source: 'Square Port-Saïd', rates };
}

async function fetchRates() {
  if (_ratesCache.data && (Date.now() - _ratesCache.at) < RATES_CACHE_TTL_MS) {
    return _ratesCache.data;
  }
  const resp = await fetch(RATES_SOURCE_URL, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; TchipaApp/1.0)' },
    signal: AbortSignal.timeout(20_000),
  });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  const parsed = parseRatesFromHtml(await resp.text());
  const data = { ...parsed, updatedAt: Date.now() };
  _ratesCache = { at: Date.now(), data };
  return data;
}

// GET /rates — current parallel-market rates (USDT first), DZD buy/sell.
app.get('/rates', async (req, res) => {
  try {
    res.json(await fetchRates());
  } catch (e) {
    if (_ratesCache.data) return res.json({ ..._ratesCache.data, stale: true });
    console.error('[/rates]', e.message);
    res.status(502).json({ error: 'Taux indisponibles pour le moment.' });
  }
});

// ---------------------------------------------------------------------------
// WALLET — client balance in USD, for the 1688 clothing shop (2026-09-28)
//
// PayGate/Swype are gone, so Tchipa sells products instead of cards: the client
// holds a USD balance and pays for clothes with it. Money comes in through a
// human agent (dinars via BaridiMob → the agent credits the client in USD).
//
// Rules this block enforces:
// - Amounts are INTEGER CENTS everywhere. No floats touch a balance.
// - Every change is a wallet_ledger row carrying balance_after; the wallets
//   row is only a cache of the last balance_after, updated in the SAME
//   transaction. better-sqlite3 transactions are synchronous, so two debits
//   can never interleave: a balance can't go negative.
// - Writes carry an idempotency key: an agent tapping "Créditer" twice on a
//   bad connection credits once.
// - Each agent has their own token (only its sha256 is stored). Agents are
//   PREPAID (Tarik, 2026-09-28: "l'agent me doit rien et j'avance pas de
//   l'argent que je ne possède pas"): the agent pays Tarik first, Tarik loads
//   that amount as the agent's provision (agent_settlements), and every client
//   credit is taken from it. provision = paid - credited; max_outstanding is
//   an optional overdraft, 0 by default (only Tarik's own agent account has one).
// ---------------------------------------------------------------------------
db.exec(`
  CREATE TABLE IF NOT EXISTS wallets (
    phone          TEXT PRIMARY KEY,               -- normalizePhone()
    balance_cents  INTEGER NOT NULL DEFAULT 0 CHECK (balance_cents >= 0),
    updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS wallet_ledger (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    phone               TEXT NOT NULL,
    delta_cents         INTEGER NOT NULL,          -- + credit, - debit
    balance_after_cents INTEGER NOT NULL CHECK (balance_after_cents >= 0),
    kind                TEXT NOT NULL,             -- agent_credit | purchase | refund | adjust
    agent_id            INTEGER,                   -- set for agent_credit
    ref                 TEXT,                      -- order id, BaridiMob ref…
    note                TEXT,
    dzd_amount          INTEGER,                   -- dinars the agent received (agent_credit)
    idem_key            TEXT UNIQUE,
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_ledger_phone ON wallet_ledger(phone, id);
  CREATE INDEX IF NOT EXISTS idx_ledger_agent ON wallet_ledger(agent_id, id);
  CREATE TABLE IF NOT EXISTS agents (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    name                  TEXT NOT NULL,
    phone                 TEXT,
    token_hash            TEXT NOT NULL UNIQUE,    -- sha256(token); the token is shown once
    active                INTEGER NOT NULL DEFAULT 1,
    max_outstanding_cents INTEGER NOT NULL DEFAULT 0,       -- overdraft allowed beyond the prepaid provision
    created_at            TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS agent_settlements (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id    INTEGER NOT NULL,
    amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
    note        TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS wallet_sessions (
    token_hash  TEXT PRIMARY KEY,                  -- sha256(session token)
    phone       TEXT NOT NULL,
    expires_at  TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
`);

const WALLET_SESSION_DAYS = 30;
const WALLET_PIN_MAX_ATTEMPTS = 5;         // same counter as user_pins.pin_attempts
const AGENT_CREDIT_MAX_CENTS = 50000;      // 500 $ max per single credit (typo guard)

const sha256 = s => createHash('sha256').update(String(s)).digest('hex');

function toCents(v) {
  // "12.5", 12.5, "12,50" → 1250. Rejects NaN, <= 0 and more than 2 decimals.
  const s = String(v ?? '').trim().replace(',', '.');
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const [u, d = ''] = s.split('.');
  const c = parseInt(u, 10) * 100 + parseInt((d + '00').slice(0, 2), 10);
  return c > 0 ? c : null;
}
const fromCents = c => Math.round(c) / 100;

function walletBalance(phone) {
  const r = db.prepare('SELECT balance_cents FROM wallets WHERE phone = ?').get(phone);
  return r ? r.balance_cents : 0;
}

// The only function that moves money. Throws on insufficient funds; returns
// the existing row when the idempotency key was already used.
const walletApply = db.transaction(({ phone, deltaCents, kind, agentId = null, ref = null,
                                      note = null, dzd = null, idemKey = null }) => {
  if (idemKey) {
    const prev = db.prepare('SELECT * FROM wallet_ledger WHERE idem_key = ?').get(idemKey);
    if (prev) {
      if (prev.phone !== phone || prev.delta_cents !== deltaCents) {
        const e = new Error('idempotency key reused for a different operation'); e.code = 'IDEM_CONFLICT'; throw e;
      }
      return { row: prev, replay: true };
    }
  }
  const after = walletBalance(phone) + deltaCents;
  if (after < 0) { const e = new Error('Solde insuffisant'); e.code = 'INSUFFICIENT_FUNDS'; throw e; }
  const info = db.prepare(`
    INSERT INTO wallet_ledger (phone, delta_cents, balance_after_cents, kind, agent_id, ref, note, dzd_amount, idem_key)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(phone, deltaCents, after, kind, agentId, ref, note, dzd, idemKey);
  db.prepare(`
    INSERT INTO wallets (phone, balance_cents, updated_at) VALUES (?, ?, datetime('now'))
    ON CONFLICT(phone) DO UPDATE SET balance_cents = excluded.balance_cents, updated_at = excluded.updated_at
  `).run(phone, after);
  return { row: db.prepare('SELECT * FROM wallet_ledger WHERE id = ?').get(info.lastInsertRowid), replay: false };
});

function agentOutstandingCents(agentId) {
  const credited = db.prepare(`SELECT COALESCE(SUM(delta_cents),0) s FROM wallet_ledger
                                WHERE agent_id = ? AND kind = 'agent_credit'`).get(agentId).s;
  const settled  = db.prepare('SELECT COALESCE(SUM(amount_cents),0) s FROM agent_settlements WHERE agent_id = ?')
                     .get(agentId).s;
  return credited - settled;
}

function bearer(req) {
  const m = /^Bearer\s+(\S+)$/i.exec(req.get('authorization') || '');
  return m ? m[1] : null;
}

function requireAgent(req, res, next) {
  const t = bearer(req);
  const agent = t && db.prepare('SELECT * FROM agents WHERE token_hash = ? AND active = 1').get(sha256(t));
  if (!agent) return res.status(401).json({ error: 'Agent non reconnu' });
  req.agent = agent;
  next();
}

function requireClient(req, res, next) {
  const t = bearer(req);
  const s = t && db.prepare(`SELECT phone FROM wallet_sessions
                              WHERE token_hash = ? AND expires_at > datetime('now')`).get(sha256(t));
  if (!s) return res.status(401).json({ error: 'Session expirée, reconnecte-toi avec ton PIN' });
  req.clientPhone = s.phone;
  next();
}

const ledgerView = r => ({
  id: r.id, amountUsd: fromCents(r.delta_cents), balanceAfterUsd: fromCents(r.balance_after_cents),
  kind: r.kind, ref: r.ref, note: r.note, dzd: r.dzd_amount, at: r.created_at,
});

// POST /wallet/login { phone, pin } → { token, balanceUsd }
// The client proves ownership of the phone with the PIN set at install time.
app.post('/wallet/login', (req, res) => {
  const phone = normalizePhone(req.body?.phone);
  const pin = String(req.body?.pin ?? '');
  if (!phone || !/^\d{4,8}$/.test(pin)) return res.status(400).json({ error: 'phone et pin requis' });
  const u = db.prepare('SELECT pin_hash, pin_salt, verified, pin_attempts FROM user_pins WHERE phone = ?').get(phone);
  if (!u || !u.verified) return res.status(409).json({ error: 'PIN non configuré pour ce numéro' });
  if (u.pin_attempts >= WALLET_PIN_MAX_ATTEMPTS) {
    return res.status(429).json({ error: 'Trop de PIN faux. Contacte ton agent ou le support.' });
  }
  if (!verifyPin(pin, u.pin_salt, u.pin_hash)) {
    db.prepare(`UPDATE user_pins SET pin_attempts = pin_attempts + 1, updated_at = datetime('now') WHERE phone = ?`).run(phone);
    return res.status(403).json({ error: 'PIN invalide',
                                  attemptsRemaining: Math.max(0, WALLET_PIN_MAX_ATTEMPTS - u.pin_attempts - 1) });
  }
  db.prepare(`UPDATE user_pins SET pin_attempts = 0 WHERE phone = ?`).run(phone);
  const token = randomBytes(32).toString('hex');
  db.prepare(`INSERT INTO wallet_sessions (token_hash, phone, expires_at)
              VALUES (?, ?, datetime('now', ?))`).run(sha256(token), phone, `+${WALLET_SESSION_DAYS} days`);
  res.json({ token, balanceUsd: fromCents(walletBalance(phone)) });
});

// GET /wallet/me → balance + last 50 movements (client session)
app.get('/wallet/me', requireClient, (req, res) => {
  const rows = db.prepare('SELECT * FROM wallet_ledger WHERE phone = ? ORDER BY id DESC LIMIT 50').all(req.clientPhone);
  res.json({ phone: req.clientPhone, balanceUsd: fromCents(walletBalance(req.clientPhone)),
             history: rows.map(ledgerView) });
});

// POST /wallet/logout (client session)
app.post('/wallet/logout', requireClient, (req, res) => {
  db.prepare('DELETE FROM wallet_sessions WHERE token_hash = ?').run(sha256(bearer(req)));
  res.json({ ok: true });
});

// GET /agent/me → who am I, my prepaid provision, what I can still credit
app.get('/agent/me', requireAgent, (req, res) => {
  const out = agentOutstandingCents(req.agent.id);            // credited - paid
  res.json({ id: req.agent.id, name: req.agent.name, provisionUsd: fromCents(-out),
             outstandingUsd: fromCents(Math.max(0, out)),
             maxOutstandingUsd: fromCents(req.agent.max_outstanding_cents),
             availableUsd: fromCents(Math.max(0, req.agent.max_outstanding_cents - out)) });
});

// POST /agent/wallet/credit { phone, amountUsd, dzd?, ref?, idempotencyKey }
// The agent received dinars (BaridiMob) and credits the client in USD.
app.post('/agent/wallet/credit', requireAgent, (req, res) => {
  const phone = normalizePhone(req.body?.phone);
  const cents = toCents(req.body?.amountUsd);
  const idem  = String(req.body?.idempotencyKey || '').trim();
  const dzd   = req.body?.dzd != null ? parseInt(req.body.dzd, 10) : null;
  if (!phone) return res.status(400).json({ error: 'phone requis' });
  if (!cents) return res.status(400).json({ error: 'amountUsd invalide (ex. 25 ou 25.50)' });
  if (cents > AGENT_CREDIT_MAX_CENTS) {
    return res.status(400).json({ error: `Maximum ${fromCents(AGENT_CREDIT_MAX_CENTS)} $ par crédit` });
  }
  if (idem.length < 8) return res.status(400).json({ error: 'idempotencyKey requis (8 caractères min.)' });
  // Credit only a phone whose owner can log in: a typo in the number would
  // otherwise park money on a wallet nobody can open.
  const u = db.prepare('SELECT verified FROM user_pins WHERE phone = ?').get(phone);
  if (!u || !u.verified) {
    return res.status(409).json({ error: "Ce client n'a pas encore activé Tchipa (PIN + email). Crédit refusé." });
  }
  // Ceiling check is outside walletApply, so an idempotent replay is let through first.
  const prev = db.prepare('SELECT * FROM wallet_ledger WHERE idem_key = ?').get(`agent:${req.agent.id}:${idem}`);
  if (!prev && agentOutstandingCents(req.agent.id) + cents > req.agent.max_outstanding_cents) {
    return res.status(403).json({ error: 'Provision insuffisante : recharge ta provision auprès de Tchipa.',
                                  availableUsd: fromCents(Math.max(0, req.agent.max_outstanding_cents
                                                                  - agentOutstandingCents(req.agent.id))) });
  }
  try {
    const { row, replay } = walletApply({ phone, deltaCents: cents, kind: 'agent_credit', agentId: req.agent.id,
      ref: req.body?.ref ? String(req.body.ref).slice(0, 80) : null, dzd: Number.isFinite(dzd) ? dzd : null,
      idemKey: `agent:${req.agent.id}:${idem}` });
    if (!replay) console.log(`[wallet] agent ${req.agent.id} credite ${fromCents(cents)} $ -> ${phone}`);
    res.json({ ok: true, replay, entry: ledgerView(row) });
  } catch (e) {
    if (e.code === 'IDEM_CONFLICT') return res.status(409).json({ error: 'Clé déjà utilisée pour une autre opération' });
    console.error('[wallet] credit:', e.message);
    res.status(500).json({ error: 'Erreur interne' });
  }
});

// GET /agent/credits → my last 100 credits
app.get('/agent/credits', requireAgent, (req, res) => {
  const rows = db.prepare(`SELECT * FROM wallet_ledger WHERE agent_id = ? AND kind = 'agent_credit'
                           ORDER BY id DESC LIMIT 100`).all(req.agent.id);
  res.json({ credits: rows.map(r => ({ ...ledgerView(r), phone: r.phone })) });
});

// POST /admin/agents { name, phone?, maxOutstandingUsd? } → token (shown ONCE)
app.post('/admin/agents', (req, res) => {
  const name = String(req.body?.name || '').trim();
  if (!name) return res.status(400).json({ error: 'name requis' });
  const max = req.body?.maxOutstandingUsd != null ? toCents(req.body.maxOutstandingUsd) : 0;
  if (max === null) return res.status(400).json({ error: 'maxOutstandingUsd invalide' });
  const token = 'agt_' + randomBytes(24).toString('hex');
  const info = db.prepare('INSERT INTO agents (name, phone, token_hash, max_outstanding_cents) VALUES (?, ?, ?, ?)')
    .run(name, normalizePhone(req.body?.phone) || null, sha256(token), max);
  res.json({ id: info.lastInsertRowid, name, token, note: "Donne ce code à l'agent : il ne sera plus jamais affiché." });
});

// GET /admin/agents → every agent with what they owe
app.get('/admin/agents', (req, res) => {
  const rows = db.prepare('SELECT id, name, phone, active, max_outstanding_cents, created_at FROM agents').all();
  res.json({ agents: rows.map(a => ({ id: a.id, name: a.name, phone: a.phone, active: !!a.active,
    provisionUsd: fromCents(-agentOutstandingCents(a.id)), maxOutstandingUsd: fromCents(a.max_outstanding_cents),
    createdAt: a.created_at })) });
});

// POST /admin/agents/:id/provision { amountUsd, note? } → the agent paid Tarik: load their provision
// (/settle kept as an alias for the first version of this route)
app.post(['/admin/agents/:id/provision', '/admin/agents/:id/settle'], (req, res) => {
  const id = parseInt(req.params.id, 10);
  const cents = toCents(req.body?.amountUsd);
  if (!db.prepare('SELECT 1 FROM agents WHERE id = ?').get(id)) return res.status(404).json({ error: 'Agent introuvable' });
  if (!cents) return res.status(400).json({ error: 'amountUsd invalide' });
  db.prepare('INSERT INTO agent_settlements (agent_id, amount_cents, note) VALUES (?, ?, ?)')
    .run(id, cents, req.body?.note ? String(req.body.note).slice(0, 200) : null);
  res.json({ ok: true, provisionUsd: fromCents(-agentOutstandingCents(id)) });
});

// POST /admin/agents/:id/active { active: bool } → block / unblock an agent
app.post('/admin/agents/:id/active', (req, res) => {
  const info = db.prepare('UPDATE agents SET active = ? WHERE id = ?').run(req.body?.active ? 1 : 0, parseInt(req.params.id, 10));
  if (!info.changes) return res.status(404).json({ error: 'Agent introuvable' });
  res.json({ ok: true });
});

// GET /admin/wallets → every non-empty wallet
app.get('/admin/wallets', (req, res) => {
  const rows = db.prepare('SELECT * FROM wallets WHERE balance_cents > 0 ORDER BY balance_cents DESC').all();
  const total = rows.reduce((s, r) => s + r.balance_cents, 0);
  res.json({ totalUsd: fromCents(total), wallets: rows.map(r => ({ phone: r.phone, balanceUsd: fromCents(r.balance_cents),
                                                                    updatedAt: r.updated_at })) });
});

// POST /admin/wallet/adjust { phone, amountUsd (+/-), note, idempotencyKey } → manual correction
app.post('/admin/wallet/adjust', (req, res) => {
  const phone = normalizePhone(req.body?.phone);
  const raw = String(req.body?.amountUsd ?? '').trim();
  const neg = raw.startsWith('-');
  const cents = toCents(neg ? raw.slice(1) : raw);
  const note = String(req.body?.note || '').trim();
  const idem = String(req.body?.idempotencyKey || '').trim();
  if (!phone || !cents || !note || idem.length < 8) {
    return res.status(400).json({ error: 'phone, amountUsd, note et idempotencyKey requis' });
  }
  try {
    const { row, replay } = walletApply({ phone, deltaCents: neg ? -cents : cents, kind: 'adjust', note,
                                          idemKey: `admin:${idem}` });
    res.json({ ok: true, replay, entry: ledgerView(row) });
  } catch (e) {
    if (e.code === 'INSUFFICIENT_FUNDS') return res.status(409).json({ error: 'Solde insuffisant pour ce retrait' });
    if (e.code === 'IDEM_CONFLICT') return res.status(409).json({ error: 'Clé déjà utilisée pour une autre opération' });
    res.status(500).json({ error: 'Erreur interne' });
  }
});

// ---------------------------------------------------------------------------
// SHOP — 1688 clothing catalogue paid with the wallet (2026-09-28)
//
// catalogue.db is built offline by ~/tchipa-boutique/import_catalogue.py (TMAPI)
// and copied next to this file; it is opened READ-ONLY here. Prices shown and
// charged always come from it: the app sends product + variant, never a price.
// Each 1688 variant (colour x size) has its own price — vendors hide a cheap
// accessory among the variants to advertise a bait price, so we never charge
// "the product price", only the chosen variant's.
// ---------------------------------------------------------------------------
const CATALOGUE_PATH = path.join(__dirname, 'catalogue.db');
let catalogue = null;
function cat() {
  if (!catalogue && require('fs').existsSync(CATALOGUE_PATH)) {
    catalogue = new Database(CATALOGUE_PATH, { readonly: true });
  }
  return catalogue;
}
const SHOP_CATEGORIES = ['Femme', 'Homme', 'Hijab', 'Abaya', 'Enfants'];
const SHOP_PAGE = 20;
const SHOP_MAX_QTY = 10;
const SHOP_STATUSES = ['payee', 'achetee', 'entrepot', 'expediee', 'livree', 'annulee'];

db.exec(`
  CREATE TABLE IF NOT EXISTS shop_orders (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    phone        TEXT NOT NULL,
    total_cents  INTEGER NOT NULL,
    status       TEXT NOT NULL DEFAULT 'payee',
    full_name    TEXT NOT NULL,
    contact_phone TEXT NOT NULL,
    wilaya       TEXT NOT NULL,
    commune      TEXT,
    address      TEXT,
    tracking     TEXT,
    admin_note   TEXT,
    idem_key     TEXT UNIQUE,
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_shop_orders_phone ON shop_orders(phone, id);
  CREATE TABLE IF NOT EXISTS shop_order_items (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id        INTEGER NOT NULL,
    item_id         INTEGER NOT NULL,          -- 1688 offer id
    title           TEXT,
    image           TEXT,
    variant         TEXT NOT NULL,             -- 1688 props_names, e.g. "Color:Black;Size:L"
    qty             INTEGER NOT NULL,
    unit_cents      INTEGER NOT NULL,          -- client price charged
    cost_cents      INTEGER,                   -- our cost (1688 + agent + freight), for margin
    url_1688        TEXT
  );
`);

function productRow(id) {
  return cat() && cat().prepare('SELECT * FROM produits WHERE item_id = ?').get(id);
}
function productTitle(p) { return p.titre_fr || p.titre_en; }
function parseVariant(name) {
  // "Color:White leopard print;Size:L" -> { Color: 'White leopard print', Size: 'L' }
  const o = {};
  for (const part of String(name || '').split(';')) {
    const i = part.indexOf(':');
    if (i > 0) o[part.slice(0, i).trim()] = part.slice(i + 1).trim();
  }
  return o;
}
const productCard = p => ({
  id: p.item_id, title: productTitle(p), category: p.categorie, sub: p.sous_categorie || null,
  image: (JSON.parse(p.images || '[]')[0]) || null,
  priceFrom: p.prix_des_usd, priceTo: p.prix_max_usd, sold: p.ventes_n || 0,
});
// Sub-categories (sous_categorie) and 1688 sales (ventes_n) are computed offline by
// ~/tchipa-boutique/classer.py. Older catalogue files may lack them: checked once.
let catHasSubs = null;
function hasSubs() {
  if (catHasSubs === null && cat()) {
    catHasSubs = cat().prepare('PRAGMA table_info(produits)').all().some(c => c.name === 'sous_categorie');
  }
  return !!catHasSubs;
}
const SHOP_MIN_SUB = 12;   // smaller sub-categories stay reachable under "Tout"
const SHOP_SORTS = {
  pop: 'ventes_n DESC, rowid', price_asc: 'prix_des_usd ASC, rowid', price_desc: 'prix_des_usd DESC, rowid',
};

// GET /shop/categories → [{name, count, image, subs:[{name, count, image}]}]
app.get('/shop/categories', (req, res) => {
  if (!cat()) return res.json({ categories: [] });
  const counts = Object.fromEntries(cat().prepare('SELECT categorie c, COUNT(*) n FROM produits GROUP BY 1').all()
                                      .map(r => [r.c, r.n]));
  const cover = (where, args) => {
    const r = cat().prepare(`SELECT images FROM produits WHERE ${where} ORDER BY ${hasSubs() ? 'ventes_n DESC' : 'rowid'} LIMIT 1`).get(...args);
    return r ? (JSON.parse(r.images || '[]')[0] || null) : null;
  };
  res.json({ categories: SHOP_CATEGORIES.filter(c => counts[c]).map(c => ({
    name: c, count: counts[c], image: cover('categorie = ?', [c]),
    subs: hasSubs()
      ? cat().prepare(`SELECT sous_categorie s, COUNT(*) n FROM produits WHERE categorie = ? AND sous_categorie IS NOT NULL
                       GROUP BY 1 HAVING n >= ? ORDER BY n DESC`).all(c, SHOP_MIN_SUB)
          .map(r => ({ name: r.s, count: r.n, image: cover('categorie = ? AND sous_categorie = ?', [c, r.s]) }))
      : [],
  })) });
});

// GET /shop/products?category=&sub=&q=&sort=pop|price_asc|price_desc&max=&page=1  → 20 per page
app.get('/shop/products', (req, res) => {
  if (!cat()) return res.json({ items: [], hasMore: false });
  const page = Math.max(1, parseInt(req.query.page, 10) || 1);
  const where = [], args = [];
  if (req.query.category) { where.push('categorie = ?'); args.push(String(req.query.category)); }
  if (req.query.sub && hasSubs()) { where.push('sous_categorie = ?'); args.push(String(req.query.sub)); }
  const max = parseFloat(req.query.max);
  if (max > 0) { where.push('prix_des_usd <= ?'); args.push(max); }
  const q = String(req.query.q || '').trim().slice(0, 60);
  if (q) {
    for (const w of q.split(/\s+/).slice(0, 5)) {
      where.push('(titre_fr LIKE ? OR titre_en LIKE ?)'); args.push(`%${w}%`, `%${w}%`);
    }
  }
  const order = hasSubs() ? (SHOP_SORTS[req.query.sort] || SHOP_SORTS.pop) : 'rowid';
  const rows = cat().prepare(`SELECT * FROM produits ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
                              ORDER BY ${order} LIMIT ? OFFSET ?`).all(...args, SHOP_PAGE + 1, (page - 1) * SHOP_PAGE);
  res.json({ items: rows.slice(0, SHOP_PAGE).map(productCard), hasMore: rows.length > SHOP_PAGE, page });
});

// GET /shop/products/:id → full sheet with every variant and its price
app.get('/shop/products/:id', (req, res) => {
  const p = productRow(parseInt(req.params.id, 10));
  if (!p) return res.status(404).json({ error: 'Produit introuvable' });
  const variants = JSON.parse(p.variantes_prix || '[]').filter(v => v.stock > 0).map(v => ({
    name: v.nom, props: parseVariant(v.nom), priceUsd: v.prix_client_usd, stock: v.stock,
  }));
  res.json({ ...productCard(p), titleEn: p.titre_en, images: JSON.parse(p.images || '[]'), video: p.video,
             weightKg: p.poids_kg, options: JSON.parse(p.variantes || '{}'), variants });
});

function priceVariant(p, variantName) {
  const v = JSON.parse(p.variantes_prix || '[]').find(x => x.nom === variantName);
  if (!v || !(v.stock > 0)) return null;
  return { unitCents: Math.round(v.prix_client_usd * 100), costCents: Math.round(v.revient_usd * 100) };
}

// POST /shop/orders { items:[{productId, variant, qty}], delivery:{fullName, phone, wilaya, commune?, address?},
//                     idempotencyKey }  (client session) → pays with the wallet
app.post('/shop/orders', requireClient, (req, res) => {
  const items = Array.isArray(req.body?.items) ? req.body.items.slice(0, 30) : [];
  const d = req.body?.delivery || {};
  const idem = String(req.body?.idempotencyKey || '').trim();
  if (!items.length) return res.status(400).json({ error: 'Panier vide' });
  if (idem.length < 8) return res.status(400).json({ error: 'idempotencyKey requis' });
  const fullName = String(d.fullName || '').trim(), wilaya = String(d.wilaya || '').trim();
  const contact = String(d.phone || '').trim();
  if (!fullName || !wilaya || !contact) {
    return res.status(400).json({ error: 'Nom, téléphone et wilaya de livraison requis' });
  }
  const lines = [];
  for (const it of items) {
    const qty = parseInt(it.qty, 10);
    if (!(qty >= 1 && qty <= SHOP_MAX_QTY)) return res.status(400).json({ error: `Quantité 1 à ${SHOP_MAX_QTY}` });
    const p = productRow(parseInt(it.productId, 10));
    const pr = p && priceVariant(p, String(it.variant || ''));
    if (!pr) return res.status(409).json({ error: 'Un article n\'est plus disponible', productId: it.productId });
    lines.push({ p, variant: String(it.variant), qty, ...pr });
  }
  const total = lines.reduce((s, l) => s + l.unitCents * l.qty, 0);
  const already = db.prepare('SELECT id FROM shop_orders WHERE idem_key = ?').get(`order:${req.clientPhone}:${idem}`);
  if (already) return res.json({ ok: true, replay: true, orderId: already.id });
  try {
    const orderId = db.transaction(() => {
      const info = db.prepare(`INSERT INTO shop_orders (phone, total_cents, full_name, contact_phone, wilaya, commune,
                                 address, idem_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(req.clientPhone, total, fullName.slice(0, 80), contact.slice(0, 30), wilaya.slice(0, 40),
             String(d.commune || '').slice(0, 60) || null, String(d.address || '').slice(0, 200) || null,
             `order:${req.clientPhone}:${idem}`);
      const oid = info.lastInsertRowid;
      const ins = db.prepare(`INSERT INTO shop_order_items (order_id, item_id, title, image, variant, qty, unit_cents,
                                cost_cents, url_1688) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`);
      for (const l of lines) {
        ins.run(oid, l.p.item_id, productTitle(l.p), JSON.parse(l.p.images || '[]')[0] || null, l.variant, l.qty,
                l.unitCents, l.costCents * l.qty, l.p.url);
      }
      // Throws INSUFFICIENT_FUNDS -> the whole order rolls back.
      walletApply({ phone: req.clientPhone, deltaCents: -total, kind: 'purchase', ref: `commande #${oid}`,
                    idemKey: `purchase:${oid}` });
      return oid;
    })();
    console.log(`[shop] commande #${orderId} ${req.clientPhone} ${fromCents(total)} $`);
    res.json({ ok: true, orderId, totalUsd: fromCents(total), balanceUsd: fromCents(walletBalance(req.clientPhone)) });
  } catch (e) {
    if (e.code === 'INSUFFICIENT_FUNDS') {
      return res.status(402).json({ error: 'Solde insuffisant', totalUsd: fromCents(total),
                                    balanceUsd: fromCents(walletBalance(req.clientPhone)) });
    }
    console.error('[shop] order:', e.message);
    res.status(500).json({ error: 'Erreur interne' });
  }
});

function orderView(o) {
  const items = db.prepare('SELECT * FROM shop_order_items WHERE order_id = ?').all(o.id);
  return { id: o.id, status: o.status, totalUsd: fromCents(o.total_cents), createdAt: o.created_at,
           updatedAt: o.updated_at, tracking: o.tracking, wilaya: o.wilaya,
           items: items.map(i => ({ productId: i.item_id, title: i.title, image: i.image, variant: i.variant,
                                    props: parseVariant(i.variant), qty: i.qty, unitUsd: fromCents(i.unit_cents) })) };
}

// GET /shop/orders (client session) → my orders
app.get('/shop/orders', requireClient, (req, res) => {
  const rows = db.prepare('SELECT * FROM shop_orders WHERE phone = ? ORDER BY id DESC LIMIT 50').all(req.clientPhone);
  res.json({ orders: rows.map(orderView) });
});

// GET /admin/shop/orders?status= → orders to buy, with 1688 links and our cost
app.get('/admin/shop/orders', (req, res) => {
  const st = req.query.status ? String(req.query.status) : null;
  const rows = db.prepare(`SELECT * FROM shop_orders ${st ? 'WHERE status = ?' : ''} ORDER BY id DESC LIMIT 200`)
                 .all(...(st ? [st] : []));
  res.json({ orders: rows.map(o => {
    const items = db.prepare('SELECT * FROM shop_order_items WHERE order_id = ?').all(o.id);
    const cost = items.reduce((s, i) => s + (i.cost_cents || 0), 0);
    return { ...orderView(o), phone: o.phone, fullName: o.full_name, contactPhone: o.contact_phone,
             commune: o.commune, address: o.address, adminNote: o.admin_note,
             costUsd: fromCents(cost), marginUsd: fromCents(o.total_cents - cost),
             links1688: items.map(i => ({ url: i.url_1688, variant: i.variant, qty: i.qty })) };
  }) });
});

// POST /admin/shop/orders/:id/status { status, tracking?, note? } — 'annulee' refunds the wallet
app.post('/admin/shop/orders/:id/status', (req, res) => {
  const id = parseInt(req.params.id, 10);
  const status = String(req.body?.status || '');
  if (!SHOP_STATUSES.includes(status)) return res.status(400).json({ error: 'status: ' + SHOP_STATUSES.join(' | ') });
  const o = db.prepare('SELECT * FROM shop_orders WHERE id = ?').get(id);
  if (!o) return res.status(404).json({ error: 'Commande introuvable' });
  if (o.status === 'annulee') return res.status(409).json({ error: 'Commande déjà annulée et remboursée' });
  db.transaction(() => {
    db.prepare(`UPDATE shop_orders SET status = ?, tracking = COALESCE(?, tracking), admin_note = COALESCE(?, admin_note),
                updated_at = datetime('now') WHERE id = ?`)
      .run(status, req.body?.tracking ? String(req.body.tracking).slice(0, 80) : null,
           req.body?.note ? String(req.body.note).slice(0, 200) : null, id);
    if (status === 'annulee') {
      walletApply({ phone: o.phone, deltaCents: o.total_cents, kind: 'refund', ref: `commande #${id}`,
                    idemKey: `refund:${id}` });
    }
  })();
  res.json({ ok: true, order: orderView(db.prepare('SELECT * FROM shop_orders WHERE id = ?').get(id)) });
});

// One-time (idempotent) rewrite of every stored phone to normalizePhone()'s
// current output, run after all tables exist. Rows keyed by phone that now
// collide are the same person registered under two formats (same email_hash
// in prod): for user_pins keep the verified row, then the most recent; other
// phone-keyed tables are left untouched on collision and logged.
(function migratePhones() {
  const tx = db.transaction(() => {
    let changed = 0;
    // user_pins: merge duplicates first.
    const groups = new Map();
    for (const r of db.prepare('SELECT phone, verified, updated_at FROM user_pins').all()) {
      const k = normalizePhone(r.phone);
      if (k) (groups.get(k) || groups.set(k, []).get(k)).push(r);
    }
    for (const [k, rows] of groups) {
      if (rows.length === 1 && rows[0].phone === k) continue;
      rows.sort((a, b) => (b.verified - a.verified) || String(b.updated_at).localeCompare(String(a.updated_at)));
      const [keep, ...drop] = rows;
      for (const r of drop) {
        db.prepare('DELETE FROM user_pins WHERE phone = ?').run(r.phone);
        console.log(`[migration] user_pins: ${r.phone} merged into ${k} (kept ${keep.phone})`);
      }
      if (keep.phone !== k) { db.prepare('UPDATE user_pins SET phone = ? WHERE phone = ?').run(k, keep.phone); changed++; }
    }
    // Every other phone column.
    const tables = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all().map(t => t.name);
    for (const t of tables) {
      if (t === 'user_pins') continue;
      for (const c of db.prepare(`PRAGMA table_info(${t})`).all().filter(c => /phone/.test(c.name))) {
        for (const { v } of db.prepare(`SELECT DISTINCT ${c.name} AS v FROM ${t} WHERE ${c.name} IS NOT NULL`).all()) {
          const k = normalizePhone(v);
          if (!k || k === v) continue;
          try { changed += db.prepare(`UPDATE ${t} SET ${c.name} = ? WHERE ${c.name} = ?`).run(k, v).changes; }
          catch (e) { console.error(`[migration] ${t}.${c.name} ${v} -> ${k} skipped: ${e.message}`); }
        }
      }
    }
    if (changed) console.log(`[migration] phones normalized: ${changed} row(s)`);
  });
  try { tx(); } catch (e) { console.error('[migration] phones:', e.message); }
})();

app.listen(PORT, () => {
  console.log(`Tchipa API actif sur http://localhost:${PORT}`);
});
