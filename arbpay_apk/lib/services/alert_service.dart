import 'package:flutter/services.dart';
import '../models/app_state.dart';

class AlertService {
  static const _channel = MethodChannel('com.arbpay.bot/device');

  /// Launches an external app deep-link (such as phonepe://, upi://, intent://)
  static Future<bool> launchExternalUrl(String url) async {
    try {
      final res = await _channel.invokeMethod<bool>('launchExternal', {'url': url});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Starts the Android Foreground Service for uninterrupted background execution
  static Future<void> startForegroundService(String title, String text) async {
    try {
      await _channel.invokeMethod('startForegroundService', {
        'title': title,
        'text': text,
      });
    } catch (_) {}
  }

  /// Updates the ongoing background notification with the latest log/status
  static Future<void> updateForegroundService(String title, String text, {bool highPriority = false}) async {
    try {
      await _channel.invokeMethod('updateForegroundService', {
        'title': title,
        'text': text,
        'highPriority': highPriority,
      });
    } catch (_) {}
  }

  /// Stops the Foreground Service when bot is idle/stopped
  static Future<void> stopForegroundService() async {
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (_) {}
  }

  /// Requests notification permission on Android 13+ (API 33+)
  static Future<void> requestNotificationPermission() async {
    try {
      await _channel.invokeMethod('requestNotificationPermission');
    } catch (_) {}
  }

  /// Stops any active or repeating vibration immediately
  static Future<void> stopVibration() async {
    try {
      await _channel.invokeMethod('stopVibrate');
    } catch (_) {}
  }

  /// Triggers a heads-up banner notification popup
  static Future<void> showQrReadyNotification({
    String title = '🔥 ORDER CLAIMED! QR Ready',
    String text = 'Tap to open payment screen and complete order',
  }) async {
    try {
      await _channel.invokeMethod('showQrReadyNotification', {
        'title': title,
        'text': text,
      });
    } catch (_) {}
  }

  /// Triggers sound, heads-up notification popup, and vibration when an order is claimed and QR is ready
  static Future<void> playQrReadyAlert(AppState state) async {
    if (state.qrSoundEnabled) {
      try {
        await _channel.invokeMethod('playAlert', {'type': 'qr'});
      } catch (_) {}
    }
    if (state.qrVibrateEnabled) {
      final vibeType = state.aggressiveAlertEnabled ? 'qr_aggressive' : 'qr';
      try {
        await _channel.invokeMethod('vibrate', {'type': vibeType});
      } catch (_) {}
    }
    await showQrReadyNotification(
      title: '🔥 ORDER CLAIMED! QR Ready',
      text: state.currentOrder.isNotEmpty
          ? 'Order: ${state.currentOrder} — Tap to complete payment'
          : 'Tap to complete payment',
    );
  }

  /// Triggers sound and/or vibration when KYC Confirmation is requested / required
  static Future<void> playKycPromptAlert(AppState state) async {
    if (state.kycSoundEnabled) {
      try {
        await _channel.invokeMethod('playAlert', {'type': 'kyc'});
      } catch (_) {}
    }
    if (state.kycVibrateEnabled) {
      try {
        await _channel.invokeMethod('vibrate', {'type': 'kyc'});
      } catch (_) {}
    }
  }

  /// Triggers sound and/or vibration when KYC Confirmation transitions to Completed
  static Future<void> playKycCompletedAlert(AppState state) async {
    if (state.kycSoundEnabled) {
      try {
        await _channel.invokeMethod('playAlert', {'type': 'kyc'});
      } catch (_) {}
    }
    if (state.kycVibrateEnabled) {
      try {
        await _channel.invokeMethod('vibrate', {'type': 'kyc'});
      } catch (_) {}
    }
  }

  /// Preview test sound for settings
  static Future<void> testSound(String type) async {
    try {
      await _channel.invokeMethod('playAlert', {'type': type});
    } catch (_) {}
  }

  /// Preview test vibration for settings
  static Future<void> testVibrate(String type) async {
    try {
      await _channel.invokeMethod('vibrate', {'type': type});
    } catch (_) {}
  }
}
