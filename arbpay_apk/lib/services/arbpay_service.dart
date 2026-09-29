import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import '../models/app_state.dart';
import 'alert_service.dart';

class ArbPayService {
  static const List<String> _apiUrls = [
    'https://apiweb.payapiar.com',
    'https://apiweb.apiarbpay.com',
    'https://apiweb.asjoby.com',
    'https://apiweb.arbpay.me',
  ];
  String _apiUrl = 'https://apiweb.payapiar.com';
  static const List<String> _bankCodes = [
    'supermoney', 'phonepe', 'paytm', 'gpay', 'mobikwik', 'freeCharge', 'airtel',
    'jio', 'freo', 'slice', 'twid', 'pop', 'navi', 'moneyView', 'induspay'
  ];

  InAppWebViewController? _webView;
  AppState? _state;
  bool _running = false;
  String _token = '';
  String _deviceCode = '';
  String _memberId = '';
  int _bankIndex = 0;
  final Set<String> _skippedOrders = {};
  final Set<String> _seenBuyCodes = {};   // mirrors Python _seen_codes
  // Banks actually enabled/bound on the site for this account. Populated by
  // _fetchAvailableBanks(); falls back to the full hardcoded list.
  List<String> _activeBanks = List<String>.from(_bankCodes);
  // Consecutive orders that were rejected (2005) by EVERY active bank.
  int _ordersAllBanksRejected = 0;

  // ── Native HTTP fast-path ────────────────────────────────────────────────
  // We send API calls with a native keep-alive HTTP client (no WebView/JS
  // bridge) using the token + cookies + User-Agent harvested from the WebView
  // session. If Cloudflare blocks the native client (403 / challenge), we fall
  // back to the WebView fetch() path automatically.
  String _currentOrigin = 'https://arbpay.me';
  http.Client? _httpClient;
  String _userAgent = '';
  String _cookieHeader = '';
  bool _nativeEnabled = true;     // disabled after repeated CF blocks
  int _nativeBlockStreak = 0;     // consecutive native CF blocks
  DateTime? _nativeDisabledUntil; // temporary cooldown instead of permanent disable

  void init(InAppWebViewController controller, AppState state) {
    _webView = controller;
    _state = state;
  }

  void resetSessionAndCache() {
    _running = false;
    _skippedOrders.clear();
    _seenBuyCodes.clear();
    _bankIndex = 0;
    _ordersAllBanksRejected = 0;
    _token = '';
    _deviceCode = '';
    _memberId = '';
    _cookieHeader = '';
    _nativeBlockStreak = 0;
    _nativeDisabledUntil = null;
    try { _httpClient?.close(); } catch (_) {}
    _httpClient = null;
  }

  void dispose() {
    stop();
    AlertService.stopForegroundService();
    try { _httpClient?.close(); } catch (_) {}
    _httpClient = null;
    _webView = null;
    _state = null;
  }

  bool get isRunning => _running;

  Future<void> captureTokenAndRun(String phone, String password, int amtMin, int amtMax) async {
    if (_running) return;
    _running = true;
    _state?.setStatus(BotStatus.capturing);
    final mode = _state?.paymentMode == PaymentMode.bank ? 'Bank' : 'OTP/UPI';
    _log('Capturing token from active session... [Mode: $mode]', level: LogLevel.info);

    await AlertService.requestNotificationPermission();
    await AlertService.startForegroundService(
      'ARBPay Bot Running',
      'Capturing token from active session... [Mode: $mode]',
    );

    try {
      await _buildApiSession();
      if (_token.isEmpty) {
        _log('Token not found — make sure you are logged in', level: LogLevel.error);
        _state?.setStatus(BotStatus.error);
        return;
      }
      _log('Token captured! Starting buy loop...', level: LogLevel.success);
      _state?.setStatus(BotStatus.running);
      _seenBuyCodes.clear();
      await _harvestSession();
      await _fetchAvailableBanks();
      await _runBuyLoop(amtMin, amtMax);
    } catch (e) {
      _log('Fatal error: $e', level: LogLevel.error);
      _state?.setStatus(BotStatus.error);
    } finally {
      _running = false;
      if (_state?.status != BotStatus.qrReady) {
        AlertService.stopForegroundService();
      }
    }
  }

  void stop() {
    _running = false;
    _state?.setStatus(BotStatus.idle);
    AlertService.stopForegroundService();
    _log('Bot stopped by user', level: LogLevel.warning);
  }


