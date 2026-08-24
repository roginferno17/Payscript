import argparse
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).with_name(".env"))
except ImportError:
    pass

import requests as req_lib

import undetected_chromedriver as uc
from selenium import webdriver
from selenium.common.exceptions import ElementClickInterceptedException, TimeoutException
from selenium.webdriver.chrome.options import Options as ChromeOptions
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.edge.options import Options as EdgeOptions
from selenium.webdriver.edge.service import Service as EdgeService
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait


URL     = "https://arbpay.me"
API_URLS = [
    "https://apiweb.apiarbpay.com",
    "https://apiweb.payapiar.com",
    "https://apiweb.asjoby.com",
    "https://apiweb.arbpay.me"
]
API_URL = API_URLS[0]
PHONE_NUMBER = os.environ.get("PHONE_NUMBER", "")
PASSWORD = os.environ.get("PASSWORD", "")

# ── Speed tunables ────────────────────────────────────────────────────────────
CLICK_INTERVAL   = 0.0   # seconds between buy clicks (0 = as fast as possible)
POPUP_PAUSE      = 0.1
INPUT_SETTLE     = 0.05
LOGIN_SETTLE     = 0.5
# ─────────────────────────────────────────────────────────────────────────────


def log(message: str):
    timestamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{timestamp}] {message}", flush=True)


def build_driver(browser: str, headless: bool):
    log(f"Starting {browser} browser")
    common_args = [
        "--start-maximized",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--disable-notifications",
        "--disable-popup-blocking",
    ]
    if browser == "edge":
        options = EdgeOptions()
        options.add_experimental_option("detach", True)
        if headless:
            options.add_argument("--headless=new")
        for arg in common_args:
            options.add_argument(arg)
        return webdriver.Edge(service=EdgeService(), options=options)

    # Use undetected_chromedriver to bypass Cloudflare bot detection
    options = uc.ChromeOptions()
    options.set_capability("goog:loggingPrefs", {"performance": "ALL"})
    if headless:
        options.add_argument("--headless=new")
    for arg in common_args:
        options.add_argument(arg)

    try:
        return uc.Chrome(options=options, use_subprocess=True)
    except Exception as e:
        log(f"[WARN] Standard UC init failed ({e}), attempting version_main=151...")
        try:
            return uc.Chrome(options=options, version_main=151, use_subprocess=True)
        except Exception as e2:
            log(f"[WARN] Version 151 UC init failed ({e2}), falling back to Edge...")
            edge_opts = EdgeOptions()
            edge_opts.set_capability("goog:loggingPrefs", {"performance": "ALL"})
            if headless:
                edge_opts.add_argument("--headless=new")
            for arg in common_args:
                edge_opts.add_argument(arg)
            return webdriver.Edge(options=edge_opts)


# ── API layer — all calls run inside Chrome via fetch() to bypass Cloudflare ──
# Endpoints confirmed from network capture:
#   POST /ar-wallet/buyCenter/buyList                     → order list
#   POST /ar-wallet/buyCenter/beforeBuy                   → reserve slot
#   POST /ar-wallet/buyCenter/buy                         → place order
#   POST /ar-wallet/buyCenter/getPaymentPageDataEncryption → QR data

_api_driver = None      # Selenium WebDriver used for all fetch() calls
_api_token      = ""
_api_device_code = ""


def build_api_session(driver):
    """Extract token + deviceCode from localStorage; store driver for fetch() calls."""
    global _api_driver, _api_token, _api_device_code
    try:
        ls = driver.execute_script(
            "return Object.entries(window.localStorage)"
            ".reduce((o,[k,v])=>{o[k]=v;return o},{});"
        )
        token       = json.loads(ls.get("token",      "{}")).get("value", "")
        device_code = json.loads(ls.get("deviceCode", "{}")).get("value", "")
    except Exception as e:
        log(f"Could not read localStorage: {e}")
        return None

    if not token:
        log("No token found in localStorage — cannot build API session")
        return None

    _api_driver      = driver
    _api_token       = token
    _api_device_code = device_code
    log(f"API session built — token ends ...{token[-12:]} (browser-fetch mode)")
    return driver   # truthy sentinel so callers know session is ready


