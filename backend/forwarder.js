'use strict';
const fs   = require('fs');
const path = require('path');
const { ethers } = require('ethers');
const Database  = require('better-sqlite3');

try {
  fs.readFileSync('/var/www/tchipa-api/.env', 'utf8')
    .split('\n')
    .forEach(line => {
      const eq = line.indexOf('=');
      if (eq > 0) {
        const k = line.slice(0, eq).trim();
        const v = line.slice(eq + 1).trim();
        if (k && !process.env[k]) process.env[k] = v;
      }
    });
} catch (e) {
  console.error('[Forwarder] Cannot read .env:', e.message);
}

const USDT_POLYGON  = '0xc2132D05D31c914a87C6611C10748AEb04B58e8F';
const USDT_DECIMALS = 6;
const USDT_ABI = [
  'function transfer(address to, uint256 amount) returns (bool)',
  'function balanceOf(address) view returns (uint256)',
];
const TRANSFER_TOPIC = ethers.id('Transfer(address,address,uint256)');

const PUBLIC_RPCS = [
  'https://polygon.drpc.org',
  'https://polygon-bor-rpc.publicnode.com',
  'https://1rpc.io/matic',
];
const RPC_URLS = process.env.POLYGON_RPC
  ? [process.env.POLYGON_RPC, ...PUBLIC_RPCS]
  : PUBLIC_RPCS;

const POLL_INTERVAL_MS  = 15_000;
const BLOCK_WINDOW      = 9;        // Alchemy free tier limite a 10 blocks
const AMOUNT_TOLERANCE  = 0.000005; // USDT, match strict (le suffix unique fait l'unicite)
const MIN_FORWARD       = 0.50;     // USDT, ignore poussiere
const SUFFIX_STEP       = 0.000001; // 1 micro-USDT par unite de suffix
const SUFFIX_MAX        = 9999;     // 9999 commandes uniques par cycle

// ── DB schema (migration safe) ───────────────────────────────────────────────
const db = new Database(path.join(__dirname, 'orders.db'));
db.exec(`
  CREATE TABLE IF NOT EXISTS pending_orders (
    redeem_id       TEXT PRIMARY KEY,
    client_amount   REAL NOT NULL,
    paygate_amount  REAL NOT NULL,
    paygate_address TEXT NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS processed_txs (
    tx_hash      TEXT NOT NULL,
    log_index    INTEGER NOT NULL,
    redeem_id    TEXT,
    from_address TEXT,
    amount       REAL,
    forward_tx   TEXT,
    status       TEXT,
    processed_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (tx_hash, log_index)
  );
  CREATE TABLE IF NOT EXISTS forwarder_state (
    key   TEXT PRIMARY KEY,
    value TEXT
  );
`);

// Migration: add from_address column if missing
try {
  const cols = db.prepare(`PRAGMA table_info(pending_orders)`).all().map(c => c.name);
  if (!cols.includes('from_address')) {
    db.exec(`ALTER TABLE pending_orders ADD COLUMN from_address TEXT`);
    console.log('[Forwarder] Migration: added from_address to pending_orders');
  }
} catch (e) {
  console.error('[Forwarder] Migration error:', e.message);
}

const stateGet = (k) => {
  const r = db.prepare('SELECT value FROM forwarder_state WHERE key=?').get(k);
  return r ? r.value : null;
};
const stateSet = (k, v) => {
  db.prepare('INSERT OR REPLACE INTO forwarder_state (key,value) VALUES (?,?)').run(k, String(v));
};

// ── State ────────────────────────────────────────────────────────────────────
let rpcIndex      = 0;
let walletKey     = null;
let walletAddress = null;
let errCount      = 0;

// ── Raw fetch-based RPC ──────────────────────────────────────────────────────
async function rpcCall(method, params = []) {
  const url  = RPC_URLS[rpcIndex];
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
  const res  = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error('HTTP ' + res.status);
  const json = await res.json();
  if (json.error) throw new Error(json.error.message || JSON.stringify(json.error));
  return json.result;
}

