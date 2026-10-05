// ============================================================
// tchipa-ai — assistant du site tchipa.co.uk
// Service ISOLÉ (port 3003). Ne touche PAS au backend de paiement tchipa-api.
// Exposé via nginx en https://api.tchipa.co.uk/assistant/*
//
// Cerveau : modèles GRATUITS d'OpenRouter (chaîne de repli) puis Ollama local
//           en dernier recours → coût 0 $/question.
// Persona : Mena, réceptionniste IA de Tchipa DZ (boutique de vêtements).
// Contexte : contexte.txt (base de connaissances de la boutique).
// Répond dans la langue de la question (FR / AR / EN).
// ============================================================
require('dotenv').config({ path: require('path').join(__dirname, '.env') });
const express = require('express');
const cors = require('cors');
const fs = require('fs');
const path = require('path');

const PORT = process.env.TCHIPA_AI_PORT || 3003;
const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY || '';
const OLLAMA_URL = process.env.OLLAMA_URL || 'http://127.0.0.1:32769';
const OLLAMA_MODEL = process.env.OLLAMA_MODEL || 'qwen2:1.5b';

// Chaîne de modèles gratuits (essayés dans l'ordre ; on tombe sur le suivant si échec).
// Modèles NON « thinking » privilégiés pour éviter les fuites de raisonnement.
const FREE_MODELS = [
  'nvidia/nemotron-3-super-120b-a12b:free',
  'google/gemma-4-31b-it:free',
  'meta-llama/llama-3.3-70b-instruct:free',
  'openai/gpt-oss-120b:free',
];

const CONTEXT = fs.readFileSync(path.join(__dirname, 'contexte.txt'), 'utf8');

const SYSTEM_PROMPT =
`You are MENA, the AI receptionist of Tchipa DZ ("Ana Mena"). You welcome visitors on the
website tchipa.co.uk and in the Tchipa app. Tchipa is an online clothing shop: clothes from
Chinese manufacturers, delivered to the customer's home in Algeria, delivery and customs
included, paid in dinars via BaridiMob.
Personality: warm, elegant, welcoming, like the receptionist of a beautiful store. You speak
naturally, as a woman (in French and Arabic use feminine forms for yourself). You can greet
with "Marhba bik !" when it fits.
Your job: answer visitors' questions and help them order, based ONLY on the KNOWLEDGE BASE
below.

RULES:
- ALWAYS reply in the language of the question: French if asked in French, Arabic (العربية)
  if asked in Arabic, English if asked in English, Algerian darija if asked in darija.
  Never mix languages in one answer.
- ALGERIAN darija only (never Moroccan): write it in Latin letters (arabizi) if the user does,
  with Algerian words: "wach", "kayen / makanch", "ta3", "bezzaf", "chwiya", "rani", "dork",
  "ma3lich". NEVER use Moroccan words like "dyal", "wakha", "bzaf", "daba", "mashi
  mochkil", and never mix in Spanish or English.
- Base every answer only on the KNOWLEDGE BASE. If the information is not there, say so
  honestly and point the user to Telegram support — never invent prices, rates, features
  or card numbers.
- Be friendly, clear and encouraging. Help the visitor take the next step (install the app,
  top up the balance with an agent, choose items, pick the right size). Keep answers short
  (a few sentences to a short paragraph). Simple bullet steps are welcome for "how to".
- You CANNOT see anyone's personal order, balance or payment. For anything about a specific
  order, a payment, a top-up, finding an agent or becoming an agent, tell the user to contact
  Tchipa support on Telegram.
- Never state an exchange rate or a precise price: prices are shown in the app and the rate
  is given by the agent at top-up time. Never promise a delivery date: 2 to 4 weeks is only
  indicative.
- Hijab and abaya sections are NOT available yet ("coming very soon").
- Only talk about Tchipa. Politely decline unrelated topics.
- Give DIRECTLY the final answer for the user. Never show your reasoning, never think out
  loud, never write any <think> tags.

===== KNOWLEDGE BASE =====
${CONTEXT}
===== END OF KNOWLEDGE BASE =====`;

const app = express();
app.use(cors({
  origin: [
    'https://tchipa.co.uk',
    'https://www.tchipa.co.uk',
    'https://tarik9991.github.io',
    'http://localhost:8080',
    'http://127.0.0.1:8080',
  ],
}));
app.use(express.json({ limit: '32kb' }));

// ---- rate limit en mémoire : N questions / fenêtre / IP ----
const RL_MAX = 25;            // questions max
const RL_WINDOW = 20 * 60e3; // par 20 minutes
const hits = new Map();       // ip -> [timestamps]
function rateLimited(ip) {
  const now = Date.now();
  const arr = (hits.get(ip) || []).filter(t => now - t < RL_WINDOW);
  arr.push(now);
  hits.set(ip, arr);
  return arr.length > RL_MAX;
}
setInterval(() => {
  const now = Date.now();
  for (const [ip, arr] of hits) {
    const keep = arr.filter(t => now - t < RL_WINDOW);
    if (keep.length) hits.set(ip, keep); else hits.delete(ip);
  }
}, RL_WINDOW).unref();

