import os, json, base64, traceback, re, requests
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS

app = Flask(__name__, static_folder="/var/www/html/import", static_url_path="")
CORS(app)

OLLAMA_URL   = "http://localhost:11434/api/chat"
OLLAMA_MODEL = "gemma3:4b"
UPLOAD_FOLDER = "/tmp/import_uploads"
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

EXTRACT_PROMPT = """You are a product data extraction assistant. Look at the screenshot and return a JSON object with exactly these fields:

{
  "name": "full product name as shown",
  "price": "price as shown, e.g. 29.99",
  "currency": "3-letter ISO code if detectable, else null",
  "variants": [
    { "label": "variant option label", "value": "option value" }
  ],
  "image_url": null,
  "source_url": null
}

Rules:
- variants: each selectable option (size, colour, storage, etc.) becomes one entry. If none, return [].
- price: digits only, no currency symbol, e.g. "19.99".
- currency: e.g. "USD", "EUR", "CNY". Infer from symbol if needed.
- If a field cannot be determined return null.
- Return ONLY raw JSON, no markdown fences, no extra text."""


def _strip_fences(raw):
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1] if "\n" in raw else raw[3:]
    if raw.endswith("```"):
        raw = raw[:-3]
    return raw.strip()


def _call_ollama(image_b64):
    resp = requests.post(
        OLLAMA_URL,
        json={
            "model": OLLAMA_MODEL,
            "messages": [{
                "role": "user",
                "content": EXTRACT_PROMPT,
                "images": [image_b64],
            }],
            "stream": False,
        },
        timeout=120,
    )
    resp.raise_for_status()
    return _strip_fences(resp.json()["message"]["content"])


@app.route("/")
def index():
    return send_from_directory("/var/www/html/import", "index.html")


@app.route("/extract", methods=["POST"])
def extract():
    file = request.files.get("screenshot")
    if not file or not file.filename:
        return jsonify({"error": "No screenshot provided"}), 400

    ext = os.path.splitext(file.filename)[1].lower() or ".png"
    save_path = os.path.join(UPLOAD_FOLDER, f"upload{ext}")
    raw = ""
    try:
        file.save(save_path)
        with open(save_path, "rb") as f:
            image_b64 = base64.b64encode(f.read()).decode()

        raw = _call_ollama(image_b64)
        data = json.loads(raw)
        return jsonify(data)

    except json.JSONDecodeError as e:
        return jsonify({"error": "Model returned non-JSON", "raw": raw, "detail": str(e)}), 502
    except Exception as e:
        return jsonify({"error": str(e), "trace": traceback.format_exc()}), 500
    finally:
        if os.path.exists(save_path):
            os.remove(save_path)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5055, debug=False)