def browser_fetch(path: str, body: dict, page: str = "Arb") -> dict:
    """
    POST to API_URL+path from inside Chrome using synchronous XHR.
    Runs via execute_script (blocking) — no async timeout issues.
    Returns parsed JSON dict, or {} on error.
    """
    global _api_driver, _api_token, _api_device_code
    if not _api_driver:
        return {}
    js = """
var xhr = new XMLHttpRequest();
xhr.open('POST', arguments[0], false);
xhr.setRequestHeader('Accept', 'application/json, text/plain, */*');
xhr.setRequestHeader('Content-Type', 'application/json');
xhr.setRequestHeader('authorization', 'Bearer ' + arguments[2]);
xhr.setRequestHeader('deviceCode', arguments[3]);
xhr.setRequestHeader('deviceId', '');
xhr.setRequestHeader('deviceType', '3');
xhr.setRequestHeader('language', '1');
xhr.setRequestHeader('page', arguments[4]);
try {
  xhr.send(JSON.stringify(arguments[1]));
  return {ok: true, status: xhr.status, text: xhr.responseText};
} catch(e) {
  return {ok: false, status: 0, text: String(e)};
}
"""
    try:
        result = _api_driver.execute_script(
            js,
            f"{API_URL}{path}",
            body,
            _api_token,
            _api_device_code,
            page,
        )
        if not result:
            return {}
        if not result.get("ok") or result.get("status", 0) not in (200, 201):
            return {}
        text = result.get("text", "")
        return json.loads(text)
    except Exception as e:
        if _buylist_call_count <= 1:
            log(f"[DEBUG] browser_fetch exception: {e}")
        return {}


def enable_cdp_network(driver):
    try:
        driver.execute_cdp_cmd("Network.enable", {})
    except Exception:
        pass


_buylist_call_count = 0

def reset_buylist_debug():
    global _buylist_call_count
    _buylist_call_count = 0

def api_get_order_list(amount_min: int = 100, amount_max: int = 1000):
    """
    POST /ar-wallet/buyCenter/buyList via browser fetch().
    Returns orders filtered to amount_min–amount_max.
    """
    global _api_driver, _buylist_call_count
    if not _api_driver:
        return []
    _buylist_call_count += 1
    try:
        data = browser_fetch("/ar-wallet/buyCenter/buyList", {"orderType": 1, "pageNo": 1})

        if _buylist_call_count == 1:
            log(f"[DEBUG] buyList response: {json.dumps(data)[:400]}")

        # Unwrap nested response shapes — try every common key
        records = []
        if isinstance(data, list):
            records = data
        elif isinstance(data, dict):
            for top_key in ("data", "result", "body", "response"):
                inner = data.get(top_key)
                if inner is None:
                    continue
                if isinstance(inner, list):
                    records = inner
                    break
                if isinstance(inner, dict):
                    for sub_key in ("records", "list", "rows", "data", "items", "content"):
                        val = inner.get(sub_key)
                        if val and isinstance(val, list):
                            records = val
                            break
                    if records:
                        break

        if not records and _buylist_call_count == 1:
            log(f"[DEBUG] Could not parse records — top-level keys: {list(data.keys()) if isinstance(data, dict) else type(data)}")

        filtered = [
            o for o in records
            if amount_min <= float(o.get("amount", 0)) <= amount_max
        ]
        return filtered
    except Exception as e:
        if _buylist_call_count == 1:
            log(f"[DEBUG] buyList exception: {e}")
        return []


def api_before_buy(platform_order: str, amount: int) -> dict:
    return browser_fetch("/ar-wallet/buyCenter/beforeBuy",
                         {"amount": amount, "platformOrder": platform_order,
                          "payType": "3", "orderType": 1})


# Bank codes to cycle through when server rejects the current one (code 2005)
BANK_CODES = [
    "mobikwik", "paytm", "phonepe", "gpay", "amazonpay", "freecharge", "airtel",
    "supermoney", "freo", "slice", "twid", "pop", "navi", "moneyView", "induspay", "jio"
]

def api_buy(platform_order: str, amount: int,
            buy_bank_code: str = "mobikwik", buyer_kyc_id: int = 0) -> dict:
    return browser_fetch("/ar-wallet/buyCenter/buy",
                         {"amount": amount, "platformOrder": platform_order,
                          "payType": "3", "orderType": 1,
                          "buyBankCode": buy_bank_code, "buyerKycId": buyer_kyc_id})


def api_get_payment_page(mr_order: str) -> dict:
    return browser_fetch("/ar-wallet/buyCenter/getPaymentPageDataEncryption",
                         {"platformOrder": mr_order}, page="ArbCashier")


def extract_mr_order(buy_response: dict) -> str:
    """Dig out the MR order number from the buy API response."""
    if not buy_response:
        return ""
    data = buy_response.get("data") or buy_response.get("result") or {}
    if isinstance(data, str) and data.startswith("MR"):
        return data
    if isinstance(data, dict):
        order = (data.get("buyOrderNo") or data.get("platformOrder")
                 or data.get("orderNo") or data.get("mOrderNo") or "")
        if order:
            return order
    return ""