  // ── Extract token from WebView localStorage ───────────────────────────────
  // Mirrors Python build_api_session exactly:
  //   token       = json.loads(ls.get("token",      "{}")).get("value", "")
  //   device_code = json.loads(ls.get("deviceCode", "{}")).get("value", "")
  Future<void> _buildApiSession() async {
    if (_webView == null) return;

    final result = await _webView!.callAsyncJavaScript(functionBody: '''
      var ls = {};
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        ls[k] = localStorage.getItem(k);
      }
      return ls;
    ''');

    if (result == null || result.value == null) {
      _log('localStorage empty — cannot read session', level: LogLevel.warning);
      return;
    }

    final lsMap = Map<String, dynamic>.from(result.value as Map);
    _log('LS keys: ${lsMap.keys.toList()}', level: LogLevel.info);

    // Primary path: exact Python approach
    try {
      final tokenRaw = lsMap['token']?.toString() ?? '{}';
      final tokenParsed = jsonDecode(tokenRaw) as Map;
      final t = tokenParsed['value']?.toString() ?? '';
      if (t.length > 20) {
        _token = t;
        _log('Token found at key "token"', level: LogLevel.success);
      }
    } catch (_) {}

    try {
      final dcRaw = lsMap['deviceCode']?.toString() ?? '{}';
      final dcParsed = jsonDecode(dcRaw) as Map;
      _deviceCode = dcParsed['value']?.toString() ?? '';
    } catch (_) {}

    // Extract memberId (critical for ARBPay gateway authorization)
    try {
      final memRaw = lsMap['memberId']?.toString() ?? '';
      if (memRaw.isNotEmpty && !memRaw.startsWith('{')) {
        _memberId = memRaw;
      } else if (memRaw.startsWith('{')) {
        final memParsed = jsonDecode(memRaw) as Map;
        _memberId = (memParsed['value'] ?? '').toString();
      }
      if (_memberId.isNotEmpty) {
        _log('memberId found at "memberId": $_memberId', level: LogLevel.success);
      }
    } catch (_) {}

    // Dynamic API domain from runtime-domains:PRO probe selections
    try {
      final rdRaw = lsMap['runtime-domains:PRO']?.toString();
      if (rdRaw != null && rdRaw.isNotEmpty) {
        final rd = jsonDecode(rdRaw);
        if (rd is Map && rd['selections'] is Map) {
          final activeApi = rd['selections']['api']?.toString();
          if (activeApi != null && activeApi.startsWith('http')) {
            _apiUrl = activeApi.replaceAll(RegExp(r'/+$'), '');
            _log('Dynamic active API domain: $_apiUrl', level: LogLevel.info);
          }
        }
      }
    } catch (_) {}

    // Fallback: scan all keys for token/auth/jwt and memberId patterns
    if (_token.isEmpty || _memberId.isEmpty) {
      for (final entry in lsMap.entries) {
        final key = entry.key.toLowerCase();
        final val = entry.value?.toString() ?? '';
        if (_token.isEmpty && (key.contains('token') || key.contains('auth') || key.contains('jwt'))) {
          if (val.length > 20 && !val.startsWith('{')) {
            _token = val;
            _log('Token found at key "${entry.key}"', level: LogLevel.success);
            break;
          }
          try {
            final parsed = jsonDecode(val) as Map;
            final t = (parsed['value'] ?? parsed['token'] ??
                parsed['accessToken'] ?? parsed['access_token'] ?? '').toString();
            if (t.length > 20) {
              _token = t;
              _log('Token found nested at key "${entry.key}"', level: LogLevel.success);
              break;
            }
          } catch (_) {}
        }
        if (_deviceCode.isEmpty && (key.contains('device') || key.contains('code'))) {
          if (val.length > 5 && !val.startsWith('{')) {
            _deviceCode = val;
          } else {
            try {
              final parsed = jsonDecode(val) as Map;
              _deviceCode = (parsed['value'] ?? parsed['deviceCode'] ?? '').toString();
            } catch (_) {}
          }
        }
        if (_memberId.isEmpty && (key.contains('member') || key.contains('userid'))) {
          if (val.isNotEmpty && !val.startsWith('{') && RegExp(r'^\d+$').hasMatch(val)) {
            _memberId = val;
            _log('memberId found at key "${entry.key}": $_memberId', level: LogLevel.info);
          } else if (val.startsWith('{')) {
            try {
              final parsed = jsonDecode(val) as Map;
              final m = (parsed['value'] ?? parsed['memberId'] ?? parsed['id'] ?? '').toString();
              if (m.isNotEmpty && RegExp(r'^\d+$').hasMatch(m)) {
                _memberId = m;
                _log('memberId found nested at key "${entry.key}": $_memberId', level: LogLevel.info);
              }
            } catch (_) {}
          }
        }
      }
    }

    // Last resort: any JWT-like long string with dots
    if (_token.isEmpty) {
      for (final entry in lsMap.entries) {
        final val = entry.value?.toString() ?? '';
        if (val.contains('.') && val.length > 50 && !val.startsWith('{')) {
          _token = val;
          _log('Token guessed from key "${entry.key}"', level: LogLevel.warning);
          break;
        }
        try {
          final parsed = jsonDecode(val);
          if (parsed is Map) {
            for (final v in parsed.values) {
              final s = v?.toString() ?? '';
              if (s.length > 50 && s.contains('.')) {
                _token = s;
                _log('Token guessed nested from key "${entry.key}"', level: LogLevel.warning);
                break;
              }
            }
          }
        } catch (_) {}
        if (_token.isNotEmpty) break;
      }
    }

    if (_token.isNotEmpty) {
      _log(
        'API session ready — token ...${_token.length > 12 ? _token.substring(_token.length - 12) : _token}, memberId: ${_memberId.isEmpty ? "(none)" : _memberId}',
        level: LogLevel.success,
      );
    } else {
      _log('Token not found — make sure you are logged in', level: LogLevel.error);
    }

    // If the native fast-path is already armed, refresh cookies so a rebuilt
    // session keeps using a valid cf_clearance.
    if (_httpClient != null) {
      await _refreshCookies();
    }
  }

