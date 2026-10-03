"""
ARBPay SmartRangeBuy endless grabber (One-click Grab API)
=========================================================
Reverse-engineered from live site (Oct 2026):
  main-eb88447c.js  ->  useBuyARB.hook-43ce7acc.js  ->  index-32a817ea.js

One-click Grab is NOT buyList/buy anymore. It is:
  POST /ar-wallet/smartRangeBuy/amountRanges  {orderType, pageNo:1, pageSize:100}
  POST /ar-wallet/smartRangeBuy/status        {orderType} (silent)
  POST /ar-wallet/smartRangeBuy/match/start   {maxAmount, minAmount, orderType, buyBankCode, buyerKycId}
  POST /ar-wallet/smartRangeBuy/match/cancel  {orderType}
  POST /ar-wallet/smartRangeBuy/scene/list    {orderType?}
  (legacy) POST /ar-wallet/buyCenter/quickBuyConfirmBuy {amount, payType:"3"}

Site logic in `ba()` (hook):
  for (requestsNum < 20):
    resp = match/start(...)
    if MATCHED -> auto-jump to /order/cashier?platformOrder=buyOrderNo in 6s
    else wait 1000ms and retry
  After 20 -> FAILED, user must click Retry (we automate: loop forever).

This script reproduces that flow but loops rounds endlessly until MATCHED.

Usage:
  python ARBPay_smartgrab.py --min 1700 --max 2000
  python ARBPay_smartgrab.py --min 100 --max 50000 --order-type 1 --bank-code phonepe
  python ARBPay_smartgrab.py --min 1000 --max 2000 --interval 1.0 --browser edge

Auth: same browser-fetch trick as ARBPay_python_script.py (Cloudflare-safe).
Requires PHONE_NUMBER / PASSWORD in .env or env vars.
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).with_name(".env"))
except ImportError:
    pass

import undetected_chromedriver as uc
from selenium import webdriver
from selenium.common.exceptions import ElementClickInterceptedException, TimeoutException
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.edge.options import Options as EdgeOptions
from selenium.webdriver.edge.service import Service as EdgeService
from selenium.webdriver.support.ui import WebDriverWait


URL = "https://arbpay.me"
API_URLS = [
    "https://apiweb.payapiar.com",
    "https://apiweb.apiarbpay.com",
    "https://apiweb.asjoby.com",
    "https://apiweb.arbpay.me",
]
API_URL = API_URLS[0]
PHONE_NUMBER = os.environ.get("PHONE_NUMBER", "")
PASSWORD = os.environ.get("PASSWORD", "")

LOGIN_SETTLE = 0.5
INPUT_SETTLE = 0.05
POPUP_PAUSE = 0.1

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def log(message: str):
    try:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {message}", flush=True)
    except UnicodeEncodeError:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] "
              f"{message.encode('ascii', 'replace').decode()}", flush=True)


def build_driver(browser: str, headless: bool):
    log(f"Starting {browser} browser")
    common_args = [
        "--start-maximized", "--no-sandbox", "--disable-gpu",
        "--disable-dev-shm-usage", "--disable-notifications", "--disable-popup-blocking",
    ]
    if browser == "edge":
        options = EdgeOptions()
        options.add_experimental_option("detach", True)
        if headless:
            options.add_argument("--headless=new")
        for arg in common_args:
            options.add_argument(arg)
        return webdriver.Edge(service=EdgeService(), options=options)
    options = uc.ChromeOptions()
    options.set_capability("goog:loggingPrefs", {"performance": "ALL"})
    if headless:
        options.add_argument("--headless=new")
    for arg in common_args:
        options.add_argument(arg)
    try:
        return uc.Chrome(options=options, use_subprocess=True)
    except Exception as e:
        log(f"[WARN] UC init failed ({e}), falling back to Edge...")
        edge_opts = EdgeOptions()
        if headless:
            edge_opts.add_argument("--headless=new")
        for arg in common_args:
            edge_opts.add_argument(arg)
        return webdriver.Edge(options=edge_opts)


# ── API session (browser XHR, Cloudflare-transparent) ──
_api_driver = None
_api_token = ""
_api_device_code = ""
_api_member_id = ""


def build_api_session(driver):
    global _api_driver, _api_token, _api_device_code, _api_member_id, API_URL
    try:
        ls = driver.execute_script(
            "return Object.entries(window.localStorage)"
            ".reduce((o,[k,v])=>{o[k]=v;return o},{});"
        )
        token = json.loads(ls.get("token", "{}")).get("value", "")
        device_code = json.loads(ls.get("deviceCode", "{}")).get("value", "")
        member_raw = ls.get("memberId", "")
        if member_raw.startswith("{"):
            try:
                member_id = json.loads(member_raw).get("value", "")
            except Exception:
                member_id = member_raw
        else:
            member_id = member_raw
        if not member_id:
            for k, v in ls.items():
                if "member" in k.lower() or "userid" in k.lower():
                    if v and str(v).isdigit():
                        member_id = str(v)
                        break
        rd_raw = ls.get("runtime-domains:PRO")
        if rd_raw:
            try:
                rd = json.loads(rd_raw)
                act_api = rd.get("selections", {}).get("api")
                if act_api and act_api.startswith("http"):
                    API_URL = act_api.rstrip("/")
                    log(f"Dynamic API host: {API_URL}")
            except Exception:
                pass
    except Exception as e:
        log(f"Could not read localStorage: {e}")
        return None
    if not token:
        log("No token in localStorage — cannot build API session")
        return None
    _api_driver = driver
    _api_token = token
    _api_device_code = device_code
    _api_member_id = member_id
    log(f"API session built — token ...{token[-12:]} | memberId: {member_id or '(none)'}")
    return driver


def browser_fetch(path: str, body: dict, page: str = "Arb", silent: bool = False) -> dict:
    global _api_driver, _api_token, _api_device_code, _api_member_id
    if not _api_driver:
        return {}
    js = """