def api_fast_buy_loop(amount_min: int = 100, amount_max: int = 1000, driver=None):
    """
    Tight loop: buyList → beforeBuy → buy → return MR order on success.
    All calls run inside Chrome via fetch() — Cloudflare transparent.
    """
    log("API fast-buy loop started (browser-fetch mode)")
    attempts = 0
    empty_streak = 0
    bank_index = 0               # cycles through BANK_CODES on 2005
    skipped_orders = set()       # orders that returned 2005 for ALL banks
    fetch_fail_streak = 0        # consecutive empty fetch() responses

    while True:
        attempts += 1

        orders = api_get_order_list(amount_min, amount_max)
        if not orders:
            empty_streak += 1
            if empty_streak % 20 == 0:
                log(f"No orders in range {amount_min}-{amount_max} (attempt {attempts})...")
            # If fetch keeps returning nothing, try to rebuild the session
            if empty_streak >= 100:
                log("[WARN] 100 consecutive empty buyList — rebuilding API session")
                if driver:
                    build_api_session(driver)
                empty_streak = 0
            time.sleep(0.05)
            continue

        empty_streak = 0
        fetch_fail_streak = 0

        # Pick the first order not in our skip list
        order = None
        for o in orders:
            oid = o.get("platformOrder") or o.get("orderNo") or o.get("mOrderNo") or ""
            if oid and oid not in skipped_orders:
                order = o
                break
        if not order:
            # All visible orders have been skipped — clear and retry
            skipped_orders.clear()
            time.sleep(0.1)
            continue

        platform_order = (order.get("platformOrder") or order.get("orderNo")
                          or order.get("mOrderNo") or "")
        amount = int(order.get("amount", 0))

        if not platform_order:
            time.sleep(0.05)
            continue

        if attempts == 1 or attempts % 50 == 0:
            log(f"API attempt {attempts}: order={platform_order} amount={amount}")

        # Skip beforeBuy — go straight to buy to win the race.
        current_bank = BANK_CODES[bank_index % len(BANK_CODES)]
        buy_resp = api_buy(platform_order, amount, buy_bank_code=current_bank)
        buy_code = str(buy_resp.get("code", ""))

        # Detect fetch() failures (empty dict = network/session error)
        if not buy_resp:
            fetch_fail_streak += 1
            if fetch_fail_streak >= 5:
                log(f"[WARN] {fetch_fail_streak} consecutive empty buy responses — rebuilding API session")
                if driver:
                    build_api_session(driver)
                fetch_fail_streak = 0
            time.sleep(0.1)
            continue
        fetch_fail_streak = 0

        # Log every unique buy code to see what the server is returning
        if not hasattr(api_fast_buy_loop, "_seen_codes"):
            api_fast_buy_loop._seen_codes = set()
        if buy_code not in api_fast_buy_loop._seen_codes:
            api_fast_buy_loop._seen_codes.add(buy_code)
            log(f"[DEBUG] buy code={buy_code} resp={json.dumps(buy_resp)[:200]}")

        if buy_code in ("200", "0", "1", "00", "success", "SUCCESS"):
            mr_order = extract_mr_order(buy_resp)
            if mr_order:
                log(f"Buy SUCCESS after {attempts} attempts — MR order: {mr_order}")
                return mr_order, amount
            else:
                log(f"[DEBUG] buy code={buy_code} but no MR order found. Full resp: {json.dumps(buy_resp)[:300]}")
        elif buy_code == "2005":
            # "Please select another bank" — try next bank code
            log(f"[DEBUG] Bank '{current_bank}' rejected for {platform_order} — trying next bank")
            bank_index += 1
            if bank_index % len(BANK_CODES) == 0:
                # Exhausted all banks for this order — skip it
                log(f"[DEBUG] All banks rejected for {platform_order} — skipping order")
                skipped_orders.add(platform_order)
                bank_index = 0
            time.sleep(0.05)
            continue
        elif buy_code == "1027":
            # Unfinished order exists — recover it and proceed to payment
            data = buy_resp.get("data") or {}
            existing_order = data.get("platformOrder", "")
            if existing_order:
                log(f"Existing unfinished order detected: {existing_order} — proceeding to payment")
                return existing_order, amount
        elif buy_code == "1191":
            # Rate limited — server asks to wait 5 seconds
            time.sleep(5.0)
            continue
        # code 1194 = snatched by someone else — just keep looping

        time.sleep(0.02)


# ── Stale-safe DOM helpers ────────────────────────────────────────────────────

def safe_get_attr(el, attr):
    try:
        return el.get_attribute(attr) or ""
    except Exception:
        return ""