  // ── Fetch banks actually available on the site for buying ───────────────
  // The endpoint takes {'type': '1'} for buying and returns data.allBanks
  // (supported payment banks). Falls back to the hardcoded list that the
  // Python script uses, so this is a safe default on any failure.
  Future<void> _fetchAvailableBanks() async {
    final resp = await _request(
      '/ar-wallet/kycCenter/getBanks/bankListAndBoundListForQuick',
      {'type': '1'},
      verbose: true,
    );

    if (resp.isEmpty) {
      _log('Bank list fetch failed — using default bank cycle (${_bankCodes.join(", ")})',
          level: LogLevel.warning);
      _activeBanks = List<String>.from(_bankCodes);
      return;
    }

    final respCode = resp['code']?.toString() ?? '';
    final respMsg  = resp['msg']?.toString() ?? resp['message']?.toString() ?? '';
    if (respCode != '1' && respCode != '200' && respCode != '0') {
      _log('Bank list API error (code=$respCode): $respMsg — using default bank cycle',
          level: LogLevel.warning);
      _activeBanks = List<String>.from(_bankCodes);
      return;
    }

    // The response shape isn't 100% known, so scan recursively for any
    // bank-code-like field that isn't explicitly disabled.
    final codes = <String>[];
    void scan(dynamic node) {
      if (node is Map) {
        final code = (node['bankCode'] ?? node['payBankCode'] ??
                node['channelCode'] ?? node['bankCardCode'] ?? '')
            .toString()
            .toLowerCase()
            .trim();
        final status = (node['status'] ?? node['enable'] ?? node['enabled'] ??
                node['available'] ?? node['state'] ?? '')
            .toString()
            .toLowerCase();
        final disabled = status == '0' || status == 'false' ||
            status == 'disabled' || status == 'off' || status == 'no';
        if (code.isNotEmpty && !disabled) codes.add(code);
        for (final v in node.values) {
          scan(v);
        }
      } else if (node is List) {
        for (final v in node) {
          scan(v);
        }
      }
    }
    // Walk data.allBanks (supported payment banks for buying). Also
    // check data.boundBanks as a fallback in case the shape differs.
    final dataNode = resp['data'];
    if (dataNode is Map) {
      scan(dataNode['allBanks'] ?? dataNode['boundBanks'] ?? dataNode);
    }

    // Order: known codes first (we know how to send them), then any extras.
    final seen = <String>{};
    final ordered = <String>[];
    for (final b in _bankCodes) {
      if (codes.contains(b) && seen.add(b)) ordered.add(b);
    }
    for (final c in codes) {
      if (seen.add(c)) ordered.add(c);
    }

    if (ordered.isEmpty) {
      _log('Bank list parsed but NO usable bankCodes found. Using default: ${_bankCodes.join(", ")}',
          level: LogLevel.warning);
      _activeBanks = List<String>.from(_bankCodes);
    } else {
      _activeBanks = ordered;
      _log('Enabled banks: ${ordered.join(", ")}', level: LogLevel.success);
    }
  }