var xhr = new XMLHttpRequest();
xhr.open('POST', arguments[0], false);
xhr.setRequestHeader('Accept', 'application/json, text/plain, */*');
xhr.setRequestHeader('Content-Type', 'application/json');
xhr.setRequestHeader('authorization', 'Bearer ' + arguments[2]);
if (arguments[5]) { xhr.setRequestHeader('memberId', arguments[5]); }
xhr.setRequestHeader('deviceCode', arguments[3]);
xhr.setRequestHeader('deviceId', '');
xhr.setRequestHeader('deviceType', '3');
xhr.setRequestHeader('language', '1');
xhr.setRequestHeader('page', arguments[4]);
try {
  xhr.send(JSON.stringify(arguments[1]));
  return {ok: true, status: xhr.status, text: xhr.responseText};
} catch(e) { return {ok: false, status: 0, text: String(e)}; }
"""
    try:
        result = _api_driver.execute_script(
            js, f"{API_URL}{path}", body, _api_token, _api_device_code, page, _api_member_id
        )
        if not result or not result.get("ok") or result.get("status", 0) not in (200, 201):
            return {}
        return json.loads(result.get("text", "") or "{}")
    except Exception as e:
        if not silent:
            log(f"[DEBUG] browser_fetch {path} exception: {e}")
        return {}


# ── SmartRangeBuy endpoints (confirmed from index-32a817ea.js) ──
def api_smart_ranges(order_type: int = 1) -> dict:
    """POST /ar-wallet/smartRangeBuy/amountRanges — list of selectable ranges + reward extend."""
    return browser_fetch("/ar-wallet/smartRangeBuy/amountRanges",
                         {"orderType": order_type, "pageNo": 1, "pageSize": 100})


def api_smart_status(order_type: int = 1) -> dict:
    """POST /ar-wallet/smartRangeBuy/status — scene LIST/MATCH, existing MATCHED order."""
    return browser_fetch("/ar-wallet/smartRangeBuy/status", {"orderType": order_type}, silent=True)


def api_smart_start(min_amount, max_amount, order_type: int = 1,
                    buy_bank_code: str = "", buyer_kyc_id=0) -> dict:
    """
    POST /ar-wallet/smartRangeBuy/match/start — one matching attempt.
    Site payload (hook `ba`): {maxAmount, minAmount, orderType, buyBankCode, buyerKycId}
    """
    payload = {"maxAmount": max_amount, "minAmount": min_amount, "orderType": order_type}
    if buy_bank_code:
        payload["buyBankCode"] = buy_bank_code
    # hook always sends buyerKycId (may be 0); keep it to match site exactly
    payload["buyerKycId"] = buyer_kyc_id if buyer_kyc_id is not None else 0
    return browser_fetch("/ar-wallet/smartRangeBuy/match/start", payload)


def api_smart_cancel(order_type: int = 1) -> dict:
    return browser_fetch("/ar-wallet/smartRangeBuy/match/cancel", {"orderType": order_type})


def api_fetch_banks():
    """Return list of (bankCode, kycId, bankName) from bound/all banks."""
    resp = browser_fetch("/ar-wallet/kycCenter/getBanks/bankListAndBoundListForQuick", {"type": "1"})
    out = []
    try:
        data = resp.get("data") or {}
        for key in ("boundBanks", "allBanks"):
            lst = data.get(key) or []
            if isinstance(lst, list):
                for b in lst:
                    if not isinstance(b, dict):
                        continue
                    code = str(b.get("bankCode") or b.get("payBankCode") or b.get("channelCode") or "").strip()
                    if not code:
                        continue
                    kid = b.get("id", 0)
                    try:
                        kid = int(kid)
                    except Exception:
                        kid = 0
                    name = str(b.get("bankName") or b.get("upiId") or code)
                    out.append((code, kid, name, key))
    except Exception as e:
        log(f"[WARN] bank parse failed: {e}")
    # de-dup, bound first
    seen = set()
    uniq = []
    for code, kid, name, src in out:
        if code.lower() in seen:
            continue
        seen.add(code.lower())
        uniq.append((code, kid, name))
    return uniq


def parse_match_start(resp: dict):
    """Return (code, matchResult, buyResult dict, matchInfo dict, msg)."""
    if not resp:
        return "", "", {}, {}, "empty response"
    code = str(resp.get("code", ""))
    msg = str(resp.get("msg", "") or resp.get("message", ""))
    data = resp.get("data") or {}
    if not isinstance(data, dict):
        return code, "", {}, {}, msg
    match_result = str(data.get("matchResult", "") or data.get("matchresult", ""))
    buy_result = data.get("buyResult") or data.get("buyresult") or {}
    match_info = data.get("matchInfo") or data.get("matchinfo") or {}
    if not isinstance(buy_result, dict):
        buy_result = {}
    if not isinstance(match_info, dict):
        match_info = {}
    return code, match_result, buy_result, match_info, msg


BANK_CODES_FALLBACK = [
    "supermoney", "phonepe", "paytm", "gpay", "mobikwik", "freeCharge", "airtel",
    "jio", "freo", "slice", "twid", "pop", "navi", "moneyView", "induspay",
]


def smart_endless_loop(min_amount, max_amount, order_type: int = 1,
                       bank_code: str = "", interval: float = 1.0, driver=None):
    """
    Endless One-click Grab:
      outer round loop (infinite) -> inner 20x match/start @ ~1s (site limit)
      on FAILED after 20 -> immediately start next round (site requires manual Retry; we automate)
    Returns (buyOrderNo, amount) on MATCHED.
    """
    log(f"SmartGrab endless started: range {min_amount}-{max_amount} orderType={order_type} "
        f"bank={bank_code or '(auto-cycle)'} interval={interval}s")

    # 0) Show available site ranges once (helps user pick valid range)
    try:
        r = api_smart_ranges(order_type)
        if str(r.get("code")) == "1":
            lst = (r.get("data") or {}).get("list") or []
            ext = (r.get("data") or {}).get("extend") or {}
            log(f"Site ranges ({len(lst)}): " +
                ", ".join(f"{x.get('minimumAmount')}-{x.get('maximumAmount')}" for x in lst[:8]))
            if ext:
                log(f"Site reward extend: min={ext.get('minRewardAmount')} max={ext.get('maxRewardAmount')}")
        else:
            log(f"[DEBUG] amountRanges code={r.get('code')} msg={r.get('msg')}")
    except Exception as e:
        log(f"[WARN] amountRanges failed: {e}")

    # 1) Resolve bank cycle: prefer bound banks with real kycId
    bank_cycle = []
    try:
        banks = api_fetch_banks()
        if banks:
            log(f"Banks ({len(banks)}): " + ", ".join(f"{c}(id={i})" for c, i, _ in banks[:10]))
            bank_cycle = [(c, i) for c, i, _ in banks]
    except Exception as e:
        log(f"[WARN] bank fetch failed: {e}")
    if bank_code:
        # pin to requested bank; look up its kycId if known else 0
        kid = 0
        for c, i in bank_cycle:
            if c.lower() == bank_code.lower():
                kid = i
                break
        bank_cycle = [(bank_code, kid)]
    if not bank_cycle:
        bank_cycle = [(c, 0) for c in BANK_CODES_FALLBACK]
        log(f"Using fallback bank cycle ({len(bank_cycle)} codes, kycId=0)")

    # 2) Resume check: already MATCHED?
    try:
        st = api_smart_status(order_type)
        if str(st.get("code")) == "1":
            d = st.get("data") or {}
            if d.get("scene") == "MATCH" and str(d.get("status", "")).upper() == "COMPLETED":
                pass
            # buyResult may already hold a matched order after refresh
            br = d.get("buyResult") or {}
            if isinstance(br, dict) and br.get("buyOrderNo"):
                log(f"Resumed existing MATCHED order from status: {br.get('buyOrderNo')}")
                return br.get("buyOrderNo"), int(float(br.get("amount", 0) or 0))
    except Exception:
        pass

    total_requests = 0
    round_no = 0
    bank_idx = 0
    seen_codes = set()

    while True:
        round_no += 1
        cur_bank, cur_kid = bank_cycle[bank_idx % len(bank_cycle)]
        log(f"-- Round {round_no}: match/start x20 in {min_amount}-{max_amount} "
            f"[bank={cur_bank} kycId={cur_kid}] --")

        for attempt_in_round in range(1, 21):
            total_requests += 1
            n = attempt_in_round  # site UI shows (n/20)
            resp = api_smart_start(min_amount, max_amount, order_type, cur_bank, cur_kid)
            code, match_result, buy_result, match_info, msg = parse_match_start(resp)

            if code and code not in seen_codes:
                seen_codes.add(code)
                log(f"[DEBUG] first code={code} msg={msg!r} matchResult={match_result!r} "
                    f"raw={json.dumps(resp)[:250]}")
            if match_result and f"{code}:{match_result}" not in seen_codes:
                seen_codes.add(f"{code}:{match_result}")
                log(f"[DEBUG] matchResult={match_result} (code={code})")

            if not resp:
                log(f"[{total_requests}] (req {n}/20) empty response — session hiccup, retrying...")
                time.sleep(interval)
                if total_requests % 25 == 0 and driver:
                    log("[WARN] many empty responses — rebuilding API session")
                    build_api_session(driver)
                continue

            # Unfinished order present (site: pendingOrder) — go pay it
            if code == "1027":
                data = resp.get("data") or {}
                pend = data.get("pendingOrder") or data
                order_no = ""
                if isinstance(pend, dict):
                    order_no = str(pend.get("buyOrderNo") or pend.get("platformOrder") or "")
                if order_no:
                    log(f"MATCHED via unfinished order (1027): {order_no} — proceeding to payment")
                    return order_no, int(min_amount)
                log(f"Code 1027 but no order found: {json.dumps(resp)[:250]} — continuing")
                time.sleep(interval)
                continue

            if code == "1205":
                log(f"[{total_requests}] smartGrab unavailable (1205): {msg} — waiting 5s then new round")
                time.sleep(5.0)
                break  # break inner -> next outer round (retry)

            if code != "1":
                log(f"[{total_requests}] (req {n}/20) code={code} msg={msg!r} — restarting round in 2s")
                time.sleep(2.0)
                break

            # code == 1: inspect matchResult
            mr_upper = (match_result or "").upper()
            if mr_upper == "MATCHED":
                buy_no = str(buy_result.get("buyOrderNo") or "")
                amt = buy_result.get("amount", 0)
                try:
                    amt = int(float(amt))
                except Exception:
                    amt = int(min_amount)
                reward = buy_result.get("rewardAmount", 0)
                pay_time = (match_info.get("payTime") or buy_result.get("payTime") or 0)
                log(f"MATCHED after {total_requests} total requests "
                    f"(round {round_no} req {n}/20): order={buy_no} amount={amt} "
                    f"reward={reward} payTime={pay_time}s")
                return buy_no, amt

            # NOT matched yet — MATCHING / FAILED / empty → keep going within 20
            if n < 20:
                if n == 1 or n % 5 == 0:
                    log(f"[{total_requests}] searching {min_amount}-{max_amount} ({n}/20) "
                        f"matchResult={match_result or 'MATCHING'} ...")
                time.sleep(interval)
                continue
            # n == 20 reached without match -> outer loop retries (site shows FAILED + Retry)
            log(f"Round {round_no} exhausted 20/20 with no match - auto-retrying (endless)...")
            break

        # rotate bank each outer round so a dead bank doesn't stall us forever
        bank_idx += 1
        time.sleep(0.2)


# ── login + navigation helpers (minimal, copied pattern from main script) ──
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


def safe_get_attr(el, attr):
    try:
        return el.get_attribute(attr) or ""
    except Exception:
        return ""


def visible_enabled_inputs(driver):
    try:
        return [e for e in driver.find_elements(By.TAG_NAME, "input")
                if safe_is_displayed(e) and safe_is_enabled(e)]
    except Exception:
        return []


def wait_for_login_form(driver, timeout: float = 30.0):
    deadline = time.time() + timeout
    log("Waiting for login form...")
    while time.time() < deadline:
        try:
            inputs = visible_enabled_inputs(driver)
            if any((safe_get_attr(el, "type") or "").lower() == "password" for el in inputs):
                phone = pwd = None
                for el in inputs:
                    t = (safe_get_attr(el, "type") or "text").lower()
                    combo = " ".join([t, safe_get_attr(el, "placeholder").lower(),
                                      safe_get_attr(el, "name").lower(), safe_get_attr(el, "id").lower()])
                    if pwd is None and t == "password":
                        pwd = el
                    if phone is None and any(k in combo for k in ["tel", "phone", "mobile", "username", "number"]):
                        phone = el
                if phone is None:
                    for el in inputs:
                        if (safe_get_attr(el, "type") or "text").lower() in {"text", "tel", "number", "search", ""}:
                            phone = el
                            break
                if phone is not None and pwd is not None:
                    return phone, pwd
        except Exception:
            pass
        time.sleep(0.5)
    raise TimeoutException("login inputs not found")


def set_input(driver, el, value, name):
    driver.execute_script(
        """const el=arguments[0],v=arguments[1];el.scrollIntoView({block:'center'});el.focus();
