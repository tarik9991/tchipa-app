#!/usr/bin/env node
/* fetch_images.js — local companion of the yupoo-catalog Apify actor.
 *
 * 1. Reads the actor's dataset (via Apify API) — rows:
 *    { store, albumId, title, priceCny, albumUrl, photos, photoCount }
 * 2. Downloads photos into yupoo_data/<store>/<albumId>_<slug>/ and converts
 *    them to WebP (max 1200px, quality 80 — ~4-10x smaller than Yupoo originals;
 *    IMG_MAX_WIDTH / IMG_WEBP_QUALITY to override). Falls back to the original
 *    file if sharp is unavailable or the resize fails. GIFs are kept as-is.
 * 3. Writes catalogue.csv in the exact format backend/import_yupoo.js reads:
 *    album_id, title, price_cny, category, album_url, cover, images, photo_count
 *
 * Usage:
 *   APIFY_TOKEN=... node fetch_images.js <runId> [--store name] [--only-missing]
 *
 * Incremental: re-running skips albums whose photos are all on disk.
 */
import { ApifyClient } from 'apify-client';
import fs from 'node:fs';
import path from 'node:path';

// resize is optional: if sharp is not installed we still download originals
let sharp = null;
try { sharp = (await import('sharp')).default; } catch {}

const IMG_MAX_WIDTH = parseInt(process.env.IMG_MAX_WIDTH || '1200', 10);
const IMG_WEBP_QUALITY = parseInt(process.env.IMG_WEBP_QUALITY || '80', 10);
// photo.yupoo.com tolerates parallel fetches (only listing pages ban) —
// CONCURRENCY=24 cuts a ~150k-photo run from ~60h sequential to ~2-4h
const CONCURRENCY = parseInt(process.env.CONCURRENCY || '24', 10);

// load .env (token written by the user, never logged)
const envPath = path.join(import.meta.dirname, '.env');
if (fs.existsSync(envPath)) {
    for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
        const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.+)\s*$/);
        if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
    }
}

const OUT_ROOT = process.env.YUPOO_OUT || path.join(import.meta.dirname, '..', 'yupoo');
const DATA_ROOT = path.join(OUT_ROOT, 'yupoo_data');

const CSV_COLUMNS = ['album_id', 'title', 'price_cny', 'category', 'album_url', 'cover', 'images', 'photo_count'];

const token = process.env.APIFY_TOKEN;
if (!token) { console.error('APIFY_TOKEN manquant'); process.exit(1); }

const runId = process.argv[2];
if (!runId) { console.error('Usage: node fetch_images.js <runId> [--only-missing]'); process.exit(1); }
const onlyMissing = process.argv.includes('--only-missing');
const useLocal = process.argv.includes('--local');

