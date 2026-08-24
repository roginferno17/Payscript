"""
ARBPay API Logger
=================
Intercepts and live-logs every API call made in the Selenium browser session.
Uses Chrome DevTools Protocol (CDP) Network events to capture all requests
and responses in real time — no code changes to the main script needed.

Usage:
    python api_logger.py [--browser chrome|edge] [--headless] [--filter arbpay]

Output:
    Prints timestamped logs to console + saves to api_logs_<date>.txt
"""

import argparse
import json
import os
import sys
import time
import threading
from datetime import datetime
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).with_name(".env"))
except ImportError:
    pass

import undetected_chromedriver as uc
from selenium import webdriver
from selenium.webdriver.chrome.options import Options as ChromeOptions
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.edge.options import Options as EdgeOptions
from selenium.webdriver.edge.service import Service as EdgeService

# ── Config ────────────────────────────────────────────────────────────────────
URL         = "https://arbpay.me"
API_URL     = "https://apiweb.arbpay.me"
LOG_FILE    = f"api_logs_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"

# Colours for terminal output
RESET  = "\033[0m"
BOLD   = "\033[1m"
CYAN   = "\033[96m"
GREEN  = "\033[92m"
YELLOW = "\033[93m"
RED    = "\033[91m"
GREY   = "\033[90m"
BLUE   = "\033[94m"
MAGENTA= "\033[95m"

# ── Logging ───────────────────────────────────────────────────────────────────
_log_lock = threading.Lock()
_log_file = open(LOG_FILE, "w", encoding="utf-8")

def log(msg: str, color: str = RESET, prefix: str = ""):
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    line = f"[{ts}] {prefix}{msg}"
    with _log_lock:
        print(f"{color}{line}{RESET}", flush=True)
        _log_file.write(line + "\n")
        _log_file.flush()

def log_separator(title: str = ""):
    sep = "─" * 60
    if title:
        log(f"┌{sep}┐", GREY)
        log(f"│  {title:<58}│", BOLD)
        log(f"└{sep}┘", GREY)
    else:
        log(sep, GREY)

# ── Request/Response store ────────────────────────────────────────────────────
# Maps requestId → { url, method, headers, postData, timestamp }
_pending_requests: dict = {}
_request_lock = threading.Lock()

def _on_request(params: dict):
    """Called when a network request is about to be sent."""
    req_id  = params.get("requestId", "")
    request = params.get("request", {})
    url     = request.get("url", "")
    method  = request.get("method", "GET")
    headers = request.get("headers", {})
    body    = request.get("postData", "")

    with _request_lock:
        _pending_requests[req_id] = {
            "url":       url,
            "method":    method,
            "headers":   headers,
            "body":      body,
            "timestamp": datetime.now(),
        }

    # Only log API calls (filter noise)
    if _should_log(url):
        path = url.replace(API_URL, "").replace(URL, "") or url
        log(f"→ {method} {path}", CYAN, "REQ  ")
        if body:
            try:
                parsed = json.loads(body)
                log(f"   Body: {json.dumps(parsed, ensure_ascii=False)}", BLUE)
            except Exception:
                log(f"   Body: {body[:300]}", BLUE)
        _log_headers(headers, "   ")

def _on_response(params: dict):
    """Called when a response header is received."""
    req_id   = params.get("requestId", "")
    response = params.get("response", {})
    url      = response.get("url", "")
    status   = response.get("status", 0)
    mime     = response.get("mimeType", "")

    if not _should_log(url):
        return

    path = url.replace(API_URL, "").replace(URL, "") or url
    color = GREEN if 200 <= status < 300 else (YELLOW if status < 500 else RED)
    log(f"← {status} {path} [{mime}]", color, "RES  ")

    # Store status for body fetch
    with _request_lock:
        if req_id in _pending_requests:
            _pending_requests[req_id]["status"] = status

