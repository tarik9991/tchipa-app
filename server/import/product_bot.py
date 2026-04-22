import asyncio
import json
import os
import sys
import traceback
from pathlib import Path

import requests
from playwright.async_api import async_playwright

SERVER_URL = os.getenv("EXTRACT_SERVER", "http://localhost:5055/extract")

COOKIE_FILE = Path(__file__).parent / "temu_cookies.json"


def _load_cookies(_url: str = "") -> list[dict]:
    """Load Playwright-format cookies from temu_cookies.json."""
    if not COOKIE_FILE.exists():
        print(f"[warn] {COOKIE_FILE.name} not found — running without cookies", file=sys.stderr)
        return []
    try:
        cookies = json.loads(COOKIE_FILE.read_text())
    except Exception as e:
        print(f"[warn] Could not read {COOKIE_FILE.name}: {e}", file=sys.stderr)
        return []

    # Normalise sameSite values that Playwright rejects
    _SAME_SITE_MAP = {"unspecified": "Lax", "no_restriction": "None"}
    for c in cookies:
        c.pop("hostOnly", None)
        c.pop("session",  None)
        c.pop("storeId",  None)
        c.pop("id",       None)
        if "expirationDate" in c:
            c.setdefault("expires", int(c.pop("expirationDate")))
        c["sameSite"] = _SAME_SITE_MAP.get(c.get("sameSite", "Lax"), c.get("sameSite", "Lax"))

    return cookies

# CSS that hides common login/region-gate overlays
OVERLAY_HIDE_CSS = """
.login-mask, .login-modal, .region-modal, .country-modal,
[class*="login-overlay"], [class*="sign-in-wall"],
[class*="auth-modal"], [class*="gate-modal"] {
    display: none !important;
}
body { overflow: auto !important; }
"""


async def _dismiss_overlays(page):
    """Best-effort overlay removal: Escape key + CSS injection."""
    try:
        await page.keyboard.press("Escape")
    except Exception:
        pass
    await page.add_style_tag(content=OVERLAY_HIDE_CSS)


async def _is_blocked(page) -> bool:
    """Return True if the page still shows a login / auth wall."""
    content = (await page.content()).lower()
    blocked_signals = [
        "continue with google",
        "sign in to continue",
        "log in to see prices",
        "login required",
    ]
    return any(sig in content for sig in blocked_signals)


async def _product_title_visible(page) -> bool:
    """Return True if at least one product-title-like element is visible."""
    selectors = [
        "[class*='product-title']",
        "[class*='product-name']",
        "[class*='item-title']",
        "h1",
    ]
    for sel in selectors:
        try:
            el = page.locator(sel).first
            if await el.is_visible(timeout=2000):
                return True
        except Exception:
            pass
    return False


async def scrape(url: str) -> dict:
    cookies = _load_cookies()
    print(f"[bot] Loaded {len(cookies)} cookies into context")

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)
        context = await browser.new_context(
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            ),
            locale="fr-FR",
            timezone_id="Europe/Paris",
        )

        # Cookie injection before navigation to avoid initial popups
        await context.add_cookies(cookies)

        page = await context.new_page()

        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=30_000)

            # Human-like pause then Escape
            await asyncio.sleep(2)
            await _dismiss_overlays(page)
            await asyncio.sleep(1)

            # If title still not visible, inject overlay-hiding CSS
            if not await _product_title_visible(page):
                await page.add_style_tag(content=OVERLAY_HIDE_CSS)
                await asyncio.sleep(1)

            # Verification: bail early if login wall is still present
            if await _is_blocked(page):
                return {
                    "error": "blocked",
                    "message": "Temu is blocking me, retrying with another method...",
                }

            screenshot_bytes = await page.screenshot(full_page=False, type="png")

        finally:
            await browser.close()

    # Send screenshot to local extract server
    resp = requests.post(
        SERVER_URL,
        files={"screenshot": ("page.png", screenshot_bytes, "image/png")},
        timeout=120,
    )
    resp.raise_for_status()
    return resp.json()


def main():
    if len(sys.argv) < 2:
        print("Usage: python product_bot.py <product-url>", file=sys.stderr)
        sys.exit(1)

    url = sys.argv[1]
    try:
        result = asyncio.run(scrape(url))
    except Exception as e:
        result = {"error": str(e), "trace": traceback.format_exc()}

    if result.get("error") == "blocked":
        print(result["message"])
    else:
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
