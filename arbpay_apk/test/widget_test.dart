import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:arbpay_bot/main.dart';
import 'package:arbpay_bot/models/app_state.dart';

void main() {
  testWidgets('App initialization smoke test', (WidgetTester tester) async {
    final state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ArbPayApp(),
      ),
    );
    expect(find.text('ARBPay Bot'), findsWidgets);
  });
}