def _on_loading_finished(driver, params: dict):
    """Called when response body is fully loaded — fetch and log it."""
    req_id = params.get("requestId", "")

    with _request_lock:
        req_info = _pending_requests.pop(req_id, None)

    if not req_info:
        return

    url = req_info.get("url", "")
    if not _should_log(url):
        return

    # Fetch response body via CDP
    try:
        result = driver.execute_cdp_cmd(
            "Network.getResponseBody", {"requestId": req_id}
        )
        body = result.get("body", "")
        if result.get("base64Encoded"):
            import base64
            body = base64.b64decode(body).decode("utf-8", errors="replace")
    except Exception:
        body = ""

    if not body:
        return

    path     = url.replace(API_URL, "").replace(URL, "") or url
    duration = (datetime.now() - req_info["timestamp"]).total_seconds() * 1000

    log(f"   Response body for {path} ({duration:.0f}ms):", GREY)
    try:
        parsed = json.loads(body)
        pretty = json.dumps(parsed, indent=2, ensure_ascii=False)
        # Truncate very long responses
        if len(pretty) > 2000:
            pretty = pretty[:2000] + "\n  ... [truncated]"
        for line in pretty.splitlines():
            log(f"   {line}", _response_color(parsed))
    except Exception:
        preview = body[:500] + ("..." if len(body) > 500 else "")
        log(f"   {preview}", GREY)

    log_separator()

def _on_loading_failed(params: dict):
    """Called when a request fails."""
    req_id = params.get("requestId", "")
    url    = params.get("request", {}).get("url", "")

    with _request_lock:
        req_info = _pending_requests.pop(req_id, None)

    if req_info:
        url = req_info.get("url", url)

    if _should_log(url):
        error = params.get("errorText", "unknown error")
        path  = url.replace(API_URL, "").replace(URL, "") or url
        log(f"✗ FAILED {path} — {error}", RED, "ERR  ")
        log_separator()

# ── Helpers ───────────────────────────────────────────────────────────────────
_url_filter: str = ""

KNOWN_API_DOMAINS = [
    "apiweb.arbpay.me",
    "apiweb.apiarbpay.com",
    "apiweb.payapiar.com",
    "apiweb.asjoby.com",
]

KNOWN_FRONTEND_DOMAINS = [
    "arbpay.me",
    "arbpay.co",
    "payzuva.com",
    "paykexo.com",
    "paykuno.com",
    "payvuno.com",
    "paywivo.com",
    "payjora.com",
    "payduno.com",
]

def _should_log(url: str) -> bool:
    """Return True if this URL should be logged."""
    if not url:
        return False
    # Always log API calls
    if any(domain in url for domain in KNOWN_API_DOMAINS) or "/ar-" in url:
        return True
    # Log page navigations on known mirror domains
    if any(domain in url for domain in KNOWN_FRONTEND_DOMAINS) and not any(
        ext in url for ext in [".js", ".css", ".png", ".jpg", ".ico", ".woff", ".svg", ".ttf"]
    ):
        return True
    # Custom filter
    if _url_filter and _url_filter.lower() in url.lower():
        return True
    return False

def _response_color(parsed: dict) -> str:
    code = str(parsed.get("code", ""))
    if code in ("200", "0", "1", "00", "success", "SUCCESS"):
        return GREEN
    if code in ("2005", "1191", "1194", "1027"):
        return YELLOW
    if code:
        return RED
    return GREY

def _log_headers(headers: dict, indent: str = ""):
    """Log interesting headers only."""
    interesting = ["authorization", "content-type", "devicecode", "devicetype", "page"]
    for k, v in headers.items():
        if k.lower() in interesting:
            # Truncate auth token for readability
            if k.lower() == "authorization" and len(v) > 40:
                v = v[:20] + "..." + v[-12:]
            log(f"{indent}{k}: {v}", GREY)

# ── CDP event listener thread ─────────────────────────────────────────────────
def _start_cdp_listener(driver):
    """Enable CDP Network domain and wire up event handlers."""
    driver.execute_cdp_cmd("Network.enable", {})
    log("CDP Network monitoring enabled", GREEN)

    # Selenium 4 supports CDP event listeners via add_cdp_listener
    driver.add_cdp_listener("Network.requestWillBeSent",
                             lambda e: _on_request(e))
    driver.add_cdp_listener("Network.responseReceived",
                             lambda e: _on_response(e))
    driver.add_cdp_listener("Network.loadingFinished",
                             lambda e: _on_loading_finished(driver, e))
    driver.add_cdp_listener("Network.loadingFailed",
                             lambda e: _on_loading_failed(e))

