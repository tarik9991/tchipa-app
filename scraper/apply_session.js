#!/usr/bin/env node
/**
 * apply_session.js
 *
 * Loads AliExpress session cookies into Puppeteer's USER_DATA_DIR so that
 * subsequent scraper runs browse as a logged-in user.
 *
 * Usage:
 *   node apply_session.js [cookies.json]
 *
 * If no argument is supplied the script reads JSON from stdin.
 *
 * The cookies file must be a JSON array of cookie objects in the standard
 * browser export format (name, value, domain, path, …).  Both the Chrome
 * DevTools "Copy all as JSON" format and the Netscape / EditThisCookie export
 * format are accepted.
 *
 * Environment variables (all optional):
 *   USER_DATA_DIR   – Puppeteer profile directory (default: ./user_data)
 *   HEADLESS        – "false" to watch the browser open (default: true)
 */

'use strict';

const puppeteer = require('puppeteer');
const fs        = require('fs');
const path      = require('path');
const readline  = require('readline');

// ─── Configuration ───────────────────────────────────────────────────────────

const USER_DATA_DIR = process.env.USER_DATA_DIR
  ? path.resolve(process.env.USER_DATA_DIR)
  : path.resolve(__dirname, 'user_data');

const HEADLESS = process.env.HEADLESS !== 'false';

const ALIEXPRESS_ORIGIN = 'https://www.aliexpress.com';

// ─── Helpers ─────────────────────────────────────────────────────────────────

/** Read all of stdin as a string. */
function readStdin() {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin });
    const lines = [];
    rl.on('line', (l) => lines.push(l));
    rl.on('close', () => resolve(lines.join('\n')));
  });
}

/**
 * Normalise a cookie object from any common export format into the shape that
 * Puppeteer's page.setCookie() expects.
 */
function normaliseCookie(raw) {
  // Handle EditThisCookie / JSON export field aliases
  const name  = raw.name  ?? raw.Name  ?? '';
  const value = raw.value ?? raw.Value ?? '';
  let domain  = raw.domain ?? raw.Domain ?? raw.host ?? '';

  // Ensure the domain starts with a dot for cross-subdomain scope, matching
  // how browsers store AliExpress cookies (e.g. ".aliexpress.com").
  if (domain && !domain.startsWith('.') && !domain.startsWith('http')) {
    domain = '.' + domain;
  }

  const cookie = {
    name,
    value,
    domain,
    path:     raw.path     ?? raw.Path     ?? '/',
    httpOnly: raw.httpOnly ?? raw.HttpOnly ?? false,
    secure:   raw.secure   ?? raw.Secure   ?? false,
    sameSite: raw.sameSite ?? raw.SameSite ?? 'None',
  };

  // Optional: expiry / expires
  const expiry = raw.expirationDate ?? raw.expiry ?? raw.expires ?? raw.Expires;
  if (expiry !== undefined && expiry !== null && expiry !== -1) {
    // Some exports give a human-readable date string
    cookie.expires = typeof expiry === 'number'
      ? Math.floor(expiry)
      : Math.floor(new Date(expiry).getTime() / 1000);
  }

  return cookie;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  // 1. Load raw cookies JSON
  let rawJson;
  const cookieArg = process.argv[2];

  if (cookieArg) {
    const filePath = path.resolve(cookieArg);
    console.log(`Reading cookies from file: ${filePath}`);
    rawJson = fs.readFileSync(filePath, 'utf8');
  } else if (!process.stdin.isTTY) {
    console.log('Reading cookies from stdin…');
    rawJson = await readStdin();
  } else {
    console.error(
      'Error: No cookies provided.\n' +
      'Usage: node apply_session.js [cookies.json]\n' +
      '   or: cat cookies.json | node apply_session.js'
    );
    process.exit(1);
  }

  let rawCookies;
  try {
    rawCookies = JSON.parse(rawJson);
  } catch (err) {
    console.error('Error: Could not parse cookies JSON —', err.message);
    process.exit(1);
  }

  if (!Array.isArray(rawCookies)) {
    console.error('Error: cookies JSON must be an array of cookie objects.');
    process.exit(1);
  }

  const cookies = rawCookies.map(normaliseCookie).filter((c) => c.name);
  console.log(`Parsed ${cookies.length} cookie(s).`);

  // 2. Ensure USER_DATA_DIR exists
  fs.mkdirSync(USER_DATA_DIR, { recursive: true });
  console.log(`Using USER_DATA_DIR: ${USER_DATA_DIR}`);

  // 3. Launch Puppeteer with the persistent profile
  // Use the system Chromium when the bundled one isn't compatible (e.g. ARM/ChromeOS)
  const executablePath = process.env.CHROMIUM_PATH
    || (() => {
        const candidates = [
          '/usr/bin/chromium',
          '/usr/bin/chromium-browser',
          '/usr/bin/google-chrome',
        ];
        const fs2 = require('fs');
        return candidates.find((p) => { try { fs2.accessSync(p, fs2.constants.X_OK); return true; } catch { return false; } });
      })();

  const browser = await puppeteer.launch({
    headless: HEADLESS,
    userDataDir: USER_DATA_DIR,
    executablePath,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--disable-software-rasterizer',
      '--disable-blink-features=AutomationControlled',
      '--no-zygote',
      '--single-process',
    ],
    defaultViewport: { width: 1280, height: 800 },
    timeout: 60000,
  });

  const page = await browser.newPage();

  // Minimal stealth: hide navigator.webdriver
  await page.evaluateOnNewDocument(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  });

  try {
    // 4. Open AliExpress so the browser has the right origin context,
    //    then inject the cookies
    console.log(`Navigating to ${ALIEXPRESS_ORIGIN} …`);
    await page.goto(ALIEXPRESS_ORIGIN, {
      waitUntil: 'domcontentloaded',
      timeout: 30_000,
    });

    console.log('Injecting cookies…');
    for (const cookie of cookies) {
      try {
        await page.setCookie(cookie);
      } catch (err) {
        console.warn(`  Skipped cookie "${cookie.name}": ${err.message}`);
      }
    }

    // 5. Reload to let AliExpress pick up the new session
    console.log('Reloading to activate session…');
    await page.reload({ waitUntil: 'networkidle2', timeout: 45_000 });

    // 6. Verify login by checking for a known logged-in element
    const loggedIn = await page.evaluate(() => {
      // AliExpress shows the account name / avatar when logged in
      return (
        document.querySelector('.comet-icon-account') !== null ||
        document.querySelector('[data-role="user-info"]') !== null ||
        document.cookie.includes('aep_usuc_f') ||
        document.cookie.includes('_tb_token_')
      );
    });

    if (loggedIn) {
      console.log('Session verified — you are logged in to AliExpress.');
    } else {
      console.warn(
        'Warning: Could not confirm login. ' +
        'The cookies may have expired or the page structure changed. ' +
        'Check the browser manually with HEADLESS=false.'
      );
    }

    console.log(`\nDone. Profile saved to: ${USER_DATA_DIR}`);
    console.log(
      'Future Puppeteer scripts that use this USER_DATA_DIR will start ' +
      'as a logged-in AliExpress user.'
    );
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