  // ── Buy loop ───────────────────────────────────────────────────────────────
  Future<void> _runBuyLoop(int amtMin, int amtMax) async {
    final isBank = _state?.paymentMode == PaymentMode.bank;
    final orderType = isBank ? 2 : 1;
    final payType   = isBank ? '1' : '3';
    final modeLabel = isBank ? 'Bank' : 'OTP/UPI';
    _log('Buy loop started (₹$amtMin - ₹$amtMax) [Mode: $modeLabel]', level: LogLevel.success);
    _log('Token last 12: ...${_token.length > 12 ? _token.substring(_token.length - 12) : _token}',
        level: LogLevel.info);
    _log('deviceCode: ${_deviceCode.isEmpty ? "(empty)" : _deviceCode}',
        level: LogLevel.info);
    _skippedOrders.clear();
    _bankIndex = 0;
    _ordersAllBanksRejected = 0;
    int emptyStreak   = 0;
    int fetchFailStreak = 0;
    int buyListCallCount = 0;
    // Log every buy response for first 10 attempts, then every unique code
    int verboseBuyCount = 0;

    while (_running) {
      if (_token.isEmpty) {
        _log('No token — waiting 3s', level: LogLevel.warning);
        await Future.delayed(const Duration(seconds: 3));
        continue;
      }

      // ── buyList — verbose on first call and every 10 attempts ─────────────
      buyListCallCount++;
      final isVerbose = buyListCallCount <= 3 || buyListCallCount % 10 == 0;
      final orders = await _getOrderList(amtMin, amtMax, orderType: orderType, verbose: isVerbose);

      if (orders.isEmpty) {
        emptyStreak++;
        if (emptyStreak % 100 == 0) {
          _log('Searching for orders in ₹$amtMin-₹$amtMax ($emptyStreak checks)...',
              level: LogLevel.info);
        }
        await Future.delayed(const Duration(milliseconds: 15));
        continue;
      }
      emptyStreak = 0;
      fetchFailStreak = 0;

      // Pick first order not in skip list
      Map<String, dynamic>? order;
      for (final o in orders) {
        final oid = (o['platformOrder'] ?? o['orderNo'] ?? o['mOrderNo'] ?? '').toString();
        if (oid.isNotEmpty && !_skippedOrders.contains(oid)) {
          order = o;
          break;
        }
      }
      if (order == null) {
        _skippedOrders.clear();
        await Future.delayed(const Duration(milliseconds: 15));
        continue;
      }

      final platformOrder = (order['platformOrder'] ?? order['orderNo'] ?? order['mOrderNo'] ?? '').toString();
      final rawAmt = order['amount'] ?? order['maximumAmount'] ?? order['minimumAmount'] ?? '0';
      final amount = (double.tryParse(rawAmt.toString()) ?? 0).toInt();
      if (platformOrder.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 10));
        continue;
      }

      final targetPayType = (order['payType'] != null && order['payType'].toString().isNotEmpty)
          ? order['payType'].toString()
          : payType;
      final targetOrderType = (order['orderType'] != null)
          ? (int.tryParse(order['orderType'].toString()) ?? orderType)
          : orderType;

      // Increment attempt counter ONLY when an actual buy is executed!
      _state?.incrementAttempts();
      final attempts = _state?.attempts ?? 0;

      final isOrderBank = targetPayType == '1' || targetOrderType == 2;
      final currentBank = isOrderBank ? '' : _activeBanks[_bankIndex % _activeBanks.length];
      final bankLabel = isOrderBank ? 'Bank Transfer' : 'bank=$currentBank';
      _log('Attempt #$attempts → order=$platformOrder ₹$amount [$bankLabel]',
          level: LogLevel.info);

      // ── buy (two-step beforeBuy + buy claiming) ──────────────────────────
      verboseBuyCount++;
      final buyResp = await _claimOrder(platformOrder, amount, currentBank,
          payType: targetPayType, orderType: targetOrderType,
          verbose: verboseBuyCount <= 5);

      // Always log the full raw buy response for the first 5, then every unique code
      final rawPreview = jsonEncode(buyResp);
      if (verboseBuyCount <= 5) {
        _log('buy[$verboseBuyCount] raw: ${rawPreview.length > 400 ? rawPreview.substring(0, 400) : rawPreview}',
            level: LogLevel.info);
      }

      if (buyResp.isEmpty) {
        fetchFailStreak++;
        _log('buy empty resp #$fetchFailStreak', level: LogLevel.warning);
        if (fetchFailStreak >= 5) {
          _log('[WARN] $fetchFailStreak consecutive empty — rebuilding session',
              level: LogLevel.warning);
          await _buildApiSession();
          await _harvestSession();
          _skippedOrders.clear();
          _bankIndex = 0;
          _ordersAllBanksRejected = 0;
          fetchFailStreak = 0;
        }
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }
      fetchFailStreak = 0;

      final code = buyResp['code']?.toString() ?? '';
      final msg  = buyResp['msg']?.toString() ?? buyResp['message']?.toString() ?? '';

      // Any response other than a bank rejection means at least one bank is
      // being accepted/processed — reset the "all banks dead" detector.
      if (code != '2005') _ordersAllBanksRejected = 0;

      // Log every unique code with its message
      if (!_seenBuyCodes.contains(code)) {
        _seenBuyCodes.add(code);
        _log('NEW buy code=$code msg="$msg" | ${rawPreview.length > 250 ? rawPreview.substring(0, 250) : rawPreview}',
            level: LogLevel.warning);
      }