async function getUsdtBalance(address) {
  const data = '0x70a08231' + address.slice(2).padStart(64, '0');
  const hex  = await rpcCall('eth_call', [{ to: USDT_POLYGON, data }, 'latest']);
  return parseFloat(ethers.formatUnits(BigInt(hex), USDT_DECIMALS));
}

async function getBlockNumber() {
  const hex = await rpcCall('eth_blockNumber', []);
  return parseInt(hex, 16);
}

function makeProvider() {
  const provider = new ethers.JsonRpcProvider(RPC_URLS[rpcIndex]);
  provider.pollingInterval = 99_999_999;
  return provider;
}

async function sendUsdt(toAddress, amount) {
  const provider = makeProvider();
  const wallet   = new ethers.Wallet(walletKey, provider);
  const contract = new ethers.Contract(USDT_POLYGON, USDT_ABI, wallet);
  const wei      = ethers.parseUnits(amount.toFixed(6), USDT_DECIMALS);
  const tx       = await contract.transfer(toAddress, wei);
  await tx.wait(1);
  return tx.hash;
}

function nextRpc() {
  rpcIndex = (rpcIndex + 1) % RPC_URLS.length;
  console.log('[Forwarder] Changement RPC ->', RPC_URLS[rpcIndex]);
}

// ── Match logic ──────────────────────────────────────────────────────────────
function findOrderByFrom(fromAddr) {
  if (!fromAddr) return null;
  const r = db.prepare(`
    SELECT * FROM pending_orders
    WHERE LOWER(from_address) = LOWER(?)
    ORDER BY created_at ASC LIMIT 1
  `).get(fromAddr);
  return r || null;
}

function findOrderByAmount(received) {
  // Match strict: le suffix unique (positions 5-6 decimales) garantit l'unicite
  const all = db.prepare(`SELECT * FROM pending_orders ORDER BY created_at ASC`).all();
  let best = null, bestDiff = Infinity;
  for (const r of all) {
    const diff = Math.abs(r.client_amount - received);
    if (diff <= AMOUNT_TOLERANCE && diff < bestDiff) {
      best = r; bestDiff = diff;
    }
  }
  return best;
}

// Compteur atomique pour suffix unique (1..SUFFIX_MAX, wrap-around)
function nextSuffix() {
  const cur = parseInt(stateGet('next_suffix') || '0', 10);
  const next = (cur % SUFFIX_MAX) + 1;
  stateSet('next_suffix', next);
  return next;
}

// baseAmount (ex: 11.74) + suffix unique (ex: 42) -> 11.740042 USDT
function buildUniqueClientAmount(baseAmount) {
  const suffix = nextSuffix();
  // toFixed(6) pour preserver les 6 decimales de USDT
  const unique = parseFloat((baseAmount + suffix * SUFFIX_STEP).toFixed(6));
  return { clientAmount: unique, suffix };
}

function deleteOrder(redeemId) {
  db.prepare('DELETE FROM pending_orders WHERE redeem_id = ?').run(redeemId);
}

function restoreOrder(o) {
  db.prepare(`
    INSERT OR IGNORE INTO pending_orders
      (redeem_id, client_amount, paygate_amount, paygate_address, from_address)
    VALUES (?, ?, ?, ?, ?)
  `).run(o.redeem_id, o.client_amount, o.paygate_amount, o.paygate_address, o.from_address);
}

function alreadyProcessed(txHash, logIndex) {
  const r = db.prepare('SELECT 1 FROM processed_txs WHERE tx_hash = ? AND log_index = ?').get(txHash, logIndex);
  return !!r;
}

