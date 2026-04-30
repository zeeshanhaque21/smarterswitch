import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/main.dart';

void main() {
  testWidgets('app boots to the Pair screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SmarterSwitchApp()));
    await tester.pumpAndSettle();
    expect(find.text('SmarterSwitch'), findsOneWidget);
    expect(find.text('OLD phone'), findsOneWidget);
    expect(find.text('NEW phone'), findsOneWidget);
  });
}
