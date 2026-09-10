import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../theme/app_theme.dart';
import '../services/icon_service.dart';
import '../services/alert_service.dart';

// Keep local constants only for things that don't change with theme
const _yellow = Color(0xFFFFCC00);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _phoneCtrl;
  late TextEditingController _passwordCtrl;
  late TextEditingController _amtMinCtrl;
  late TextEditingController _amtMaxCtrl;
  bool _obscurePassword = true;
  late PaymentMode _paymentMode;
  late bool _qrSound;
  late bool _qrVibrate;
  late bool _kycSound;
  late bool _kycVibrate;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _phoneCtrl    = TextEditingController(text: state.phone);
    _passwordCtrl = TextEditingController(text: state.password);
    _amtMinCtrl   = TextEditingController(text: state.amountMin.toString());
    _amtMaxCtrl   = TextEditingController(text: state.amountMax.toString());
    _paymentMode  = state.paymentMode;
    _qrSound      = state.qrSoundEnabled;
    _qrVibrate    = state.qrVibrateEnabled;
    _kycSound     = state.kycSoundEnabled;
    _kycVibrate   = state.kycVibrateEnabled;
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    _amtMinCtrl.dispose();
    _amtMaxCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    state.phone        = _phoneCtrl.text.trim();
    state.password     = _passwordCtrl.text;
    state.amountMin    = int.tryParse(_amtMinCtrl.text) ?? 1700;
    state.amountMax    = int.tryParse(_amtMaxCtrl.text) ?? 2000;
    state.setPaymentMode(_paymentMode);
    state.setQrAlerts(sound: _qrSound, vibrate: _qrVibrate);
    state.setKycAlerts(sound: _kycSound, vibrate: _kycVibrate);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('phone',       state.phone);
    await prefs.setString('password',    state.password);
    await prefs.setInt('amtMin',         state.amountMin);
    await prefs.setInt('amtMax',         state.amountMax);
    await prefs.setString('paymentMode', _paymentMode == PaymentMode.bank ? 'bank' : 'upi');
    await prefs.setBool('qrSound',       _qrSound);
    await prefs.setBool('qrVibrate',     _qrVibrate);
    await prefs.setBool('kycSound',      _kycSound);
    await prefs.setBool('kycVibrate',    _kycVibrate);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Settings saved',
          style: TextStyle(color: Color(0xFF0A0A0F), fontWeight: FontWeight.bold)),
        backgroundColor: _yellow,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final t = AppTheme(state.isDark);
        return Scaffold(
          backgroundColor: t.bg,
          appBar: AppBar(
            backgroundColor: t.bg,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_new_rounded, color: t.textSub, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text('Settings', style: TextStyle(
              color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
            actions: [
              GestureDetector(
                onTap: () async {
                  state.toggleTheme();
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('isDark', state.isDark);
                  await IconService.setIcon(isDark: state.isDark);
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: t.card, borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: t.border),
                  ),
                  child: Icon(
                    state.isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                    color: t.yellow, size: 18),
                ),
              ),
              GestureDetector(
                onTap: _save,
                child: Container(
                  margin: const EdgeInsets.only(right: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: t.yellow, borderRadius: BorderRadius.circular(10)),
                  child: Text('SAVE', style: TextStyle(
                    color: t.bg, fontWeight: FontWeight.bold,
                    fontSize: 13, letterSpacing: 1.0)),
                ),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(height: 0.5, color: t.border),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _SectionLabel('ACCOUNT', t),
              const SizedBox(height: 12),
              _DarkField(label: 'Phone Number', controller: _phoneCtrl,
                icon: Icons.phone_android_rounded, keyboardType: TextInputType.phone, t: t),
              const SizedBox(height: 10),
              _DarkField(
                label: 'Password', controller: _passwordCtrl,
                icon: Icons.lock_outline_rounded, obscureText: _obscurePassword, t: t,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_obscurePassword)
                      IconButton(
                        icon: Icon(Icons.copy_rounded, color: t.textDim, size: 16),
                        tooltip: 'Copy password',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _passwordCtrl.text));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('Password copied',
                              style: TextStyle(color: t.bg)),
                            backgroundColor: t.yellow,
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 2),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          ));
                        },
                      ),
                    IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: t.textDim, size: 18),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              _SectionLabel('AMOUNT RANGE (₹)', t),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _DarkField(label: 'Minimum', controller: _amtMinCtrl,
                  icon: Icons.arrow_downward_rounded, keyboardType: TextInputType.number, t: t)),
                const SizedBox(width: 10),
                Expanded(child: _DarkField(label: 'Maximum', controller: _amtMaxCtrl,
                  icon: Icons.arrow_upward_rounded, keyboardType: TextInputType.number, t: t)),
              ]),
              const SizedBox(height: 28),
              _SectionLabel('PAYMENT MODE', t),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: t.card, borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.border),
                ),
                child: Row(children: [
                  _ModeTab(label: 'OTP / UPI', subLabel: 'Cycles through UPI banks',
                    icon: Icons.currency_rupee_rounded, selected: _paymentMode == PaymentMode.upi,
                    isLeft: true, t: t, onTap: () => setState(() => _paymentMode = PaymentMode.upi)),
                  Container(width: 0.5, height: 72, color: t.border),
                  _ModeTab(label: 'Bank', subLabel: 'Direct bank transfer',
                    icon: Icons.account_balance_rounded, selected: _paymentMode == PaymentMode.bank,
                    isLeft: false, t: t, onTap: () => setState(() => _paymentMode = PaymentMode.bank)),
                ]),
              ),
              const SizedBox(height: 28),
              _SectionLabel('NOTIFICATIONS & ALERTS', t),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: t.card, borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.qr_code_scanner_rounded, color: t.yellow, size: 18),
                      const SizedBox(width: 8),
                      Text('QR READY ALERTS', style: TextStyle(
                        color: t.yellow, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                    ]),
                    const SizedBox(height: 12),
                    _AlertToggleRow(
                      title: 'Cash Sound',
                      subtitle: 'Play cash chime when QR is ready',
                      icon: Icons.volume_up_rounded,
                      value: _qrSound,
                      t: t,
                      onChanged: (v) => setState(() => _qrSound = v),
                      onTest: () => AlertService.testSound('qr'),
                    ),
                    const SizedBox(height: 10),
                    _AlertToggleRow(
                      title: 'Vibration',
                      subtitle: 'Vibrate device when QR is ready',
                      icon: Icons.vibration_rounded,
                      value: _qrVibrate,
                      t: t,
                      onChanged: (v) => setState(() => _qrVibrate = v),
                      onTest: () => AlertService.testVibrate('qr'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Divider(color: t.border, height: 1),
                    ),
                    Row(children: [
                      Icon(Icons.verified_rounded, color: t.green, size: 18),
                      const SizedBox(width: 8),
                      Text('KYC CONFIRMATION ALERTS', style: TextStyle(
                        color: t.green, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                    ]),
                    const SizedBox(height: 12),
                    _AlertToggleRow(
                      title: 'Coin Cascade Sound',
                      subtitle: 'Play coin payout chime when confirmation completes',
                      icon: Icons.volume_up_rounded,
                      value: _kycSound,
                      t: t,
                      onChanged: (v) => setState(() => _kycSound = v),
                      onTest: () => AlertService.testSound('kyc'),
                    ),
                    const SizedBox(height: 10),
                    _AlertToggleRow(
                      title: 'Vibration',
                      subtitle: 'Double pulse vibration on transaction completion',
                      icon: Icons.vibration_rounded,
                      value: _kycVibrate,
                      t: t,
                      onChanged: (v) => setState(() => _kycVibrate = v),
                      onTest: () => AlertService.testVibrate('kyc'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              _SectionLabel('INFO', t),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: t.card, borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.border),
                ),
                child: Column(children: [
                  _InfoRow(icon: Icons.currency_rupee_rounded, color: t.yellow, t: t,
                    title: 'OTP / UPI mode',
                    desc: 'Buys UPI orders using bank OTP. Starts with Supermoney, cycles through PhonePe, GPay, Paytm etc.'),
                  const SizedBox(height: 14),
                  _InfoRow(icon: Icons.account_balance_rounded, color: t.green, t: t,
                    title: 'Bank mode',
                    desc: 'Buys bank transfer orders using direct bank transfer.'),
                  const SizedBox(height: 14),
                  _InfoRow(icon: Icons.info_outline_rounded, color: t.textSub, t: t,
                    title: 'On success',
                    desc: 'When an order is claimed, the QR payment screen appears in the WebView.'),
                ]),
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }
}

// ── Section label ──────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text;
  final AppTheme t;
  const _SectionLabel(this.text, this.t);
  @override
  Widget build(BuildContext context) {
    return Text(text, style: TextStyle(
      color: t.textSub, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5));
  }
}

