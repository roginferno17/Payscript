import 'package:flutter/foundation.dart';

enum BotStatus { idle, connecting, cloudflare, loggingIn, capturing, running, qrReady, success, error }

enum PaymentMode { upi, bank }

class LogEntry {
  final String time;
  final String message;
  final LogLevel level;

  LogEntry({required this.time, required this.message, required this.level});
}

enum LogLevel { info, success, warning, error }

class AppState extends ChangeNotifier {
  BotStatus _status = BotStatus.idle;
  final List<LogEntry> _logs = [];
  int _rounds = 0;
  int _attempts = 0;
  int _successCount = 0;
  String _currentOrder = '';

  // Settings
  String phone = '';
  String password = '';
  int amountMin = 1700;
  int amountMax = 2000;
  PaymentMode paymentMode = PaymentMode.upi;
  bool isDark = true;

  // Alerts
  bool qrSoundEnabled = true;
  bool qrVibrateEnabled = true;
  bool kycSoundEnabled = true;
  bool kycVibrateEnabled = true;

  void setQrAlerts({bool? sound, bool? vibrate}) {
    if (sound != null) qrSoundEnabled = sound;
    if (vibrate != null) qrVibrateEnabled = vibrate;
    notifyListeners();
  }

  void setKycAlerts({bool? sound, bool? vibrate}) {
    if (sound != null) kycSoundEnabled = sound;
    if (vibrate != null) kycVibrateEnabled = vibrate;
    notifyListeners();
  }

  BotStatus get status => _status;
  List<LogEntry> get logs => List.unmodifiable(_logs);
  int get rounds => _rounds;
  int get attempts => _attempts;
  int get successCount => _successCount;
  String get currentOrder => _currentOrder;

  // Derived API values based on payment mode
  int get orderType => paymentMode == PaymentMode.upi ? 1 : 2;
  String get payType => paymentMode == PaymentMode.upi ? '3' : '1';

  void setPaymentMode(PaymentMode mode) {
    paymentMode = mode;
    notifyListeners();
  }

  void toggleTheme() {
    isDark = !isDark;
    notifyListeners();
  }

  void setStatus(BotStatus s) {
    _status = s;
    notifyListeners();
  }

  void addLog(String message, {LogLevel level = LogLevel.info}) {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    _logs.insert(0, LogEntry(time: time, message: message, level: level));
    if (_logs.length > 200) _logs.removeLast();
    notifyListeners();
  }

  void incrementAttempts() {
    _attempts++;
    notifyListeners();
  }

  void incrementRounds() {
    _rounds++;
    notifyListeners();
  }

  void incrementSuccess() {
    _successCount++;
    notifyListeners();
  }

  void setCurrentOrder(String order) {
    _currentOrder = order;
    notifyListeners();
  }

  void reset() {
    _status = BotStatus.idle;
    _attempts = 0;
    _currentOrder = '';
    notifyListeners();
  }

  void resetForNewRun() {
    _status = BotStatus.idle;
    _attempts = 0;
    _currentOrder = '';
    _logs.clear();
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
}
