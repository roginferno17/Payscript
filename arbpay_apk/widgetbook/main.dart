import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:arbpay_bot/models/app_state.dart';
import 'package:arbpay_bot/theme/app_theme.dart';
import 'package:arbpay_bot/widgets/log_panel.dart';
import 'package:arbpay_bot/widgets/status_card.dart';
import 'package:arbpay_bot/screens/home_screen.dart';
import 'package:arbpay_bot/screens/settings_screen.dart';

void main() {
  runApp(const WidgetbookApp());
}

// ── Fake AppState with sample data ────────────────────────────────────────────
AppState _fakeState({
  BotStatus status = BotStatus.running,
  bool isDark = true,
  int rounds = 12,
  int success = 3,
  String order = 'ORD-20240518-001',
  List<LogEntry>? logs,
}) {
  final state = AppState();
  state.setStatus(status);
  if (!isDark) state.toggleTheme();
  for (var i = 0; i < rounds; i++) {
    state.incrementRounds();
  }
  for (var i = 0; i < success; i++) {
    state.incrementSuccess();
  }
  state.setCurrentOrder(order);

  final sampleLogs = logs ??
      [
        LogEntry(time: '12:01:05', message: 'Bot started successfully', level: LogLevel.success),
        LogEntry(time: '12:01:04', message: 'Cloudflare challenge detected', level: LogLevel.warning),
        LogEntry(time: '12:01:03', message: 'Connecting to ARBPay...', level: LogLevel.info),
        LogEntry(time: '12:01:02', message: 'Login failed — retrying', level: LogLevel.error),
        LogEntry(time: '12:01:01', message: 'Session token captured', level: LogLevel.success),
      ];
  for (final log in sampleLogs.reversed) {
    state.addLog(log.message, level: log.level);
  }
  return state;
}

// ── Helper: wrap a widget with Provider<AppState> ─────────────────────────────
Widget _withState(Widget child, {AppState? state}) {
  return ChangeNotifierProvider<AppState>.value(
    value: state ?? _fakeState(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      home: child,
    ),
  );
}

// ── Widgetbook app ─────────────────────────────────────────────────────────────
class WidgetbookApp extends StatelessWidget {
  const WidgetbookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Widgetbook.material(
      addons: [
        ViewportAddon([
          Viewports.none,
          ...AndroidViewports.phones,
          ...IosViewports.phones,
        ]),
        ThemeAddon(
          themes: [
            WidgetbookTheme(name: 'Dark', data: _buildTheme(isDark: true)),
            WidgetbookTheme(name: 'Light', data: _buildTheme(isDark: false)),
          ],
          themeBuilder: (context, theme, child) => Theme(data: theme, child: child),
        ),
        TextScaleAddon(min: 0.8, max: 1.4),
      ],
      directories: [
        WidgetbookCategory(
          name: 'Screens',
          children: [
            WidgetbookComponent(
              name: 'Home Screen',
              useCases: [
                WidgetbookUseCase(
                  name: 'Running — Dark',
                  builder: (_) => _withState(
                    const HomeScreen(),
                    state: _fakeState(status: BotStatus.running, isDark: true),
                  ),
                ),
                WidgetbookUseCase(
                  name: 'Running — Light',
                  builder: (_) => _withState(
                    const HomeScreen(),
                    state: _fakeState(status: BotStatus.running, isDark: false),
                  ),
                ),
                WidgetbookUseCase(
                  name: 'Idle',
                  builder: (_) => _withState(
                    const HomeScreen(),
                    state: _fakeState(
                        status: BotStatus.idle, rounds: 0, success: 0, order: ''),
                  ),
                ),
                WidgetbookUseCase(
                  name: 'QR Ready',
                  builder: (_) => _withState(
                    const HomeScreen(),
                    state: _fakeState(status: BotStatus.qrReady),
                  ),
                ),
                WidgetbookUseCase(
                  name: 'Error',
                  builder: (_) => _withState(
                    const HomeScreen(),
                    state: _fakeState(status: BotStatus.error),
                  ),
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'Settings Screen',
              useCases: [
                WidgetbookUseCase(
                  name: 'Dark',
                  builder: (_) => _withState(
                    const SettingsScreen(),
                    state: _fakeState(isDark: true),
                  ),
                ),
                WidgetbookUseCase(
                  name: 'Light',
                  builder: (_) => _withState(
                    const SettingsScreen(),
                    state: _fakeState(isDark: false),
                  ),
                ),
              ],
            ),
          ],
        ),
        WidgetbookCategory(
          name: 'Widgets',
          children: [
            WidgetbookComponent(
              name: 'Log Panel',
              useCases: [
                WidgetbookUseCase(
                  name: 'Dark — with logs',
                  builder: (_) => _withState(
                    const SizedBox(height: 300, child: LogPanel(t: AppTheme(true))),
                    state: _fakeState(isDark: true),
                  ),
                ),
                WidgetbookUseCase(
                  name: 'Light — with logs',
                  builder: (_) => _withState(
                    const SizedBox(height: 300, child: LogPanel(t: AppTheme(false))),
                    state: _fakeState(isDark: false),
                  ),
                ),
                WidgetbookUseCase(
                  name: 'Empty',
                  builder: (_) => _withState(
                    const SizedBox(height: 300, child: LogPanel(t: AppTheme(true))),
                    state: _fakeState(logs: []),
                  ),
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'Status Card',
              useCases: [
                for (final status in BotStatus.values)
                  WidgetbookUseCase(
                    name: status.name,
                    builder: (_) => _withState(
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: StatusCard(),
                      ),
                      state: _fakeState(status: status),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  ThemeData _buildTheme({required bool isDark}) {
    final t = AppTheme(isDark);
    return ThemeData(
      brightness: isDark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: t.bg,
      colorScheme: ColorScheme(
        brightness: isDark ? Brightness.dark : Brightness.light,
        primary: t.yellow,
        onPrimary: t.bg,
        secondary: t.yellow,
        onSecondary: t.bg,
        error: t.red,
        onError: Colors.white,
        surface: t.surface,
        onSurface: t.textPrimary,
      ),
    );
  }
}