function markProcessed(txHash, logIndex, fields) {
  db.prepare(`
    INSERT OR REPLACE INTO processed_txs
      (tx_hash, log_index, redeem_id, from_address, amount, forward_tx, status)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(txHash, logIndex,
         fields.redeem_id || null, fields.from_address || null,
         fields.amount || 0, fields.forward_tx || null, fields.status || 'unknown');
}

// ── Process a single Transfer ────────────────────────────────────────────────
async function processIncoming(fromAddr, received, txHash, logIndex) {
  if (alreadyProcessed(txHash, logIndex)) return;
  if (received < MIN_FORWARD) {
    console.log('[Forwarder] Recu poussiere ' + received + ' USDT - ignore');
    markProcessed(txHash, logIndex, { from_address: fromAddr, amount: received, status: 'dust' });
    return;
  }

  console.log('[Forwarder] Recu ' + received + ' USDT de ' + fromAddr + ' (tx ' + txHash.slice(0, 18) + ')');

  let order = findOrderByFrom(fromAddr);
  let matchedBy = 'from_address';
  if (!order) {
    order = findOrderByAmount(received);
    matchedBy = 'amount';
  }

  if (!order) {
    console.log('[Forwarder] ORPHAN: pas de commande pour ' + received + ' USDT de ' + fromAddr);
    markProcessed(txHash, logIndex, { from_address: fromAddr, amount: received, status: 'orphan' });
    return;
  }

  console.log('[Forwarder] Match ' + matchedBy + ': order=' + order.redeem_id +
              ' (paygate=' + order.paygate_amount + ' -> ' + order.paygate_address + ')');

  // Reserve: delete avant tx pour eviter double-forward si retry
  deleteOrder(order.redeem_id);

  try {
    const hash = await sendUsdt(order.paygate_address, order.paygate_amount);
    const profit = (received - order.paygate_amount).toFixed(2);
    console.log('[Forwarder] OK forward tx=' + hash + ' profit=' + profit);
    markProcessed(txHash, logIndex, {
      redeem_id: order.redeem_id, from_address: fromAddr,
      amount: received, forward_tx: hash, status: 'forwarded',
    });
  } catch (err) {
    console.error('[Forwarder] Echec transfert (commande restoree):', err.message);
    restoreOrder(order);
    markProcessed(txHash, logIndex, {
      redeem_id: order.redeem_id, from_address: fromAddr,
      amount: received, status: 'forward_failed: ' + err.message.slice(0, 80),
    });
  }
}

// ── Polling loop (eth_getLogs) ───────────────────────────────────────────────
async function poll() {
  if (!walletAddress) return;
  try {
    const latest = await getBlockNumber();
    let lastSeen = parseInt(stateGet('last_block') || '0', 10);
    if (!lastSeen || lastSeen > latest) lastSeen = latest - BLOCK_WINDOW;
    const fromBlock = Math.max(lastSeen + 1, latest - BLOCK_WINDOW);
    if (fromBlock > latest) { errCount = 0; return; }

    const logs = await rpcCall('eth_getLogs', [{
      address:   USDT_POLYGON,
      fromBlock: '0x' + fromBlock.toString(16),
      toBlock:   '0x' + latest.toString(16),
      topics:    [TRANSFER_TOPIC, null, ethers.zeroPadValue(walletAddress, 32).toLowerCase()],
    }]);

    errCount = 0;
    if (logs.length > 0) {
      console.log('[Forwarder] ' + logs.length + ' transfer(s) IN entre block ' + fromBlock + ' et ' + latest);
    }

    logs.sort((a, b) => {
      const ba = parseInt(a.blockNumber, 16), bb = parseInt(b.blockNumber, 16);
      if (ba !== bb) return ba - bb;
      return parseInt(a.logIndex, 16) - parseInt(b.logIndex, 16);
    });

    for (const log of logs) {
      const fromAddr = '0x' + log.topics[1].slice(26).toLowerCase();
      const received = parseFloat(ethers.formatUnits(BigInt(log.data), USDT_DECIMALS));
      const txHash   = log.transactionHash;
      const logIndex = parseInt(log.logIndex, 16);
      try {
        await processIncoming(fromAddr, received, txHash, logIndex);
      } catch (e) {
        console.error('[Forwarder] processIncoming error:', e.message);
      }
    }

    stateSet('last_block', latest);
  } catch (err) {
    errCount++;
    console.error('[Forwarder] Erreur poll (' + errCount + '):', err.message.slice(0, 120));
    if (errCount >= 3) { errCount = 0; nextRpc(); }
  }
}

// ── Public API ────────────────────────────────────────────────────────────────
async function init() {
  const key = process.env.VPS_WALLET_KEY;
  if (!key) { console.error('[Forwarder] VPS_WALLET_KEY manquant'); return; }
  walletKey     = key;
  walletAddress = process.env.VPS_WALLET_ADDRESS || ethers.computeAddress(key);

  const nPending = db.prepare('SELECT COUNT(*) AS n FROM pending_orders').get().n;
  if (nPending) console.log('[Forwarder] ' + nPending + ' ordre(s) en attente en DB');

  for (let i = 0; i < RPC_URLS.length; i++) {
    rpcIndex = i;
    try {
      const balance = await getUsdtBalance(walletAddress);
      const blk = await getBlockNumber();
      console.log('[Forwarder] RPC OK:', RPC_URLS[i], '| balance:', balance, 'USDT | block:', blk);
      if (!stateGet('last_block')) stateSet('last_block', blk);
      break;
    } catch (e) {
      console.error('[Forwarder] RPC echec:', RPC_URLS[i], e.message.slice(0, 60));
      if (i === RPC_URLS.length - 1) { console.error('[Forwarder] Aucun RPC disponible'); return; }
    }
  }

  console.log('[Forwarder] Wallet:', walletAddress);
  setInterval(poll, POLL_INTERVAL_MS);
  console.log('[Forwarder] Surveillance active (' + (POLL_INTERVAL_MS/1000) + 's, window=' + BLOCK_WINDOW + ' blocks, tolerance=' + AMOUNT_TOLERANCE + ' USDT)');
}

function addOrder(redeemId, clientAmount, paygateAmount, paygateAddress, fromAddress) {
  const ca = parseFloat(clientAmount);
  const pa = parseFloat(paygateAmount);
  const fa = fromAddress ? String(fromAddress).toLowerCase() : null;

  db.prepare(`
    INSERT OR REPLACE INTO pending_orders
      (redeem_id, client_amount, paygate_amount, paygate_address, from_address)
    VALUES (?, ?, ?, ?, ?)
  `).run(redeemId, ca, pa, paygateAddress, fa);

  console.log('[Forwarder] Ordre: ' + redeemId + ' | client=' + ca + ' paygate=' + pa +
              ' -> ' + paygateAddress + (fa ? ' | from=' + fa : ' | from=NULL'));
}

function getAddress() { return process.env.VPS_WALLET_ADDRESS || walletAddress; }
async function getBalance() {
  if (!walletAddress) return 0;
  try { return await getUsdtBalance(walletAddress); } catch { return 0; }
}

async function manualForward(redeemId) {
  const order = db.prepare('SELECT * FROM pending_orders WHERE redeem_id = ?').get(redeemId);
  if (!order) return { ok: false, error: 'redeem_id introuvable dans pending_orders' };
  deleteOrder(redeemId);
  try {
    const hash = await sendUsdt(order.paygate_address, order.paygate_amount);
    console.log('[Forwarder] Manual forward OK tx=' + hash + ' order=' + redeemId);
    return { ok: true, txHash: hash, paygateAmount: order.paygate_amount, redeemId };
  } catch (err) {
    restoreOrder(order);
    return { ok: false, error: err.message };
  }
}

function getPendingOrders() {
  return db.prepare('SELECT * FROM pending_orders ORDER BY created_at DESC').all();
}

function getOrphanPayments(limit = 50) {
  return db.prepare(`SELECT * FROM processed_txs WHERE status = 'orphan' ORDER BY processed_at DESC LIMIT ?`).all(limit);
}

function getRecentTxs(limit = 50) {
  return db.prepare(`SELECT * FROM processed_txs ORDER BY processed_at DESC LIMIT ?`).all(limit);
}

module.exports = {
  init, addOrder, getAddress, getBalance,
  manualForward, getPendingOrders, getOrphanPayments, getRecentTxs,
  buildUniqueClientAmount,
};
