/* ============ RÉGLAGES ============ */
const CNY_PER_USD = 7;   // Taux de change : 1 USD = ~7 CNY
const FIXED_FEE   = 17;  // $ ajoutés
const MULTIPLIER  = 2;   // (prix_usd + 17) * 2

const CSV_URL = 'catalogue.csv';

function getImageUrl(row) {
    if (!row.cover) return 'https://via.placeholder.com/300?text=Pas+d+image';
    if (row.cover.startsWith('http')) return row.cover;
    
    let storeName = 'oraclothing';
    if (row.album_url) {
        try {
            const match = row.album_url.match(/https?:\/\/([^.]+)\.x\.yupoo\.com/);
            if (match && match[1]) storeName = match[1];
        } catch (e) {}
    }
    
    // Encodage propre du chemin pour gérer les espaces et caractères spéciaux
    const cleanCover = row.cover.split('/').map(part => encodeURIComponent(part)).join('/');
    return `../scraper/yupoo/yupoo_data/${storeName}/${cleanCover}`;
}

function calculatePriceUSD(cnyPrice) {
    const priceNum = parseFloat(cnyPrice);
    if (isNaN(priceNum) || priceNum <= 0) return null;
    return ((priceNum / CNY_PER_USD) + FIXED_FEE) * MULTIPLIER;
}

function parseCSVLine(text) {
    const lines = text.trim().split('\n');
    if (lines.length < 2) return [];
    
    const headers = lines[0].split(',').map(h => h.trim().replace(/^"|"$/g, ''));
    const products = [];

    for (let i = 1; i < lines.length; i++) {
        if (!lines[i].trim()) continue;
        
        // Regex robuste pour gérer les virgules dans les guillemets du CSV
        const values = lines[i].match(/(".*?"|[^",\s]+)(?=\s*,|\s*$)/g) || lines[i].split(',');
        const row = {};
        
        headers.forEach((h, index) => {
            let val = values[index] ? values[index].trim() : '';
            if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
            row[h] = val;
        });
        products.push(row);
    }
    return products;
}

let allProducts = [];

async function loadProducts() {
    try {
        const response = await fetch(CSV_URL);
        const text = await response.text();
        allProducts = parseCSVLine(text);
        renderProducts(allProducts);
    } catch (err) {
        console.error("Erreur de chargement du CSV :", err);
    }
}

function renderProducts(products) {
    const container = document.getElementById('products-grid') || document.body;
    const countEl = document.getElementById('product-count');
    if (countEl) countEl.innerText = `${products.length} produits`;

    let html = '<div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 16px; padding: 20px;">';
    
    products.forEach(p => {
        const usdPrice = calculatePriceUSD(p.price_cny || p.price);
        const priceDisplay = usdPrice ? `$${usdPrice.toFixed(2)}` : 'Prix sur demande';
        const imgUrl = getImageUrl(p);
        const title = p.title || 'Sans titre';
        const link = p.album_url || p.url || '#';

        html += `
            <div style="border: 1px solid #e2e8f0; border-radius: 8px; overflow: hidden; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
                <img src="${imgUrl}" alt="${title}" style="width: 100%; height: 200px; object-fit: cover;" onerror="this.onerror=null;this.src='https://via.placeholder.com/300?text=Image+Non+Trouvee';">
                <div style="padding: 12px;">
                    <h3 style="font-size: 14px; margin: 0 0 8px 0; height: 36px; overflow: hidden; font-weight: 600;">${title}</h3>
                    <div style="font-size: 18px; font-weight: bold; color: #16a34a; margin-bottom: 8px;">${priceDisplay}</div>
                    <a href="${link}" target="_blank" style="display: block; text-align: center; background: #2563eb; color: white; padding: 6px 12px; border-radius: 4px; text-decoration: none; font-size: 12px;">Voir sur Yupoo</a>
                </div>
            </div>
        `;
    });
    
    html += '</div>';
    
    const target = document.getElementById('products-container') || container;
    target.innerHTML = html;
}

document.addEventListener('DOMContentLoaded', loadProducts);