      if (['200', '0', '1', '00', 'success', 'SUCCESS'].contains(code)) {
        final mrOrder = _extractMrOrder(buyResp);
        if (mrOrder.isNotEmpty) {
          _log('BUY SUCCESS after $attempts attempts — Order: $mrOrder ₹$amount',
              level: LogLevel.success);
          _state?.incrementSuccess();
          _state?.setCurrentOrder(mrOrder);
          _state?.incrementRounds();
          _state?.setStatus(BotStatus.qrReady);
          if (_state != null) {
            AlertService.playQrReadyAlert(_state!);
          }
          await _reloadWebView(mrOrder);
          return;
        } else {
          _log('code=$code but MR order missing! Full: $rawPreview', level: LogLevel.error);
        }
      } else if (code == '2005') {
        if (!isOrderBank) {
          _log('Bank "$currentBank" rejected (2005) for $platformOrder — next bank', level: LogLevel.warning);
          _bankIndex++;
          if (_bankIndex % _activeBanks.length == 0) {
            _log('All banks rejected for $platformOrder — skipping', level: LogLevel.warning);
            _skippedOrders.add(platformOrder);
            _bankIndex = 0;
            _ordersAllBanksRejected++;
            if (_ordersAllBanksRejected % 5 == 0) {
              _log('Notice: $_ordersAllBanksRejected orders rejected by current bank cycle. Continuing scan...',
                  level: LogLevel.warning);
            }
          }
        } else {
          _log('Bank mode order rejected (2005) for $platformOrder — skipping', level: LogLevel.warning);
          _skippedOrders.add(platformOrder);
        }
        await Future.delayed(const Duration(milliseconds: 10));
        continue;
      } else if (code == '1027') {
        final data = buyResp['data'];
        final existingOrder = (data is Map ? (data['platformOrder'] ?? data['buyOrderNo'] ?? '') : '').toString();
        if (existingOrder.isNotEmpty) {
          _log('Unfinished order: $existingOrder — proceeding', level: LogLevel.warning);
          _state?.setCurrentOrder(existingOrder);
          _state?.setStatus(BotStatus.qrReady);
          if (_state != null) {
            AlertService.playQrReadyAlert(_state!);
          }
          await _reloadWebView(existingOrder);
          return;
        }
      } else if (code == '1191') {
        _log('Rate limited (1191) "$msg" — waiting 3s', level: LogLevel.warning);
        await Future.delayed(const Duration(seconds: 3));
        continue;
      } else if (code == '1194') {
        _skippedOrders.add(platformOrder);
        _log('Order $platformOrder snatched by competitor (1194)', level: LogLevel.warning);
      } else {
        _skippedOrders.add(platformOrder);
        _log('Order $platformOrder failed (code=$code): "$msg"', level: LogLevel.warning);
      }

      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> _reloadWebView([String orderNo = '']) async {
    try {
      if (orderNo.isNotEmpty) {
        await _webView?.loadUrl(urlRequest: URLRequest(
          url: WebUri('$_currentOrigin/#/order/cashier?platformOrder=$orderNo'),
        ));
      } else {
        await _webView?.reload();
      }
    } catch (_) {}
    _log('QR payment screen ready!', level: LogLevel.success);
  }

  // ── Harvest token/cookies/UA for session ─────────────────────────────────
  Future<void> _harvestSession() async {
    if (_webView == null) return;
    try {
      final ua = await _webView!.evaluateJavascript(source: 'navigator.userAgent');
      _userAgent = (ua?.toString() ?? '').trim();
      if (_userAgent.isEmpty) {
        _userAgent = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
      }

      try {
        final currentUrl = await _webView!.getUrl();
        if (currentUrl != null && currentUrl.origin.isNotEmpty) {
          _currentOrigin = currentUrl.origin;
        }
      } catch (_) {}

      final cm = CookieManager.instance();
      final cookies = await cm.getCookies(url: WebUri(_currentOrigin));
      final byName = <String, String>{};
      for (final c in cookies) {
        if (c.name.isNotEmpty) byName[c.name] = c.value.toString();
      }
      if (byName.isNotEmpty) {
        _cookieHeader = byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
      }
      _httpClient ??= http.Client();
    } catch (_) {}
  }

  bool _looksLikeCfChallenge(int status, String body) {
    if (status == 403 || status == 503 || status == 429) return true;
    final b = body.toLowerCase();
    return b.contains('just a moment') ||
        b.contains('challenge-platform') ||
        b.contains('cf-chl') ||
        b.contains('_cf_chl') ||
        b.contains('attention required') ||
        (b.contains('cloudflare') && b.contains('<html'));
  }

