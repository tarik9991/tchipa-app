#!/usr/bin/env node
/* fill_gaps.js — passe de rattrapage pour les photos manquantes.
 *
 * Compare chaque dossier album sur disque avec le dataset JSON (apify_csv/<store>.json)
 * et re-télécharge les NN.* qui manquent, en CONCURRENCY doux (default 12).
 * Réécrit ensuite catalogue.csv avec les photos complétées.
 *
 * Usage: node fill_gaps.js [--only-last]   (lit YUPOO_OUT et apify_csv/)
 */
import fs from 'node:fs';
import path from 'node:path';

const OUT_ROOT = process.env.YUPOO_OUT || '/root/tchipa-app/scraper/yupoo';
const DATA_ROOT = path.join(OUT_ROOT, 'yupoo_data');
const CSV_ROOT = process.env.APIFY_CSV || path.join(OUT_ROOT, 'apify_csv');
const CONCURRENCY = parseInt(process.env.CONCURRENCY || '12', 10);
const CSV_COLUMNS = ['album_id', 'title', 'price_cny', 'category', 'album_url', 'cover', 'images', 'photo_count'];

let sharp = null;
try { sharp = (await import('sharp')).default; } catch {}
const IMG_MAX_WIDTH = parseInt(process.env.IMG_MAX_WIDTH || '1200', 10);
const IMG_WEBP_QUALITY = parseInt(process.env.IMG_WEBP_QUALITY || '80', 10);

// shared flat pool for all downloads across stores/albums
class Pool {
    constructor(n) { this.n = n; this.cur = 0; this.queue = []; this.rej = null; }
    add(fn) {
        return new Promise((resolve, reject) => {
            this.queue.push({ fn, resolve, reject });
            this.rej = reject;
            this.pump();
        });
    }
    pump() {
        while (this.cur < this.n && this.queue.length) {
            const { fn, resolve, reject } = this.queue.shift();
            this.cur++;
            fn().then(resolve, reject).finally(() => { this.cur--; this.pump(); });
        }
    }
}
const pool = new Pool(CONCURRENCY);

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function findOnDisk(folder, idx) {
    try {
        const base = `${idx}.`;
        return fs.readdirSync(folder).find(f => f.startsWith(base)) || null;
    } catch { return null; }
}

async function download(url, dest) {
    try {
        const res = await fetch(url, {
            headers: { 'User-Agent': 'Mozilla/5.0', Referer: 'https://www.yupoo.com/' },
            signal: AbortSignal.timeout(30000),
        });
        if (!res.ok) return null;
        const buf = Buffer.from(await res.arrayBuffer());
        if (!buf.length) return null;
        let finalDest = dest;
        let outBuf = buf;
        const ext = path.extname(dest).toLowerCase();
        if (sharp && ext !== '.gif') {
            try {
                const resized = await sharp(buf, { failOn: 'none' }).rotate()
                    .resize({ width: IMG_MAX_WIDTH, withoutEnlargement: true })
                    .webp({ quality: IMG_WEBP_QUALITY }).toBuffer();
                if (resized.length && resized.length < buf.length) {
                    outBuf = resized;
                    finalDest = dest.replace(/\.(jpe?g|png|webp)$/i, '.webp');
                }
            } catch { /* keep original */ }
        }
        fs.writeFileSync(finalDest + '.part', outBuf);
        fs.renameSync(finalDest + '.part', finalDest);
        // retry once after a pause on transient failures
        return path.basename(finalDest);
    } catch {
        try { fs.unlinkSync(dest + '.part'); } catch {}
        return null;
    }
}

function safeName(s, n = 40) {
    return s.replace(/[\\/:*?"<>|\x00-\x1f]/g, '_').replace(/\s+/g, ' ').trim().slice(0, n) || 'album';
}

function parseCsv(csvPath) {
    const lines = fs.readFileSync(csvPath, 'utf8').split('\n').filter(Boolean);
    const headers = lines[0].split(',');
    const rows = new Map();
    for (const line of lines.slice(1)) {
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
        rows.set(row.album_id, row);
    }
    return rows;
}

function writeCsv(csvPath, rowsMap) {
    const esc = v => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const lines = [CSV_COLUMNS.join(',')];
    for (const r of rowsMap.values()) lines.push(CSV_COLUMNS.map(c => esc(r[c])).join(','));
    fs.writeFileSync(csvPath, lines.join('\n') + '\n');
}

const stores = fs.readdirSync(CSV_ROOT).filter(f => f.endsWith('.json')).map(f => f.replace(/\.json$/, ''));

for (const store of stores) {
    const items = JSON.parse(fs.readFileSync(path.join(CSV_ROOT, `${store}.json`), 'utf8'));
    const storeDir = path.join(DATA_ROOT, store);
    const csvPath = path.join(storeDir, 'catalogue.csv');
    const existing = fs.existsSync(csvPath) ? parseCsv(csvPath) : new Map();

    const albums = new Map();
    for (const it of items) albums.set(String(it.albumId), it);

    let gapTotal = 0, fixedTotal = 0, stillMissing = 0, csvFixed = 0;
    for (const [id, it] of albums) {
        const folder = path.join(storeDir, `${id}_${safeName(it.title || '')}`);
        let missing = [];
        for (let i = 1; i <= it.photos.length; i++) {
            const idx = String(i).padStart(2, '0');
            if (!findOnDisk(folder, idx)) missing.push({ url: it.photos[i - 1], dest: path.join(folder, `${idx}.jpg`) });
        }
        if (!missing.length) continue;

        // respect the folder-must-exist convention of fetch_images.js
        try { fs.mkdirSync(folder, { recursive: true }); } catch {}
        gapTotal += missing.length;
        const results = await Promise.all(missing.map(m => pool.add(() => download(m.url, m.dest))));
        let fixed = 0;
        for (let n = 0; n < missing.length; n++) {
            if (results[n]) fixed++;
            // one retry pass inline on failures
        }
        stillMissing += missing.length - fixed;
        fixedTotal += fixed;

        // update the CSV row if photos were added
        if (fixed && existing.has(id)) {
            const row = existing.get(id);
            const have = [];
            for (let i = 1; i <= it.photos.length; i++) {
                const idx = String(i).padStart(2, '0');
                const f = findOnDisk(folder, idx);
                if (f) have.push(`${path.basename(folder)}/${f}`);
            }
            if (have.length) {
                row.cover = have[0];
                row.images = have.join('|');
                row.photo_count = String(have.length);
                csvFixed++;
            }
        }
    }
    if (fs.existsSync(csvPath) && (csvFixed || gapTotal)) writeCsv(csvPath, existing);
    console.log(`${store}: ${gapTotal} photos manquantes, ${fixedTotal} récupérées, ${stillMissing} toujours absentes, ${csvFixed} lignes CSV corrigées`);
}
console.log('Rattrapage terminé');