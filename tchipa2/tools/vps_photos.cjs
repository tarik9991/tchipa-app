#!/usr/bin/env node
// Builds the Tchipa 2 photo tree served by nginx at api.tchipa.co.uk/t2/ (VPS only).
//
// Input : /root/tchipa-app/scraper/yupoo/yupoo_data/<store>/<albumId>_<slug>/NN.webp
//         (fetch_images.js + fill_gaps.js output; slugs hold CJK and quotes, unusable in URLs)
// Output: /var/www/tchipa2-photos/<store>/<albumId>/{1..n}.webp  hard links, no extra disk
//         /var/www/tchipa2-photos/<store>/<albumId>/s.webp       400 px cover for the grid
//         /var/www/tchipa2-photos/manifest.json                  { store: { albumId: n } }
// The source tree is never modified. Idempotent: rerun after a new scrape.
//
// Run (.cjs: the apify-actor package is an ES module; sharp comes from its node_modules):
//   cp vps_photos.cjs /root/tchipa-app/scraper/apify-actor/ && node /root/tchipa-app/scraper/apify-actor/vps_photos.cjs
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const SRC = '/root/tchipa-app/scraper/yupoo/yupoo_data';
const DST = '/var/www/tchipa2-photos';
const THUMB_WIDTH = 400;

async function main() {
  const manifest = {};
  let thumbs = 0, links = 0;
  for (const store of fs.readdirSync(SRC).sort()) {
    const sdir = path.join(SRC, store);
    if (!fs.statSync(sdir).isDirectory()) continue;
    // Several folders can share an album id (renamed album): keep the fullest one.
    const best = {};
    for (const d of fs.readdirSync(sdir)) {
      const m = /^(\d+)_/.exec(d);
      if (!m || !fs.statSync(path.join(sdir, d)).isDirectory()) continue;
      const files = fs.readdirSync(path.join(sdir, d)).filter(f => /^\d+\.webp$/.test(f))
        .sort((a, b) => parseInt(a, 10) - parseInt(b, 10));
      if (files.length && (!best[m[1]] || files.length > best[m[1]].files.length)) best[m[1]] = { d, files };
    }
    manifest[store] = {};
    for (const [id, { d, files }] of Object.entries(best)) {
      const out = path.join(DST, store, id);
      fs.mkdirSync(out, { recursive: true });
      // Renumber 1..n so gaps left by failed downloads don't break the gallery.
      files.forEach((f, i) => {
        const dst = path.join(out, `${i + 1}.webp`);
        if (!fs.existsSync(dst)) { fs.linkSync(path.join(sdir, d, f), dst); links++; }
      });
      const thumb = path.join(out, 's.webp');
      if (!fs.existsSync(thumb)) {
        try {
          await sharp(path.join(out, '1.webp')).resize({ width: THUMB_WIDTH, withoutEnlargement: true })
            .webp({ quality: 70 }).toFile(thumb);
          thumbs++;
        } catch (e) {
          console.error(`miniature ratée ${store}/${id}: ${e.message}`);
          fs.rmSync(out, { recursive: true, force: true });
          continue;
        }
      }
      manifest[store][id] = files.length;
    }
    console.log(`${store}: ${Object.keys(manifest[store]).length} albums`);
  }
  fs.writeFileSync(path.join(DST, 'manifest.json'), JSON.stringify(manifest));
  console.log(`liens créés: ${links}, miniatures créées: ${thumbs}`);
}

main().catch(e => { console.error(e); process.exit(1); });