const p=Object.getPrototypeOf(el),d=Object.getOwnPropertyDescriptor(p,'value');
d.set.call(el,v);el.dispatchEvent(new Event('input',{bubbles:true}));
el.dispatchEvent(new Event('change',{bubbles:true}));""", el, value)
    if safe_get_attr(el, "value") != value:
        el.click()
        el.send_keys(Keys.CONTROL, "a")
        el.send_keys(Keys.DELETE)
        el.send_keys(value)


def login(driver, phone, password):
    log(f"Opening {URL}")
    driver.get(URL)
    time.sleep(LOGIN_SETTLE)
    phone_in, pwd_in = wait_for_login_form(driver)
    set_input(driver, phone_in, phone, "phone")
    time.sleep(INPUT_SETTLE)
    set_input(driver, pwd_in, password, "password")
    time.sleep(INPUT_SETTLE)
    # submit: first button with Log In text else submit
    btn = None
    for b in driver.find_elements(By.TAG_NAME, "button"):
        try:
            if (b.text or "").strip().lower() == "log in" and safe_is_displayed(b):
                btn = b
                break
        except Exception:
            continue
    if btn is None:
        btn = driver.find_element(By.CSS_SELECTOR, "button[type='submit']")
    try:
        btn.click()
    except Exception:
        driver.execute_script("arguments[0].click();", btn)
    try:
        WebDriverWait(driver, 20).until(
            lambda d: "login" not in d.current_url.lower()
            or len(d.find_elements(By.CSS_SELECTOR, "input[type='password']")) == 0
            or bool(d.execute_script(
                "try{var t=JSON.parse(localStorage.getItem('token')||'{}');"
                "return !!(t.value||t.access_token);}catch(e){return false;}")))
        log(f"Login confirmed — {driver.current_url}")
        build_api_session(driver)
        return True
    except TimeoutException:
        log(f"Login unconfirmed — {driver.current_url}")
        build_api_session(driver)
        return False


def wait_for_payment(driver, timeout: float = 300.0):
    log("Waiting for payment success screen (5 min)...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            txt = (driver.find_element(By.TAG_NAME, "body").text or "").lower()
            if any(k in txt for k in ["payment successful", "payment completed", "order confirmed",
                                      "transaction successful", "purchase successful",
                                      "order placed", "thank you", "payment received"]):
                log("Payment success detected!")
                return True
        except Exception:
            pass
        time.sleep(1.0)
    log("Payment wait timed out")
    return False


def get_args():
    p = argparse.ArgumentParser(description="ARBPay endless One-click Grab (smartRangeBuy)")
    p.add_argument("--min", type=int, required=True, help="range minAmount, e.g. 1700")
    p.add_argument("--max", type=int, required=True, help="range maxAmount, e.g. 2000")
    p.add_argument("--order-type", type=int, default=1, choices=[0, 1, 2],
                   help="smartRangeBuy orderType (1=OTP/UPI default, 2=Bank, 0=other tab)")
    p.add_argument("--bank-code", default="", help="pin bank, e.g. phonepe (default: auto-cycle bound banks)")
    p.add_argument("--interval", type=float, default=1.0, help="seconds between match/start calls (site uses 1.0)")
    p.add_argument("--browser", choices=["chrome", "edge"], default="chrome")
    p.add_argument("--headless", action="store_true")
    return p.parse_args()


def main():
    if not PHONE_NUMBER or not PASSWORD:
        print("ERROR: set PHONE_NUMBER and PASSWORD in .env")
        sys.exit(1)
    args = get_args()
    if args.min > args.max:
        print("ERROR: --min must be <= --max")
        sys.exit(1)
    driver = build_driver(args.browser, args.headless)
    ok = login(driver, PHONE_NUMBER, PASSWORD)
    log("Login confirmed — entering endless smart grab" if ok else "Login unconfirmed — trying anyway")
    buy_no, amt = smart_endless_loop(args.min, args.max, args.order_type,
                                     args.bank_code, args.interval, driver=driver)
    log(f"Order claimed: {buy_no} ₹{amt} — opening cashier...")
    try:
        driver.get(f"{URL}/#/order/cashier?platformOrder={buy_no}")
    except Exception:
        driver.refresh()
    time.sleep(2.5)
    log("Cashier open — complete payment now!")
    wait_for_payment(driver, 300.0)
    log("Done. Browser left open.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