def safe_is_displayed(el):
    try:
        return el.is_displayed()
    except Exception:
        return False


def safe_is_enabled(el):
    try:
        return el.is_enabled()
    except Exception:
        return False


def visible_enabled_elements(driver, by, value):
    matches = []
    try:
        for element in driver.find_elements(by, value):
            try:
                if safe_is_displayed(element) and safe_is_enabled(element):
                    matches.append(element)
            except Exception:
                continue
    except Exception:
        pass
    return matches


def first_visible(driver, selectors, description: str, per_selector_timeout: float = 0.5):
    for by, value in selectors:
        deadline = time.time() + per_selector_timeout
        while time.time() < deadline:
            matches = visible_enabled_elements(driver, by, value)
            if matches:
                log(f"Matched {description}: {by}={value}")
                return matches[0]
            time.sleep(0.1)
    raise TimeoutException(f"No visible element found for {description}")


def click_element(driver, element, description: str):
    try:
        driver.execute_script("arguments[0].scrollIntoView({block:'center'});", element)
    except Exception:
        pass
    try:
        element.click()
    except Exception:
        try:
            driver.execute_script("arguments[0].click();", element)
        except Exception:
            pass


def visible_clickables(driver):
    clickables = []
    selectors = [
        (By.TAG_NAME, "button"),
        (By.XPATH, "//*[@role='button']"),
        (By.XPATH, "//input[@type='button' or @type='submit']"),
        (By.XPATH, "//a"),
    ]
    seen = set()
    for by, value in selectors:
        for element in visible_enabled_elements(driver, by, value):
            try:
                key = element.id
            except Exception:
                key = None
            if key and key in seen:
                continue
            if key:
                seen.add(key)
            clickables.append(element)
    return clickables


def visible_text_matches(driver, texts):
    targets = {normalize_text(t) for t in texts}
    matches = []
    seen = set()
    try:
        for element in driver.find_elements(By.XPATH, "//*"):
            try:
                if not safe_is_displayed(element):
                    continue
                text     = normalize_text(element.text)
                aria     = normalize_text(safe_get_attr(element, "aria-label"))
                val      = normalize_text(safe_get_attr(element, "value"))
                combined = " ".join(p for p in [text, aria, val] if p)
                if not combined or not any(t in combined for t in targets):
                    continue
                rect = element.rect or {}
                area = rect.get("width", 0) * rect.get("height", 0)
                if area <= 0:
                    continue
                key = element.id
                if key in seen:
                    continue
                seen.add(key)
                matches.append((area, combined, element))
            except Exception:
                continue
    except Exception:
        pass
    matches.sort(key=lambda item: item[0])
    return matches


def normalize_text(value: str):
    return " ".join((value or "").split()).strip().lower()


def compact_text(value: str):
    return re.sub(r"[^a-z0-9]+", "", normalize_text(value))


def find_clickable_by_text(driver, texts, description: str, timeout: float = 12.0):
    targets         = {normalize_text(t) for t in texts}
    compact_targets = {compact_text(t) for t in texts}
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            for element in visible_clickables(driver):
                text  = normalize_text(element.text)
                aria  = normalize_text(safe_get_attr(element, "aria-label"))
                title = normalize_text(safe_get_attr(element, "title"))
                val   = normalize_text(safe_get_attr(element, "value"))
                if any(compact_text(c) in compact_targets for c in [text, aria, title, val] if c):
                    return element
        except Exception:
            pass

        try:
            xpath = " | ".join(
                f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]"
                for t in targets
            )
            if xpath:
                direct = visible_enabled_elements(driver, By.XPATH, xpath)
                if direct:
                    return min(direct, key=lambda e: (e.rect or {}).get("width", 0) * (e.rect or {}).get("height", 0))
        except Exception:
            pass

        try:
            for element in visible_clickables(driver):
                text  = normalize_text(element.text)
                aria  = normalize_text(safe_get_attr(element, "aria-label"))
                title = normalize_text(safe_get_attr(element, "title"))
                val   = normalize_text(safe_get_attr(element, "value"))
                if any(t in c for c in [text, aria, title, val] for t in targets):
                    return element
        except Exception:
            pass

        try:
            hits = visible_text_matches(driver, texts)
            if hits:
                return hits[0][2]
        except Exception:
            pass

        time.sleep(0.05)
    raise TimeoutException(f"No clickable element found for {description}")


def click_by_text(driver, texts, description: str, timeout: float = 12.0):
    element = find_clickable_by_text(driver, texts, description, timeout=timeout)
    click_element(driver, element, description)
    return element


# ── QR / payment screen detection ─────────────────────────────────────────────

