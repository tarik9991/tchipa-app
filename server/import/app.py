import os, json, base64, traceback, re, requests
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS

app = Flask(__name__, static_folder="/var/www/html/import", static_url_path="")
CORS(app)

OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "")
UPLOAD_FOLDER = "/tmp/import_uploads"
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

EXTRACT_PROMPT = """You are a product data extraction assistant. Return a JSON object with exactly these fields:

{
  "name": "full product name as shown",
  "variants": [
    { "label": "variant option label", "value": "option value" }
  ],
  "price": "price as shown, e.g. $29.99",
  "currency": "3-letter ISO code if detectable, else null",
  "source_url": null
}

Rules:
- variants: each selectable option (size, colour, storage, etc.) becomes one entry. If none, return [].
- price: include any sale/original price distinction, e.g. "$19.99 (was $29.99)".
- If a field cannot be determined return null.
- Return ONLY raw JSON, no markdown fences, no extra text."""


def _strip_fences(raw):
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1] if "\n" in raw else raw[3:]
        if raw.endswith("```"):
            raw = raw[:-3].strip()
    return raw


def _call_model(content_blocks, prompt_extra=""):
    prompt = EXTRACT_PROMPT
    if prompt_extra:
        prompt += f"\n\n{prompt_extra}"
    content_blocks.append({"type": "text", "text": prompt})

    resp = requests.post(
        "https://openrouter.ai/api/v1/chat/completions",
        headers={
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
        },
        json={
            "model": "google/gemini-2.0-flash-001",
            "messages": [{"role": "user", "content": content_blocks}],
        },
        timeout=90,
    )
    resp.raise_for_status()
    return _strip_fences(resp.json()["choices"][0]["message"]["content"])


def _fetch_url_text(url):
    """Fetch a product page and return stripped visible text (≤ 8000 chars)."""
    r = requests.get(url, timeout=20, headers={"User-Agent": "Mozilla/5.0"})
    r.raise_for_status()
    # Remove scripts/styles, collapse whitespace
    text = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", r.text, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:8000]


@app.route("/")
def index():
    return send_from_directory("/var/www/html/import", "index.html")


@app.route("/extract", methods=["POST"])
def extract():
    if not OPENROUTER_API_KEY:
        return jsonify({"error": "OPENROUTER_API_KEY not configured on server"}), 500

    product_url = request.form.get("url", "").strip()
    file = request.files.get("screenshot")
    has_file = file and file.filename

    if not has_file and not product_url:
        return jsonify({"error": "Provide a screenshot or a product URL"}), 400

    save_path = None
    raw = ""
    try:
        if has_file:
            # --- IMAGE PATH ---
            ext = os.path.splitext(file.filename)[1].lower() or ".png"
            mime_map = {".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                        ".png": "image/png", ".webp": "image/webp", ".gif": "image/gif"}
            mime_type = mime_map.get(ext, "image/png")

            save_path = os.path.join(UPLOAD_FOLDER, f"upload{ext}")
            file.save(save_path)

            with open(save_path, "rb") as f:
                image_b64 = base64.b64encode(f.read()).decode()

            content = [{"type": "image_url",
                        "image_url": {"url": f"data:{mime_type};base64,{image_b64}"}}]
            extra = f"Caller-provided URL: {product_url}" if product_url else ""
            raw = _call_model(content, extra)

        else:
            # --- URL-ONLY PATH ---
            try:
                page_text = _fetch_url_text(product_url)
                extra = f"Source URL: {product_url}\n\nPage text:\n{page_text}"
            except Exception:
                extra = f"Source URL: {product_url}"
            raw = _call_model([], extra)

        data = json.loads(raw)
        if product_url:
            data["source_url"] = product_url
        return jsonify(data)

    except json.JSONDecodeError as e:
        return jsonify({"error": "Model returned non-JSON", "raw": raw, "detail": str(e)}), 502
    except Exception as e:
        return jsonify({"error": str(e), "trace": traceback.format_exc()}), 500
    finally:
        if save_path and os.path.exists(save_path):
            os.remove(save_path)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5055, debug=False)