  // ── Native HTTP POST. Returns:                                            ──
  //   • a parsed Map (possibly empty) when the native client handled it      ──
  //   • null when blocked/unusable → caller should fall back to WebView      ──
  Future<Map<String, dynamic>?> _postNative(String path, Map<String, dynamic> body,
      {String page = 'Arb', bool verbose = false}) async {
    if (_httpClient == null || _token.isEmpty) return null;
    if (!_nativeEnabled) {
      if (_nativeDisabledUntil != null && DateTime.now().isBefore(_nativeDisabledUntil!)) {
        return null;
      }
      _nativeEnabled = true;
      _nativeBlockStreak = 0;
    }

    final headers = <String, String>{
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/json',
      'authorization': 'Bearer $_token',
      if (_memberId.isNotEmpty) 'memberId': _memberId,
      'deviceCode': _deviceCode,
      'deviceId': '',
      'deviceType': '3',
      'language': '1',
      'page': page,
      'Origin': _currentOrigin,
      'Referer': '$_currentOrigin/',
      if (_userAgent.isNotEmpty) 'User-Agent': _userAgent,
      if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
    };

    try {
      final resp = await _httpClient!
          .post(Uri.parse('$_apiUrl$path'), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 8));

      final status = resp.statusCode;
      final text = resp.body;

      if (_looksLikeCfChallenge(status, text)) {
        _nativeBlockStreak++;
        _log('Native POST $path blocked by Cloudflare (HTTP $status) — falling back to WebView',
            level: LogLevel.warning);
        // Re-harvest cookies once in case clearance rotated.
        if (_nativeBlockStreak == 1) {
          await _refreshCookies();
        }
        if (_nativeBlockStreak >= 3) {
          _nativeEnabled = false;
          _nativeDisabledUntil = DateTime.now().add(const Duration(seconds: 15));
          _log('Native path paused for 15s after $_nativeBlockStreak CF blocks — using WebView',
              level: LogLevel.warning);
        }
        return null; // fall back
      }

      _nativeBlockStreak = 0; // healthy response resets the block streak

      if (status != 200 && status != 201) {
        final preview = text.length > 300 ? text.substring(0, 300) : text;
        _log('Native POST $path → HTTP $status body: $preview', level: LogLevel.error);
        return {}; // handled (real server error, not a CF block)
      }
      if (text.isEmpty) return {};

      if (verbose) {
        final preview = text.length > 400 ? text.substring(0, 400) : text;
        _log('Native POST $path → $status: $preview', level: LogLevel.info);
      }

      try {
        return Map<String, dynamic>.from(jsonDecode(text));
      } catch (_) {
        // HTML/non-JSON where JSON was expected ⇒ likely a challenge.
        if (_looksLikeCfChallenge(200, text)) return null;
        return {};
      }
    } catch (e) {
      // Network/timeout/socket error — don't kill native permanently, just
      // fall back for this call.
      _log('Native POST $path → error: $e — falling back to WebView',
          level: LogLevel.warning);
      return null;
    }
  }

  Future<void> _refreshCookies() async {
    try {
      final cm = CookieManager.instance();
      var byName = <String, String>{};
      final probeHosts = [
        ..._apiUrls,
        'https://arbpay.me',
        'https://arbpay.co',
      ];
      try {
        final currentUrl = await _webView!.getUrl();
        if (currentUrl != null && currentUrl.origin.isNotEmpty) {
          probeHosts.insert(0, currentUrl.origin);
        }
      } catch (_) {}

      for (final host in probeHosts) {
        try {
          final cookies = await cm.getCookies(url: WebUri(host));
          for (final c in cookies) {
            if (c.name.isNotEmpty) byName[c.name] = c.value.toString();
          }
        } catch (_) {}
      }
      // If cf_clearance is still missing, re-warm the API host.
      if (!byName.containsKey('cf_clearance') && _webView != null) {
        _log('Re-warming API host for cf_clearance...', level: LogLevel.info);
        await _webView!.callAsyncJavaScript(functionBody: '''
          try {
            await fetch("$_apiUrl", {
              method: "GET", mode: "no-cors", credentials: "include"
            });
          } catch (_) {}
          return true;
        ''');
        byName = {};
        for (final host in probeHosts) {
          try {
            final cookies = await cm.getCookies(url: WebUri(host));
            for (final c in cookies) {
              if (c.name.isNotEmpty) byName[c.name] = c.value.toString();
            }
          } catch (_) {}
        }
      }
      if (byName.isNotEmpty) {
        _cookieHeader = byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
      }
    } catch (_) {}
  }

  Map<String, dynamic> _cleanBody(Map<String, dynamic> body) {
    final clean = <String, dynamic>{};
    for (final entry in body.entries) {
      if (entry.value != null && entry.value.toString().isNotEmpty) {
        clean[entry.key] = entry.value;
      }
    }
    return clean;
  }

  // ── Unified request: native fast-path first, WebView fallback ─────────────
  Future<Map<String, dynamic>> _request(String path, Map<String, dynamic> body,
      {String page = 'Arb', bool verbose = false}) async {
    final clean = _cleanBody(body);
    if (_nativeEnabled && _token.isNotEmpty) {
      final native = await _postNative(path, clean, page: page, verbose: verbose);
      if (native != null) return native;
    }
    return _post(path, clean, page: page, verbose: verbose);
  }

  // ── WebView fetch() — full verbose logging ───────────────────────────────
  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {String page = 'Arb', bool verbose = false}) async {
    if (_webView == null) {
      _log('POST $path — WebView is null!', level: LogLevel.error);
      return {};
    }
    if (_token.isEmpty) {
      _log('POST $path — token is empty!', level: LogLevel.error);
      return {};
    }

    try {
      final result = await _webView!.callAsyncJavaScript(
        functionBody: '''
          try {
            var headers = {
              'Accept': 'application/json, text/plain, */*',
              'Content-Type': 'application/json',
              'authorization': 'Bearer ' + token,
              'deviceCode': deviceCode || '',
              'deviceId': '',
              'deviceType': '3',
              'language': '1',
              'page': page
            };
            if (memberId && memberId.length > 0) {
              headers['memberId'] = memberId;
            }
            var resp = await fetch(apiUrl, {
              method: 'POST',
              headers: headers,
              credentials: 'include',
              body: bodyStr
            });
            var text = await resp.text();
            return { ok: resp.ok, status: resp.status, text: text };
          } catch(e) {
            return { ok: false, status: 0, text: String(e) };
          }
        ''',
        arguments: {
          'apiUrl':     '$_apiUrl$path',
          'token':      _token,
          'memberId':   _memberId,
          'deviceCode': _deviceCode,
          'page':       page,
          'bodyStr':    jsonEncode(body),
        },
      );

      // ── callAsyncJavaScript-level failure ──────────────────────────────
      if (result == null) {
        _log('POST $path → callAsyncJS returned null', level: LogLevel.error);
        return {};
      }
      if (result.error != null && (result.error?.isNotEmpty ?? false)) {
        _log('POST $path → JS exception: ${result.error}', level: LogLevel.error);
        return {};
      }
      if (result.value == null) {
        _log('POST $path → JS returned null value', level: LogLevel.error);
        return {};
      }

      final res = Map<String, dynamic>.from(result.value as Map);
      final status = (res['status'] as num?)?.toInt() ?? 0;
      final text   = res['text']?.toString() ?? '';
      final ok     = res['ok'] == true;

      // ── Always log non-200 HTTP responses ────────────────────────────────
      if (!ok || (status != 200 && status != 201)) {
        final preview = text.length > 300 ? text.substring(0, 300) : text;
        _log('POST $path → HTTP $status (ok=$ok) body: $preview',
            level: LogLevel.error);
        return {};
      }

      if (text.isEmpty) {
        _log('POST $path → HTTP $status but empty body', level: LogLevel.warning);
        return {};
      }

      // ── Verbose: log raw success response ─────────────────────────────
      if (verbose) {
        final preview = text.length > 400 ? text.substring(0, 400) : text;
        _log('POST $path → $status: $preview', level: LogLevel.info);
      }

      try {
        return Map<String, dynamic>.from(jsonDecode(text));
      } catch (e) {
        _log('POST $path → JSON parse error: $e | body: ${text.substring(0, text.length.clamp(0, 200))}',
            level: LogLevel.error);
        return {};
      }
    } catch (e) {
      if (e.toString().contains('MissingPluginException') || e.toString().contains('no implementation found')) {
        _log('WebView detached or reloading — waiting 1s...', level: LogLevel.warning);
        await Future.delayed(const Duration(seconds: 1));
      } else {
        _log('POST $path → Dart exception: $e', level: LogLevel.error);
      }
      return {};
    }
  }

  // ── Order list ─────────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _getOrderList(int amtMin, int amtMax,
      {int orderType = 1, bool verbose = false}) async {
    final data = await _request(
      '/ar-wallet/buyCenter/buyList',
      {'orderType': orderType, 'pageNo': 1},
      verbose: verbose,
    );

    if (data.isEmpty) return [];

    // Log full raw top-level keys every verbose call
    if (verbose) {
      _log('buyList keys: ${data.keys.toList()} | code=${data['code']}',
          level: LogLevel.info);
    }

    List<dynamic> records = [];
    for (final topKey in ['data', 'result', 'body', 'response']) {
      final inner = data[topKey];
      if (inner == null) continue;
      if (inner is List) { records = inner; break; }
      if (inner is Map) {
        for (final subKey in ['records', 'list', 'rows', 'data', 'items', 'content']) {
          final val = inner[subKey];
          if (val is List && val.isNotEmpty) { records = val; break; }
        }
        if (records.isNotEmpty) break;
      }
    }

    if (verbose) {
      if (records.isEmpty) {
        _log('buyList: 0 raw records. Full resp: ${jsonEncode(data).substring(0, jsonEncode(data).length.clamp(0, 500))}',
            level: LogLevel.warning);
      } else {
        final amounts = records
            .whereType<Map>()
            .map((o) => o['amount']?.toString() ?? '?')
            .take(5)
            .join(', ');
        _log('buyList: ${records.length} records, amounts=[$amounts...]',
            level: LogLevel.info);
      }
    }

    final filtered = records
        .whereType<Map<String, dynamic>>()
        .where((o) {
          final rawAmt = o['amount'] ?? o['maximumAmount'] ?? o['minimumAmount'] ?? '0';
          final amt = double.tryParse(rawAmt.toString()) ?? 0;
          return amt >= amtMin && amt <= amtMax;
        })
        .toList();

    // Sort newest orders first so the bot claims fresh listings before competitors
    filtered.sort((a, b) {
      final tA = num.tryParse((a['timeStamp'] ?? a['timestamp'] ?? 0).toString()) ?? 0;
      final tB = num.tryParse((b['timeStamp'] ?? b['timestamp'] ?? 0).toString()) ?? 0;
      if (tA != tB) return tB.compareTo(tA);
      final ordA = (a['platformOrder'] ?? a['orderNo'] ?? '').toString();
      final ordB = (b['platformOrder'] ?? b['orderNo'] ?? '').toString();
      return ordB.compareTo(ordA);
    });

    if (verbose && records.isNotEmpty) {
      _log('buyList: ${filtered.length} orders in ₹$amtMin-₹$amtMax range',
          level: filtered.isEmpty ? LogLevel.warning : LogLevel.success);
    }

    return filtered;
  }

  Future<Map<String, dynamic>> _apiBeforeBuy(
      String platformOrder, int amount, String bankCode,
      {String payType = '3', int orderType = 1, bool verbose = false}) async {
    final body = <String, dynamic>{
      'amount': amount,
      'platformOrder': platformOrder,
      'payType': payType,
      'orderType': orderType,
    };
    if (payType == '3' && bankCode.isNotEmpty) {
      body['buyBankCode'] = bankCode;
    }
    return _request(
      '/ar-wallet/buyCenter/beforeBuy',
      body,
      verbose: verbose,
    );
  }

  Future<Map<String, dynamic>> _apiBuy(
      String platformOrder, int amount, String bankCode,
      {String payType = '3', int orderType = 1, bool verbose = false}) async {
    final body = <String, dynamic>{
      'amount': amount,
      'platformOrder': platformOrder,
      'payType': payType,
      'orderType': orderType,
    };
    if (payType == '3' && bankCode.isNotEmpty) {
      body['buyBankCode'] = bankCode;
      body['buyerKycId'] = 0;
    }
    return _request(
      '/ar-wallet/buyCenter/buy',
      body,
      verbose: verbose,
    );
  }

  static const _successCodes = {'200', '0', '1', '00', 'success', 'SUCCESS'};

  Future<Map<String, dynamic>> _claimOrder(
      String platformOrder, int amount, String bankCode,
      {required String payType, required int orderType, bool verbose = false}) async {
    // 1-step direct buy attempt first for sub-50ms high-speed claiming
    final buyResp = await _apiBuy(
      platformOrder,
      amount,
      bankCode,
      payType: payType,
      orderType: orderType,
      verbose: verbose,
    );

    final buyCode = buyResp['code']?.toString() ?? '';
    // If successful, or if order status is definitive (bank reject, snatched, unfinished), return immediately
    if (_successCodes.contains(buyCode) || buyCode == '2005' || buyCode == '1194' || buyCode == '1027') {
      return buyResp;
    }

    // Step 2 fallback: beforeBuy reservation in case backend requires slot reservation
    final beforeResp = await _apiBeforeBuy(
      platformOrder,
      amount,
      bankCode,
      payType: payType,
      orderType: orderType,
      verbose: verbose,
    );

    final beforeCode = beforeResp['code']?.toString() ?? '';
    if (_successCodes.contains(beforeCode)) {
      final mrOrder = _extractMrOrder(beforeResp);
      if (mrOrder.isNotEmpty) {
        return beforeResp;
      }
      return await _apiBuy(
        platformOrder,
        amount,
        bankCode,
        payType: payType,
        orderType: orderType,
        verbose: verbose,
      );
    }

    return beforeResp.isNotEmpty ? beforeResp : buyResp;
  }

  String _extractMrOrder(Map<String, dynamic> resp) {
    final data = resp['data'] ?? resp['result'];
    if (data is String && data.isNotEmpty) return data;
    if (data is Map) {
      final orderNo = (data['buyOrderNo'] ?? data['platformOrder'] ??
          data['orderNo'] ?? data['mOrderNo'] ?? '').toString();
      if (orderNo.isNotEmpty) return orderNo;
    }
    return (resp['buyOrderNo'] ?? resp['platformOrder'] ?? resp['orderNo'] ?? '').toString();
  }

  void _log(String msg, {LogLevel level = LogLevel.info}) {
    _state?.addLog(msg, level: level);
    debugPrint('[ARBPay] $msg');
  }
}

const String siteUrl = 'https://arbpay.me';
