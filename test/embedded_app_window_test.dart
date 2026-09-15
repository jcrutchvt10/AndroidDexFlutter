import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/home/embedded_app_window.dart';

void main() {
  testWidgets('attaches native surface and repositions it when frame moves', (tester) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('androiddex/windows');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'embed' ? true : null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    var closed = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [
      EmbeddedAppWindow(window: DesktopAppWindow(app: const AndroidAppInfo(name: 'Test app', packageName: 'test.app', versionName: '', iconBase64: ''),
        startedAt: DateTime(2026), processId: 123), bounds: const Size(800, 600), onClose: () => closed = true),
    ]))));
    await tester.pump();
    expect(calls.where((call) => call.method == 'embed'), isNotEmpty);
    final args = calls.first.arguments as Map;
    expect(args['process_id'], 123);
    expect(args['width'], greaterThan(0));
    await tester.drag(find.text('Test app'), const Offset(20, 15));
    await tester.pump();
    expect(calls.where((call) => call.method == 'position'), isNotEmpty);
    await tester.tap(find.byTooltip('Close app window'));
    expect(closed, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