def qr_screen_visible(driver):
    text_markers = [
        "qr code", "scan qr", "scan the qr", "upi id",
        "payment countdown", "complete payment", "copy upi",
        "save qr", "payment time",
    ]
    try:
        page_text = normalize_text(driver.find_element(By.TAG_NAME, "body").text)
        if any(m in page_text for m in text_markers):
            return True
    except Exception:
        pass

    qr_selectors = [
        (By.XPATH, "//canvas"),
        (By.XPATH, "//img[contains(translate(@src,'QR','qr'),'qr') or contains(translate(@alt,'QR','qr'),'qr')]"),
        (By.XPATH, "//*[contains(translate(normalize-space(.),'QR','qr'),'qr code')]"),
    ]
    for by, value in qr_selectors:
        try:
            for el in driver.find_elements(by, value):
                try:
                    if not safe_is_displayed(el):
                        continue
                    rect = el.rect or {}
                    if rect.get("width", 0) >= 120 and rect.get("height", 0) >= 120:
                        return True
                except Exception:
                    continue
        except Exception:
            continue
    return False


def payment_done_screen_visible(driver):
    """Detect a post-payment success/confirmation screen."""
    markers = [
        "payment successful", "payment completed", "order confirmed",
        "transaction successful", "purchase successful", "success",
        "order placed", "thank you", "payment received",
    ]
    try:
        page_text = normalize_text(driver.find_element(By.TAG_NAME, "body").text)
        if any(m in page_text for m in markers):
            return True
    except Exception:
        pass
    return False


# ── FAST targeted Buy button click ────────────────────────���───────────────────
# Based on the screenshot: yellow Buy buttons inside list rows.
# We grab ALL of them directly via XPath/CSS — no full DOM scan needed.

BUY_BUTTON_XPATHS = [
    # Most specific: a button whose ONLY visible text is "Buy"
    "//button[normalize-space(.)='Buy']",
    # Fallback: any button containing exactly "buy" (case-insensitive)
    "//button[translate(normalize-space(.),'BUY','buy')='buy']",
    # Role-button fallback
    "//*[@role='button' and translate(normalize-space(.),'BUY','buy')='buy']",
]


def get_all_buy_buttons(driver):
    """
    Return every visible, enabled Buy button as fast as possible.
    Uses targeted XPath — no full clickable scan.
    """
    seen = set()
    results = []
    for xpath in BUY_BUTTON_XPATHS:
        try:
            for el in driver.find_elements(By.XPATH, xpath):
                try:
                    eid = el.id
                    if eid in seen:
                        continue
                    seen.add(eid)
                    if safe_is_displayed(el) and safe_is_enabled(el):
                        results.append(el)
                except Exception:
                    continue
        except Exception:
            continue
    return results


def click_first_buy_button_fast(driver):
    """
    Click the first (topmost) Buy button using JS — returns True on success.
    """
    buttons = get_all_buy_buttons(driver)
    if not buttons:
        return False

    # Pick topmost by Y coordinate
    best = None
    best_y = float("inf")
    for btn in buttons:
        try:
            y = (btn.rect or {}).get("y", float("inf"))
            if y < best_y:
                best_y = y
                best = btn
        except Exception:
            continue

    if best is None:
        return False

    try:
        driver.execute_script("arguments[0].click();", best)
        return True
    except Exception:
        return False


# ── INFINITE buy loop ────────────────────────────────────────────���────────────

def click_buy_infinite(driver):
    """
    Click the first Buy button as fast as possible until QR screen appears.
    Returns total clicks performed.
    """
    log("Infinite buy-click loop started (Ctrl-C to abort)")
    clicks = 0
    consecutive_misses = 0

    while True:
        # QR / payment screen check
        try:
            if qr_screen_visible(driver):
                log(f"QR screen detected after {clicks} buy clicks")
                return clicks
        except Exception:
            pass

        # Fast targeted click
        try:
            hit = click_first_buy_button_fast(driver)
            if hit:
                clicks += 1
                consecutive_misses = 0
                if clicks == 1 or clicks % 50 == 0:
                    log(f"Clicked Buy {clicks} time(s)")
            else:
                consecutive_misses += 1
        except Exception:
            consecutive_misses += 1

        # Safety valve
        if consecutive_misses >= 20:
            log("20 consecutive misses — pausing 0.5s for DOM to settle")
            time.sleep(0.5)
            consecutive_misses = 0

        if CLICK_INTERVAL > 0:
            time.sleep(CLICK_INTERVAL)


# ── Wait for payment to complete ──────────────────────────────────────────────

