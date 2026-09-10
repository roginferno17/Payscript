# ARBPay Bot - Android APK

A Flutter Android app that automates ARBPay token buying with a clean dark UI.

## Features
- 🌑 Dark finance-style UI (black + green)
- 🔄 Real-time animated status (pulsing dot)
- 📋 Color-coded live log (green=success, yellow=warning, red=error)
- ⚙️ Settings screen (phone, password, amount range)
- 🛡️ Cloudflare bypass via real Android WebView
- 🏦 Auto bank cycling (Supermoney → Paytm → PhonePe → GPay → etc.)
- 📱 QR payment screen shown in-app when order claimed

## UI Preview

```
┌─────────────────────────────┐
│  [A] ARBPay Bot             ⚙│
│      Auto Buy Engine         │
├─────────────────────────────┤
│  ● RUNNING          Rounds:3 │
│    Order: MR123...  Wins:  2 │
├─────────────────────────────┤
│  ₹ Range: ₹1700-₹2000       │
│  🔄 Attempts: 247            │
├─────────────────────────────┤
│ [LIVE LOG]              CLEAR│
│ 17:42:01 ✓ BUY SUCCESS!     │
│ 17:42:00 ✓ Session built    │
│ 17:41:58 ⚠ CF challenge...  │
│ 17:41:55 ℹ Starting bot...  │
├─────────────────────────────┤
│      ▶  START BOT            │
└─────────────────────────────┘
```

## How to Build the APK

### Option 1: Flutter SDK (recommended)

1. Install Flutter: https://docs.flutter.dev/get-started/install
2. Install Android Studio + Android SDK
3. Open terminal in this folder:

```bash
flutter pub get
flutter build apk --release
```

APK will be at: `build/app/outputs/flutter-apk/app-release.apk`

For a debug APK (faster, no signing needed):
```bash
flutter build apk --debug
```

### Option 2: Online Build Service (no local install needed)

Use **Codemagic** (free tier):
1. Push this folder to a GitHub repo
2. Go to https://codemagic.io
3. Connect your repo → select Flutter → build Android APK
4. Download APK from build artifacts

### Option 3: Gitpod / GitHub Codespaces

Open in Gitpod: `gitpod.io/#https://github.com/YOUR_REPO`
Then run `flutter build apk --release`

## local.properties (needed for build)

Create `android/local.properties`:
```
flutter.sdk=/path/to/flutter
flutter.buildMode=release
flutter.versionName=1.0.0
flutter.versionCode=1
sdk.dir=/path/to/android/sdk
```

## How the App Works

1. Tap **START BOT**
2. WebView loads `https://arbpay.me` in the background
3. App waits for Cloudflare challenge to auto-clear (real browser = passes automatically)
4. Fills login form via JavaScript injection
5. Extracts auth token from `localStorage`
6. Polls `/ar-wallet/buyCenter/buyList` via synchronous XHR inside WebView
7. When order found in range → calls `/ar-wallet/buyCenter/buy`
8. On success → shows QR payment screen in-app

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Phone | (set in app) | Login phone number |
| Password | (set in app) | Login password |
| Amount Min | ₹1700 | Minimum order amount |
| Amount Max | ₹2000 | Maximum order amount |
