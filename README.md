# ARBPay Bot

Automated buying bot and companion Android app for the [ARBPay](https://arbpay.me) platform. Captures auth tokens from a live browser session and runs a high-speed buy loop against the ARBPay API — bypassing Cloudflare via `undetected-chromedriver`.

---

## Repository Structure

```
arb-pay-script/
├── ARBPay_python_script.py          # Primary Python bot (Chrome/Edge)
├── ARBPay_python_script_for_apk.py  # Variant for APK-integrated flows
├── api_logger.py                    # Live API call logger (Selenium + CDP)
├── requirements.txt                 # Pinned Python dependencies
├── .env                             # Credentials (gitignored)
└── arbpay_apk/                      # Flutter Android app
    └── lib/
        ├── main.dart
        ├── models/app_state.dart
        ├── screens/home_screen.dart
        ├── screens/settings_screen.dart
        └── services/arbpay_service.dart
```

---

## 1. Python Bot Scripts

### Setup

```bash
# Create and activate virtual environment
python -m venv venv
venv\Scripts\activate        # Windows
source venv/bin/activate     # macOS/Linux

# Install dependencies
pip install -r requirements.txt
```

### `.env` file

```env
PHONE_NUMBER=your_phone
PASSWORD=your_password
```

### Running

```bash
# Primary bot
python ARBPay_python_script.py

# With options
python ARBPay_python_script.py --browser edge --headless
```

### How it works

1. Launches Chrome (via `undetected-chromedriver`) to bypass Cloudflare bot detection
2. Auto-fills login credentials and waits for session to establish
3. Extracts `token` and `deviceCode` from `localStorage`
4. Runs a tight loop: `buyList` → `buy` via in-browser `XMLHttpRequest`
5. Cycles through UPI bank codes on rejection (`code 2005`)
6. On success, reloads the page to show the QR payment screen

### Key Features

- **Cloudflare bypass** — uses `undetected-chromedriver` to avoid bot detection
- **Browser-fetch injection** — all API calls run inside Chrome via `XMLHttpRequest`, inheriting the session cookies and bypassing CORS
- **Bank cycling** — automatically tries `phonepe → paytm → gpay → mobikwik → ...` on rejection
- **Session recovery** — rebuilds token on consecutive failures
- **Headless mode** — run fully in the background with `--headless`

---

## 2. API Logger

Live-logs every network request/response made in the Selenium browser session. Useful for reverse-engineering API flows.

```bash
python api_logger.py
python api_logger.py --browser edge
python api_logger.py --filter wallet   # only log URLs containing "wallet"
```

Output is color-coded in the terminal and saved to `api_logs_<timestamp>.txt`.

---

## 3. Flutter Android App (`arbpay_apk`)

A native Android app that wraps the same bot logic with a clean UI.

### Latest Release

Download the latest APK from [GitHub Releases](https://github.com/roginferno17/Payscript/releases/latest).

### Features

| Feature | Description |
|---|---|
| **Payment Mode Toggle** | Switch between OTP/UPI (`payType=3`) and Bank (`payType=1`) from Settings |
| **Built-in WebView** | Logs into ARBPay inside the app, captures token from `localStorage` |
| **Live Log Panel** | Real-time scrollable console with color-coded log levels |
| **Status Dashboard** | Shows bot state, attempt count, round count, and win count |
| **Amount Range** | Configurable min/max buy amount, persisted across sessions |
| **Auto-fill Login** | Fills phone/password into the WebView login form automatically |

### Payment Modes

| Mode | `payType` | `orderType` | Use when |
|---|---|---|---|
| OTP / UPI | `3` | `1` | Buying UPI orders (PhonePe, GPay, etc.) |
| Bank | `1` | `2` | Buying bank transfer orders |

Switch in **Settings → Payment Mode** and tap **SAVE**.

### Building from Source

```bash
cd arbpay_apk
flutter pub get
flutter build apk --release
```

> When releasing a new build, bump the version in `pubspec.yaml` and `lib/screens/home_screen.dart`.

### Installing on Device

1. Download `ARBPay-Bot-vX.X.X.apk` from [Releases](https://github.com/roginferno17/Payscript/releases)
2. Enable **Install from unknown sources** on your Android device
3. Install and open the app
4. Go to **Settings**, enter your phone/password and configure amount range
5. Tap **Capture Token**, log in via the WebView
6. Once on the home page, tap **Complete Capture & Run**

---

## API Reference (Confirmed from Network Logs)

| Endpoint | Method | Purpose |
|---|---|---|
| `/ar-auth/oauth/token` | POST | Login, returns `access_token` |
| `/ar-wallet/buyCenter/buyList` | POST | Fetch available orders |
| `/ar-wallet/buyCenter/beforeBuy` | POST | Reserve order slot |
| `/ar-wallet/buyCenter/buy` | POST | Place buy order |
| `/ar-wallet/buyCenter/getPaymentPageDataEncryption` | POST | Get QR payment data |
| `/ar-wallet/kycCenter/getBanks/bankListAndBoundListForQuick` | POST | Get available banks |

### Buy request body

**UPI mode:**
```json
{ "amount": 1700, "platformOrder": "C2C...", "payType": "3", "orderType": 1, "buyBankCode": "phonepe", "buyerKycId": 0 }
```

**Bank mode:**
```json
{ "amount": 1700, "platformOrder": "C2C...", "payType": "1", "orderType": 2, "buyBankCode": "phonepe", "buyerKycId": 0 }
```

---

## Disclaimer

This project is for educational and personal use only. Automated bots may violate ARBPay's Terms of Service. Use at your own risk.