const isArabic = s => /[؀-ۿ]/.test(s || '');

// enlève un éventuel raisonnement laissé par les modèles « thinking »
function cleanAnswer(s) {
  if (!s) return s;
  s = s.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
  const m = s.match(/<\/think>\s*([\s\S]*)$/i);
  if (m) s = m[1].trim();
  return s.trim();
}

async function fetchWithTimeout(url, opts, ms) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try { return await fetch(url, { ...opts, signal: ctrl.signal }); }
  finally { clearTimeout(t); }
}

async function askOpenRouter(model, messages) {
  const r = await fetchWithTimeout('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${OPENROUTER_API_KEY}`,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://tchipa.co.uk',
      'X-Title': 'Tchipa Mena',
    },
    body: JSON.stringify({ model, messages, max_tokens: 800, temperature: 0.35,
      reasoning: { exclude: true } }),
  }, 45000);
  if (!r.ok) throw new Error(`OpenRouter ${model} HTTP ${r.status}`);
  const d = await r.json();
  const txt = cleanAnswer(d?.choices?.[0]?.message?.content?.trim());
  if (!txt) throw new Error(`OpenRouter ${model} réponse vide`);
  return txt;
}

async function askOllama(messages) {
  const r = await fetchWithTimeout(`${OLLAMA_URL}/api/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: OLLAMA_MODEL, messages, stream: false,
      options: { temperature: 0.35, num_ctx: 8192 } }),
  }, 90000);
  if (!r.ok) throw new Error(`Ollama HTTP ${r.status}`);
  const d = await r.json();
  const txt = cleanAnswer(d?.message?.content?.trim());
  if (!txt) throw new Error('Ollama réponse vide');
  return txt;
}

app.get('/health', (_req, res) => {
  res.json({ ok: true, service: 'tchipa-ai', openrouter: !!OPENROUTER_API_KEY, models: FREE_MODELS, ollama: OLLAMA_MODEL });
});

app.post('/ask', async (req, res) => {
  const ip = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || 'unknown')
    .toString().split(',')[0].trim();
  let question = (req.body?.question || '').toString().trim();
  const history = Array.isArray(req.body?.history) ? req.body.history.slice(-6) : [];
  if (!question) return res.status(400).json({ error: 'question manquante' });
  if (question.length > 1500) question = question.slice(0, 1500);

  const ar = isArabic(question);
  if (rateLimited(ip)) {
    return res.status(429).json({
      error: 'rate_limited',
      answer: ar
        ? 'لقد طرحت العديد من الأسئلة في وقت قصير. يُرجى المحاولة مرة أخرى بعد قليل.'
        : "Vous avez posé beaucoup de questions en peu de temps. Merci de réessayer dans un moment.",
    });
  }

  const langDirective = ar
    ? 'تعليمة صارمة وإلزامية: هذا السؤال مكتوب بالعربية. اكتب كامل إجابتك بالعربية فقط.'
    : "Reply strictly in the SAME language as the user's question (French, English or Algerian darija). Do not switch language.";

  const messages = [
    { role: 'system', content: SYSTEM_PROMPT },
    ...history
      .filter(m => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
      .map(m => ({ role: m.role, content: m.content.slice(0, 2000) })),
    { role: 'system', content: langDirective },
    { role: 'user', content: question },
  ];

  const errors = [];
  if (OPENROUTER_API_KEY) {
    for (const model of FREE_MODELS) {
      try {
        const answer = await askOpenRouter(model, messages);
        return res.json({ answer, model, lang: ar ? 'ar' : 'other' });
      } catch (e) { errors.push(e.message); }
    }
  }
  try {
    const answer = await askOllama(messages);
    return res.json({ answer, model: `ollama:${OLLAMA_MODEL}`, lang: ar ? 'ar' : 'other' });
  } catch (e) {
    errors.push(e.message);
    console.error('[tchipa-ai] tous les modèles ont échoué:', errors.join(' | '));
    return res.status(503).json({
      error: 'unavailable',
      answer: ar
        ? 'المساعد غير متاح مؤقتاً. يُرجى المحاولة لاحقاً أو التواصل عبر تيليغرام.'
        : "L'assistant est momentanément indisponible. Réessayez plus tard ou contactez-nous sur Telegram.",
    });
  }
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`[tchipa-ai] écoute sur 127.0.0.1:${PORT} — OpenRouter:${!!OPENROUTER_API_KEY} Ollama:${OLLAMA_MODEL}`);
});
