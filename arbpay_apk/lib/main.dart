import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/app_state.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';
import 'services/icon_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  final prefs = await SharedPreferences.getInstance();
  final state = AppState();
  state.phone       = prefs.getString('phone')    ?? '';
  state.password    = prefs.getString('password') ?? '';
  state.amountMin   = prefs.getInt('amtMin')      ?? 1700;
  state.amountMax   = prefs.getInt('amtMax')      ?? 2000;
  state.paymentMode = (prefs.getString('paymentMode') == 'bank')
      ? PaymentMode.bank : PaymentMode.upi;
  state.isDark      = prefs.getBool('isDark') ?? true;
  state.qrSoundEnabled   = prefs.getBool('qrSound')   ?? true;
  state.qrVibrateEnabled = prefs.getBool('qrVibrate') ?? true;
  state.kycSoundEnabled   = prefs.getBool('kycSound')   ?? true;
  state.kycVibrateEnabled = prefs.getBool('kycVibrate') ?? true;

  // Sync launcher icon with saved theme on startup
  await IconService.setIcon(isDark: state.isDark);

  runApp(ChangeNotifierProvider.value(value: state, child: const ArbPayApp()));
}

class ArbPayApp extends StatelessWidget {
  const ArbPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        // Single source of truth — ThemeData is derived from AppTheme,
        // no duplicate color definitions anywhere.
        return MaterialApp(
          title: 'ARBPay Bot',
          debugShowCheckedModeBanner: false,
          themeMode: state.isDark ? ThemeMode.dark : ThemeMode.light,
          darkTheme: const AppTheme(true).toThemeData(),
          theme: const AppTheme(false).toThemeData(),
          home: const HomeScreen(),
        );
      },
    );
  }
}