# ── Driver setup ──────────────────────────────────────────────────────────────
def build_driver(browser: str = "chrome", headless: bool = False):
    common_args = [
        "--start-maximized",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--disable-notifications",
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
    options.add_argument("--log-level=3")
    if headless:
        options.add_argument("--headless=new")
    for arg in common_args:
        options.add_argument(arg)

    try:
        return uc.Chrome(options=options, use_subprocess=True)
    except Exception as e:
        log(f"[WARN] Standard UC init failed ({e}), trying version_main=151...")
        try:
            return uc.Chrome(options=options, version_main=151, use_subprocess=True)
        except Exception as e2:
            log(f"[WARN] Version 151 failed ({e2}), falling back to Edge...")
            edge_opts = EdgeOptions()
            edge_opts.set_capability("goog:loggingPrefs", {"performance": "ALL"})
            if headless:
                edge_opts.add_argument("--headless=new")
            for arg in common_args:
                edge_opts.add_argument(arg)
            return webdriver.Edge(options=edge_opts)

# ── Performance log fallback (for Edge / older Chrome) ───────────────────────
def _poll_performance_logs(driver, stop_event: threading.Event):
    """
    Fallback: poll Chrome performance logs every 500ms.
    Used when CDP listeners aren't available.
    """
    seen_ids = set()
    while not stop_event.is_set():
        try:
            logs = driver.get_log("performance")
            for entry in logs:
                try:
                    msg  = json.loads(entry["message"])["message"]
                    method = msg.get("method", "")
                    params = msg.get("params", {})

                    if method == "Network.requestWillBeSent":
                        req_id = params.get("requestId", "")
                        if req_id not in seen_ids:
                            seen_ids.add(req_id)
                            _on_request(params)

                    elif method == "Network.responseReceived":
                        _on_response(params)

                    elif method == "Network.loadingFinished":
                        _on_loading_finished(driver, params)

                    elif method == "Network.loadingFailed":
                        _on_loading_failed(params)

                except Exception:
                    continue
        except Exception:
            pass
        time.sleep(0.3)

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    global _url_filter

    parser = argparse.ArgumentParser(description="ARBPay API Logger")
    parser.add_argument("--browser",  default="chrome", choices=["chrome", "edge"])
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--filter",   default="", help="Extra URL substring to log (e.g. 'arbpay')")
    args = parser.parse_args()

    _url_filter = args.filter

    log_separator("ARBPay API Logger")
    log(f"Browser  : {args.browser}", CYAN)
    log(f"Log file : {LOG_FILE}", CYAN)
    log(f"Filter   : {_url_filter or '(API calls only)'}", CYAN)
    log_separator()

    driver = build_driver(args.browser, args.headless)
    log(f"Browser started", GREEN)

    # Enable CDP Network domain so response bodies are available
    try:
        driver.execute_cdp_cmd("Network.enable", {})
        log("CDP Network domain enabled", GREEN)
    except Exception as e:
        log(f"CDP Network.enable failed: {e}", YELLOW)

    # Use performance log polling (works reliably with undetected_chromedriver)
    log("Using performance log polling for network capture", GREEN)

    # Start fallback poller
    stop_event = threading.Event()
    poll_thread = threading.Thread(
        target=_poll_performance_logs,
        args=(driver, stop_event),
        daemon=True,
    )
    poll_thread.start()
    log("Performance log poller started", GREEN)

    # Navigate to ARBPay
    log(f"Opening {URL}", CYAN)
    driver.get(URL)
    log("Browser ready — use it normally. All API calls will be logged here.", GREEN)
    log("Press Ctrl+C to stop logging and close.", YELLOW)
    log_separator()

    try:
        while True:
            time.sleep(1)
            # Keep CDP alive by checking if browser is still open
            try:
                _ = driver.current_url
            except Exception:
                log("Browser closed — stopping logger", YELLOW)
                break
    except KeyboardInterrupt:
        log("\nStopped by user", YELLOW)
    finally:
        stop_event.set()
        try:
            driver.quit()
        except Exception:
            pass
        _log_file.close()
        log(f"Logs saved to {LOG_FILE}", GREEN)

if __name__ == "__main__":
    main()