let items;
if (useLocal) {
    // read the local actor test dataset (storage/datasets/default)
    const dir = path.join(import.meta.dirname, 'storage', 'datasets', 'default');
    const files = fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort();
    items = files.map(f => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')));
    console.log(`Dataset local: ${items.length} enregistrements`);
    if (!items.length) process.exit(0);
} else {
    await mainCloud();
}
if (useLocal) await processAll(items);

async function mainCloud() {
    const client = new ApifyClient({ token });

// ---- 1. read dataset ----
const run = await client.run(runId).get().catch(() => null);
const datasetId = run ? run.defaultDatasetId : runId;
if (!datasetId) { console.error('Run introuvable'); process.exit(1); }

const items2 = [];
let offset = 0;
for (;;) {
    const page = await client.dataset(datasetId).listItems({ offset, limit: 1000 });
    items2.push(...page.items);
    if (page.items.length < 1000) break;
    offset += 1000;
}
console.log(`Dataset ${datasetId}: ${items2.length} enregistrements`);
if (!items2.length) process.exit(0);
await processAll(items2);
}

async function processAll(items) {
// group by store
const byStore = {};
for (const it of items) (byStore[it.store] ||= []).push(it);

function safeName(s, n = 40) {
    return s.replace(/[\\/:*?"<>|\x00-\x1f]/g, '_').replace(/\s+/g, ' ').trim().slice(0, n) || 'album';
}

// ---- 2+3. per store: download photos, write catalogue.csv ----
for (const [store, rows] of Object.entries(byStore)) {
    const out = path.join(DATA_ROOT, store);
    fs.mkdirSync(out, { recursive: true });
    const csvPath = path.join(out, 'catalogue.csv');

    // existing rows for incremental mode
    const existing = new Map();
    if (fs.existsSync(csvPath)) {
        const lines = fs.readFileSync(csvPath, 'utf8').split('\n').filter(Boolean);
        const headers = lines[0].split(',');
        for (const line of lines.slice(1)) {
            // naive CSV split OK: fields never contain commas (we control titles? no...)
            // safer: use a real parse for titles with commas
            const cells = [];
            let cur = '', inQ = false;
            for (let i = 0; i < line.length; i++) {
                const c = line[i];
                if (inQ) {
                    if (c === '"') {
                        if (line[i + 1] === '"') { cur += '"'; i++; } else inQ = false;
                    } else cur += c;
                } else if (c === '"') inQ = true;
                else if (c === ',') { cells.push(cur); cur = ''; }
                else cur += c;
            }
            cells.push(cur);
            const row = Object.fromEntries(headers.map((h, i) => [h, cells[i] ?? '']));
            existing.set(row.album_id, row);
        }
    }

    let savedCount = 0, skipped = 0, failed = 0;
    const rowsToWrite = new Map();

    // build the work list first, then process albums CONCURRENCY at a time —
    // this is where the speedup comes from (albums are independent)
    const todo = [];
    for (const it of rows) {
        const title = it.title || '';
        const folder = `${it.albumId}_${safeName(title)}`;
        if (existing.has(String(it.albumId)) && !onlyMissing) { skipped++; continue; }
        if (onlyMissing && existing.has(String(it.albumId)) && (() => {
            try { return allOnDisk(it, folder, out); } catch { return false; }
        })()) { skipped++; continue; }
        todo.push({ it, folder, title });
    }

    let cursor = 0;
    async function worker() {
        for (;;) {
            const i = cursor++;
            if (i >= todo.length) return;
            const { it, folder, title } = todo[i];
            const images = await fetchAlbum(it, folder, out);
            if (!images.length) { failed++; continue; }
            const row = {
                album_id: it.albumId, title,
                price_cny: it.priceCny == null ? '' : String(it.priceCny),
                category: '', album_url: it.albumUrl,
                cover: images[0], images: images.join('|'), photo_count: images.length,
            };
            rowsToWrite.set(String(it.albumId), row);
            savedCount++;
        }
    }
    await Promise.all(Array.from({ length: CONCURRENCY }, worker));

    // merge with existing and write
    for (const [id, row] of existing) if (!rowsToWrite.has(id)) rowsToWrite.set(id, row);
    writeCsv(csvPath, rowsToWrite);
    console.log(`${store}: ${savedCount} nouveaux/MAJ, ${skipped} ignorés, ${failed} échecs → ${csvPath}`);
}
} // fin processAll

function allOnDisk(it, folder, out) {
    return it.photos.length > 0 && it.photos.every((_, i) => {
        const idx = String(i + 1).padStart(2, '0');
        return !!findOnDisk(out, folder, idx, (it.photos[i].match(/\.(jpe?g|png|webp)(\?|$)/) || [, 'jpg'])[1].replace('jpeg', 'jpg'));
    });
}

// downloads an album's missing photos in parallel, returns the image paths for the CSV
async function fetchAlbum(it, folder, out) {
    const images = [];

    // webp conversion changes what lands on disk: a downloaded 01.jpg may be
    // stored as 01.webp, so existence checks must accept both spellings
    let madeDir = false;
    const jobs = [];
    for (let i = 0; i < it.photos.length; i++) {
        const src = it.photos[i];
        const ext = (src.match(/\.(jpe?g|png|webp)(\?|$)/) || [, 'jpg'])[1].replace('jpeg', 'jpg');
        const fname = `${String(i + 1).padStart(2, '0')}.${ext}`;
        const onDisk = findOnDisk(out, folder, String(i + 1).padStart(2, '0'), ext);
        const dest = path.join(out, folder, onDisk || fname);
        if (!onDisk) {
            if (!madeDir) { fs.mkdirSync(path.join(out, folder), { recursive: true }); madeDir = true; }
            jobs.push({ src, dest, idx: i });
        } else {
            images[i] = `${folder}/${onDisk}`;
        }
    }

    const results = await Promise.all(jobs.map(j => download(j.src, j.dest)));
    for (let n = 0; n < jobs.length; n++) {
        const finalName = results[n];
        if (!finalName) continue; // holes are filtered out below
        images[jobs[n].idx] = `${folder}/${finalName}`;
    }
    return images.filter(Boolean);
}

function findOnDisk(out, folder, idx, ext) {
    const base = `${idx}.`;
    try {
        const hit = fs.readdirSync(path.join(out, folder))
            .find(f => f.startsWith(`${base}${ext}`) || f.startsWith(`${base}webp`));
        return hit || null;
    } catch { return null; }
}

function writeCsv(csvPath, rowsMap) {
    const esc = v => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const lines = [CSV_COLUMNS.join(',')];
    for (const r of rowsMap.values()) lines.push(CSV_COLUMNS.map(c => esc(r[c])).join(','));
    fs.writeFileSync(csvPath, lines.join('\n') + '\n');
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// returns the final file name (basename of finalDest), or null on failure
async function download(url, dest) {
    try {
        const res = await fetch(url, {
            headers: { 'User-Agent': 'Mozilla/5.0', Referer: 'https://www.yupoo.com/' },
            signal: AbortSignal.timeout(30000),
        });
        if (!res.ok) return null;
        const buf = Buffer.from(await res.arrayBuffer());
        if (!buf.length) return null;

        // resize to WebP (smaller, app-friendly). On any sharp failure keep
        // the original bytes so the album is not left with a missing image.
        let finalDest = dest;
        let outBuf = buf;
        const ext = path.extname(dest).toLowerCase();
        if (sharp && ext !== '.gif') {
            try {
                const resized = await sharp(buf, { failOn: 'none' })
                    .rotate() // honor EXIF orientation
                    .resize({ width: IMG_MAX_WIDTH, withoutEnlargement: true })
                    .webp({ quality: IMG_WEBP_QUALITY })
                    .toBuffer();
                if (resized.length && resized.length < buf.length) {
                    outBuf = resized;
                    finalDest = dest.replace(/\.(jpe?g|png|webp)$/i, '.webp');
                }
            } catch { /* keep original */ }
        }
        fs.writeFileSync(finalDest + '.part', outBuf);
        fs.renameSync(finalDest + '.part', finalDest);
        return path.basename(finalDest);
    } catch {
        try { fs.unlinkSync(dest + '.part'); } catch {}
        return null;
    }
}
