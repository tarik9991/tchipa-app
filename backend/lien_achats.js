// Prints Tarik's secret link to the sourcing page (/achats/<sig>), see server.js « Sourcing pages ».
// On the VPS: cd /var/www/tchipa-api && node lien_achats.js
require('dotenv').config({ path: '/var/www/tchipa-api/.env' });
const t = process.env.ADMIN_TOKEN || '';
if (t.length < 24) { console.error('ADMIN_TOKEN absent ou trop court dans .env'); process.exit(1); }
const sig = require('crypto').createHmac('sha256', t).update('achat:liste').digest('base64url').slice(0, 22);
console.log(`https://api.tchipa.co.uk/achats/${sig}`);
