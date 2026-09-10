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

  /// Triggers sound and/or vibration when an order is claimed and QR is ready
  static Future<void> playQrReadyAlert(AppState state) async {
    if (state.qrSoundEnabled) {
      try {
        await _channel.invokeMethod('playAlert', {'type': 'qr'});
      } catch (_) {}
    }
    if (state.qrVibrateEnabled) {
      try {
        await _channel.invokeMethod('vibrate', {'type': 'qr'});
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