// ── Dark input field ───────────────────────────────────────────────────────────
class _DarkField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final IconData icon;
  final TextInputType keyboardType;
  final bool obscureText;
  final Widget? suffixIcon;
  final AppTheme t;

  const _DarkField({
    required this.label, required this.controller,
    required this.icon, required this.t,
    this.keyboardType = TextInputType.text,
    this.obscureText = false, this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border),
      ),
      child: TextField(
        controller: controller, keyboardType: keyboardType, obscureText: obscureText,
        style: TextStyle(color: t.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: t.textSub, fontSize: 13),
          prefixIcon: Icon(icon, color: t.textDim, size: 18),
          suffixIcon: suffixIcon,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }
}

// ── Mode tab ───────────────────────────────────────────────────────────────────
class _ModeTab extends StatelessWidget {
  final String label, subLabel;
  final IconData icon;
  final bool selected, isLeft;
  final AppTheme t;
  final VoidCallback onTap;

  const _ModeTab({required this.label, required this.subLabel, required this.icon,
    required this.selected, required this.isLeft, required this.t, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: selected ? t.yellowDim : Colors.transparent,
            borderRadius: BorderRadius.horizontal(
              left: isLeft ? const Radius.circular(13) : Radius.zero,
              right: isLeft ? Radius.zero : const Radius.circular(13),
            ),
            border: selected
                ? Border.all(color: t.yellow.withValues(alpha: 0.4))
                : Border.all(color: Colors.transparent),
          ),
          child: Column(children: [
            Icon(icon, color: selected ? t.yellow : t.textDim, size: 20),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(
              color: selected ? t.yellow : t.textSub,
              fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 3),
            Text(subLabel, style: TextStyle(
              color: selected ? t.yellow.withValues(alpha: 0.5) : t.textDim,
              fontSize: 9)),
          ]),
        ),
      ),
    );
  }
}

// ── Info row ───────────────────────────────────────────────────────────────────
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, desc;
  final AppTheme t;

  const _InfoRow({required this.icon, required this.color,
    required this.title, required this.desc, required this.t});

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: color, size: 16),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(
          color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(desc, style: TextStyle(color: t.textSub, fontSize: 12, height: 1.4)),
      ])),
    ]);
  }
}

// ── Alert toggle row ───────────────────────────────────────────────────────────
class _AlertToggleRow extends StatelessWidget {
  final String title, subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;
  final VoidCallback onTest;
  final AppTheme t;

  const _AlertToggleRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
    required this.onTest,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: t.yellow.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: t.yellow, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(
                color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(
                color: t.textSub, fontSize: 10)),
            ],
          ),
        ),
        GestureDetector(
          onTap: onTest,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: t.border),
            ),
            child: Text('TEST', style: TextStyle(
              color: t.yellow, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
          ),
        ),
        const SizedBox(width: 8),
        Switch(
          value: value,
          activeThumbColor: t.yellow,
          activeTrackColor: t.yellowDim,
          inactiveThumbColor: t.textDim,
          inactiveTrackColor: t.surface,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

