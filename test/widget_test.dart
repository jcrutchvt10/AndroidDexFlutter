import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/app.dart';

void main() {
  testWidgets('AndroidDexHost smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AndroidDexHostApp());
    expect(find.text('Starting Android DEX'), findsOneWidget);
  });
}
