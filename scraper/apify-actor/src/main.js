/* Yupoo catalog scraper — port of tchipa-app/scraper/yupoo/yupoo_scraper.py
 *
 * Walks every album of a Yupoo store (https://<store>.x.yupoo.com), extracts
 * album title, price in CNY (parsed from the title) and full-size photo URLs.
 * Does NOT download images: URLs go to the Apify dataset; the local machine
 * fetches the files itself (saves Apify compute / free-plan credits).
 *
 * Output dataset rows:
 *   { albumId, title, priceCny, albumUrl, photos: [...], photoCount }
 * CSV conversion + per-store catalogue.csv assembly happens locally
 * (fetch_images.js), same columns as backend/import_yupoo.js expects.
 */
import { CheerioCrawler, Dataset, log } from 'crawlee';
import { Actor } from 'apify';

const USER_AGENT =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
const MAX_PAGES = 500; // safety stop for the album list
const MAX_PHOTOS = 30; // per album, matches the python scraper

// Price in the title, most explicit first. Same conventions as the python
// scraper: "P158 Nike ...", "💰168", "2600RMB", "110Y-270Y" -> 110.
const PRICE_PATTERNS = [
    /[¥￥]\s*(\d{2,5}(?:\.\d{1,2})?)/,
    /(\d{2,5}(?:\.\d{1,2})?)\s*(?:¥|￥|元|RMB|rmb|CNY|yuan)/,
    /(?<![A-Za-z0-9])[Pp]\s*(\d{2,5})(?!\d)/,
    /💰\s*(\d{2,5})/,
    /(?<![\d.\-/:#xX])(\d{3})(?![\d.\-/:%xX])/, // bare 3-digit number
];

function extractPrice(title) {
    for (const pat of PRICE_PATTERNS) {
        const m = pat.exec(title);
        if (m) return parseFloat(m[1]);
    }
    return null;
}

await Actor.init();

const {
    startUrl,
    maxAlbums = 0,
} = (await Actor.getInput()) ?? {};

if (!startUrl) {
    throw new Error('startUrl is required');
}

const u = new URL(startUrl.startsWith('http') ? startUrl : `https://${startUrl}`);
const root = `${u.protocol}//${u.host}`;
const start = ['', '/'].includes(u.pathname) ? `${root}/albums` : startUrl;
const store = u.host.split('.')[0];

log.info(`Store: ${store} — start: ${start}`);

let albumCount = 0;
const seen = new Set();

const crawler = new CheerioCrawler({
    maxRequestRetries: 4,
    requestHandlerTimeoutSecs: 90,
    // Same idea as the python scraper's 1s delay: stay under Yupoo's radar.
    // Apify rotates IPs so bans are far less likely, but keep it polite.
    maxConcurrency: 2,
    additionalMimeTypes: [],

    async requestHandler({ $, request, log: rlog }) {
        const { userData } = request;

        if (userData.type === 'album') {
            // ---- Album detail page ----
            const title =
                $('.showalbum__headerTitle, .showalbumheader__gallerytitle, h1')
                    .first().text().trim() || userData.listTitle || '';

            const photos = [];
            $('.showalbum__children img, .image__imagewrap img, img.autocover').each((_, el) => {
                if (photos.length >= MAX_PHOTOS) return;
                let src = $(el).attr('data-origin-src') || $(el).attr('data-src') || $(el).attr('src') || '';
                if (!src.includes('photo.yupoo.com')) return;
                src = src.startsWith('//') ? `https:${src}` : new URL(src, request.url).href;
                // medium/small thumbnails -> full size
                src = src.replace(/\/(small|medium|square|thumb)\.(jpe?g|png|webp)$/, '/big.$2');
                if (!photos.includes(src)) photos.push(src);
            });

            if (!photos.length) {
                rlog.warning(`[${userData.albumId}] no photos, skipped`);
            } else {
                await Dataset.pushData({
                    store,
                    albumId: userData.albumId,
                    title,
                    priceCny: extractPrice(title),
                    albumUrl: request.url.split('?')[0],
                    photos,
                    photoCount: photos.length,
                });
            }
            return;
        }

        // ---- Album listing page ----
        const links = $('a.album__main, a.album3__main').length
            ? $('a.album__main, a.album3__main')
            : $('a[href*="/albums/"]');

        let newOnPage = 0;
        for (const el of links) {
            const href = $(el).attr('href') || '';
            const m = href.match(/\/albums\/(\d+)/);
            if (!m || seen.has(m[1])) continue;
            seen.add(m[1]);
            newOnPage++;
            if (maxAlbums && albumCount >= maxAlbums) return;

            albumCount++;
            let listTitle = $(el).attr('title') || '';
            if (!listTitle) {
                listTitle = $(el).find('.album__title, .album3__title, .text_overflow').text().trim();
            }
            const albumUrl = new URL(href, root).href;
            await crawler.addRequests([{
                url: albumUrl,
                userData: { type: 'album', albumId: m[1], listTitle },
            }]);
        }

        rlog.info(`[liste] page ${request.userData.page}: ${newOnPage} albums (total ${albumCount})`);

        // Yupoo repeats the last page or shows none past the end.
        if (!newOnPage) return;

        const pageNum = request.userData.page;
        if (pageNum < MAX_PAGES) {
            const sep = start.includes('?') ? '&' : '?';
            await crawler.addRequests([{
                url: `${start}${sep}page=${pageNum + 1}`,
                userData: { page: pageNum + 1 },
            }]);
        }
    },

    failedRequestHandler({ request }, error) {
        log.error(`Request ${request.url} failed: ${error.message}`);
    },
});

const sep = start.includes('?') ? '&' : '?';
await crawler.run([{ url: `${start}${sep}page=1`, userData: { page: 1 } }]);

const total = await Dataset.getData().then(d => d.total);
log.info(`Done: ${albumCount} albums listed, ${total} records in dataset`);

await Actor.exit();