def wait_for_payment_completion(driver, timeout: float = 300.0):
    """
    After QR appears, wait until user completes payment (success screen).
    Polls every second. Times out after `timeout` seconds (default 5 min).
    """
    log("Waiting for payment to complete (watching for success screen)...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if payment_done_screen_visible(driver):
                log("Payment success screen detected!")
                return True
        except Exception:
            pass
        time.sleep(1.0)
    log("Payment completion timed out — continuing anyway")
    return False


# ── Login helpers ─────────────────────────────────────────────────────────────

def log_visible_inputs(driver):
    inputs = visible_enabled_elements(driver, By.TAG_NAME, "input")
    log(f"Found {len(inputs)} visible enabled inputs")
    for i, el in enumerate(inputs[:6], 1):
        log(f"  Input {i}: type={safe_get_attr(el, 'type')!r} "
            f"placeholder={safe_get_attr(el, 'placeholder')!r}")


def wait_for_visible_inputs(driver, minimum_count: int = 2, timeout: float = 8.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        inputs = visible_enabled_elements(driver, By.TAG_NAME, "input")
        if len(inputs) >= minimum_count:
            return inputs
        time.sleep(0.1)
    return visible_enabled_elements(driver, By.TAG_NAME, "input")


def fallback_inputs(driver):
    inputs = visible_enabled_elements(driver, By.TAG_NAME, "input")
    phone_input = password_input = None
    for el in inputs:
        t    = (safe_get_attr(el, "type") or "text").lower()
        ph   = safe_get_attr(el, "placeholder").lower()
        name = safe_get_attr(el, "name").lower()
        id_  = safe_get_attr(el, "id").lower()
        combined = " ".join([t, ph, name, id_])
        if password_input is None and t == "password":
            password_input = el
        if phone_input is None and any(tok in combined for tok in ["tel", "phone", "mobile", "username", "number"]):
            phone_input = el
    if phone_input is None:
        for el in inputs:
            if (safe_get_attr(el, "type") or "text").lower() in {"text", "tel", "number", "search", ""}:
                phone_input = el
                break
    return phone_input, password_input


def wait_for_login_form(driver, timeout: float = 30.0):
    deadline = time.time() + timeout
    log("Waiting for login page / mirror redirect to settle...")
    while time.time() < deadline:
        try:
            inputs = visible_enabled_elements(driver, By.TAG_NAME, "input")
            if any((safe_get_attr(el, "type") or "").lower() == "password" for el in inputs):
                log(f"Login form detected on {driver.current_url}")
                phone_input, password_input = fallback_inputs(driver)
                if phone_input and password_input:
                    return phone_input, password_input
        except Exception:
            pass
        time.sleep(0.5)

    phone_input, password_input = fallback_inputs(driver)
    if phone_input and password_input:
        return phone_input, password_input

    phone_selectors = [
        (By.CSS_SELECTOR, "input[type='tel']"),
        (By.CSS_SELECTOR, "input[inputmode='numeric']"),
        (By.CSS_SELECTOR, "input[autocomplete='username']"),
        (By.XPATH, "//input[contains(translate(@placeholder,'PHONE','phone'),'phone')]"),
        (By.XPATH, "//*[contains(normalize-space(.),'Phone Number')]/following::input[1]"),
        (By.XPATH, "(//input[@type='text'])[1]"),
    ]
    password_selectors = [
        (By.CSS_SELECTOR, "input[type='password']"),
        (By.CSS_SELECTOR, "input[autocomplete='current-password']"),
    ]
    try:
        phone_input = phone_input or first_visible(driver, phone_selectors, "phone input")
    except TimeoutException:
        pass
    try:
        password_input = password_input or first_visible(driver, password_selectors, "password input")
    except TimeoutException:
        pass

    if phone_input is None or password_input is None:
        raise TimeoutException("Could not identify both login inputs")
    return phone_input, password_input


def find_submit_button(driver):
    for btn in visible_enabled_elements(driver, By.TAG_NAME, "button"):
        try:
            if (btn.text or "").strip().lower() == "log in":
                return btn
        except Exception:
            continue
    selectors = [
        (By.CSS_SELECTOR, "button[type='submit']"),
        (By.XPATH, "//button[normalize-space(.)='Log In']"),
        (By.XPATH, "//button[contains(translate(normalize-space(.),'LOGIN','login'),'login')]"),
        (By.XPATH, "//input[@type='submit']"),
    ]
    return first_visible(driver, selectors, "submit button")


def set_input_value(driver, element, value: str, field_name: str):
    log(f"Filling {field_name}")
    driver.execute_script(
        """
        const el = arguments[0], v = arguments[1];
        el.scrollIntoView({block:'center'});
        el.focus();
        const proto = Object.getPrototypeOf(el);
        const desc  = Object.getOwnPropertyDescriptor(proto, 'value');
        desc.set.call(el, v);
        el.dispatchEvent(new Event('input',  {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        """,
        element, value,
    )
    if safe_get_attr(element, "value") == value:
        return
    log(f"JS fill did not stick for {field_name}, using keyboard fallback")
    element.click()
    element.send_keys(Keys.CONTROL, "a")
    element.send_keys(Keys.DELETE)
    element.send_keys(value)
    if safe_get_attr(element, "value") != value:
        raise RuntimeError(f"Failed to fill {field_name}")


def wait_for_cloudflare(driver, timeout: float = 60.0):
    """
    Block until Cloudflare's challenge/verification page clears.
    Cloudflare challenge pages have title 'Just a moment...' or contain
    the cf-challenge iframe / turnstile widget.
    Returns True when the real page is loaded, False on timeout.
    """
    log("Checking for Cloudflare challenge...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            title = driver.title or ""
            url   = driver.current_url or ""
            # Cloudflare interstitial indicators
            if "just a moment" in title.lower() or "checking your browser" in title.lower():
                remaining = int(deadline - time.time())
                log(f"Cloudflare challenge active — waiting... ({remaining}s left)")
                time.sleep(2.0)
                continue
            # Check for cf-challenge body class or turnstile iframe
            cf_present = driver.execute_script(
                "return !!(document.querySelector('iframe[src*=\"challenges.cloudflare\"]') "
                "|| document.querySelector('#cf-challenge-running') "
                "|| document.querySelector('.cf-browser-verification') "
                "|| document.querySelector('[data-ray]') "
                "|| (document.body && document.body.className && "
                "document.body.className.includes('cf-')));"
            )
            if cf_present:
                remaining = int(deadline - time.time())
                log(f"Cloudflare widget detected — waiting... ({remaining}s left)")
                time.sleep(2.0)
                continue
            # Real page is loaded
            log("Cloudflare challenge cleared — proceeding with login")
            return True
        except Exception:
            time.sleep(1.0)
    log(f"[WARN] Cloudflare challenge did not clear within {timeout}s")
    return False


def login(driver, phone: str, password: str):
    log(f"Opening {URL}")
    enable_cdp_network(driver)
    driver.get(URL)
    time.sleep(LOGIN_SETTLE)

    # Wait for Cloudflare bot check to clear before touching the login form
    wait_for_cloudflare(driver, timeout=60.0)

    phone_input, password_input = wait_for_login_form(driver)
    set_input_value(driver, phone_input,    phone,    "phone number")
    time.sleep(INPUT_SETTLE)
    set_input_value(driver, password_input, password, "password")
    time.sleep(INPUT_SETTLE)

    submit = find_submit_button(driver)
    log("Submitting login form")
    try:
        submit.click()
    except ElementClickInterceptedException:
        driver.execute_script("arguments[0].click();", submit)

    try:
        WebDriverWait(driver, 20).until(
            lambda d: "login" not in d.current_url.lower()
                      or len(d.find_elements(By.CSS_SELECTOR, "input[type='password']")) == 0
                      or bool(d.execute_script("try { var t = JSON.parse(localStorage.getItem('token')||'{}'); return !!(t.value || t.access_token); } catch(e){ return false; }"))
        )
        log(f"Login confirmed — {driver.current_url}")
        build_api_session(driver)
        return True
    except TimeoutException:
        log(f"Login unconfirmed — {driver.current_url}")
        build_api_session(driver)
        return False


# ── Popup dismissal ───────────────────────────────────────────────────────────

def dismiss_popups(driver, attempts: int = 5):
    close_selectors = [
        (By.CSS_SELECTOR,  "button[aria-label*='Close' i]"),
        (By.CSS_SELECTOR,  "button[title*='Close' i]"),
        (By.CSS_SELECTOR,  "[role='button'][aria-label*='Close' i]"),
        (By.XPATH, "//button[contains(translate(normalize-space(.),'CLOSE','close'),'close')]"),
        (By.XPATH, "//*[self::button or @role='button'][normalize-space(.)='X' or normalize-space(.)='×']"),
        (By.XPATH, "//*[contains(@class,'close') and (self::button or self::div or self::span)]"),
        (By.XPATH, "//*[contains(@class,'cancel') and (self::button or self::div or self::span)]"),
    ]
    for attempt in range(attempts):
        clicked = False
        for by, value in close_selectors:
            try:
                for el in driver.find_elements(by, value):
                    try:
                        if not safe_is_displayed(el) or not safe_is_enabled(el):
                            continue
                        driver.execute_script("arguments[0].click();", el)
                        log(f"Closed popup (attempt {attempt + 1})")
                        clicked = True
                        time.sleep(POPUP_PAUSE)
                        break
                    except Exception:
                        continue
            except Exception:
                continue
            if clicked:
                break
        if not clicked:
            time.sleep(POPUP_PAUSE)


# ── Core buy flow (one round) ─────────────────────────────────────────────────

def run_one_buy_round(driver):
    """
    Navigate to OTP-UPI → Small, then use fast HTTP API loop to win a slot.
    Falls back to Selenium clicking if API session is unavailable.
    """
    log("--- Starting new Buy ARB round ---")
    reset_buylist_debug()
    if hasattr(api_fast_buy_loop, "_seen_codes"):
        api_fast_buy_loop._seen_codes.clear()
    click_by_text(driver, ["Buy ARB", "Buy Arb"], "Buy ARB button", timeout=8.0)
    time.sleep(0.1)
    click_by_text(driver, ["OTP-UPI", "OTP UPI", "Otp-Upi", "Otp Upi"], "OTP UPI option", timeout=8.0)
    time.sleep(0.05)
    click_by_text(driver, ["Small"], "Small tab", timeout=5.0)
    time.sleep(0.3)

    # ── Fast API path ──────────────────────────────────────────────────────
    if _api_driver:
        log("Using FAST API mode — browser fetch() (buyList → beforeBuy → buy)")
        mr_order, amount = api_fast_buy_loop(amount_min=1700, amount_max=2000, driver=driver)
        if mr_order:
            log(f"Order claimed: {mr_order} for ₹{amount} — refreshing page to show payment popup...")
            driver.refresh()
            time.sleep(2.5)
            # Click whichever button the site shows to open the pending order
            clicked = click_by_text(
                driver,
                ["Complete Purchase", "Complete payment", "Pay Now", "Continue",
                 "Complete", "Proceed", "Go to Payment", "View Order"],
                "payment popup button",
                timeout=6.0,
            )
            if not clicked:
                log(f"[WARN] No popup button found — MR order {mr_order} is active, check site manually.")
            log("QR screen is live — complete your payment!")
            wait_for_payment_completion(driver, timeout=300.0)
            return

    # ── Fallback: Selenium click loop ─────────────────────────────────────
    log("API session unavailable — using Selenium click fallback")
    click_buy_infinite(driver)
    log("QR screen is live — waiting for you to complete payment...")
    wait_for_payment_completion(driver, timeout=300.0)


# ── Repeat loop with user prompt ─────────────────────────────────────────��────

def run_loop(driver):
    """
    Run buy rounds indefinitely, asking the user after each QR/payment
    whether they want to go again.
    """
    round_number = 1
    while True:
        log(f"========== Round {round_number} ==========")
        try:
            run_one_buy_round(driver)
        except TimeoutException as exc:
            log(f"Round {round_number} timed out: {exc}")
        except KeyboardInterrupt:
            log("Interrupted by user — exiting.")
            break

        round_number += 1

        # Ask user
        print("\n" + "=" * 50)
        print("Payment step done (or timed out).")
        print("Do you want to run another Buy round?")
        print("  [Y] Yes — go again")
        print("  [N] No  — exit")
        print("=" * 50)

        while True:
            try:
                answer = input("Your choice (Y/N): ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                answer = "n"
            if answer in {"y", "yes"}:
                log("User chose to go again — starting next round")
                # Dismiss any lingering modals before next round
                dismiss_popups(driver, attempts=3)
                break
            elif answer in {"n", "no", ""}:
                log("User chose to exit — goodbye!")
                return
            else:
                print("Please type Y or N.")


# ── Main ──────────────────────────────────────────────────────────────────────

def get_args():
    parser = argparse.ArgumentParser(description="Log into arbpay.me with Selenium.")
    parser.add_argument("--browser",  choices=["chrome", "edge"], default="chrome")
    parser.add_argument("--headless", action="store_true")
    return parser.parse_args()


def main():
    if not PHONE_NUMBER or not PASSWORD:
        print("ERROR: PHONE_NUMBER and PASSWORD must be set.")
        print("Either export them as environment variables or add them to a .env file.")
        sys.exit(1)

    args   = get_args()
    driver = build_driver(args.browser, args.headless)

    success = login(driver, PHONE_NUMBER, PASSWORD)
    dismiss_popups(driver)

    if success:
        log("Login confirmed — entering buy loop")
    else:
        log("Login unconfirmed — attempting buy loop anyway")

    run_loop(driver)

    if not args.headless:
        log("Browser left open")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
