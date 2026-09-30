import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/home/embedded_app_window.dart';

void main() {
  testWidgets('attaches native surface and repositions it when frame moves', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('androiddex/windows');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'embed' ? true : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final core = AndroidCore();
    addTearDown(core.dispose);
    final managed = core.windows.open(
      DesktopAppWindow(
        app: const AndroidAppInfo(
          name: 'Test app',
          packageName: 'test.app',
          versionName: '',
          iconBase64: '',
        ),
        startedAt: DateTime(2026),
        processId: 123,
      ),
      origin: const Offset(10, 10),
      extent: const Size(400, 300),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              EmbeddedAppWindow(
                core: core,
                managed: managed,
                desktop: const Size(800, 600),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(calls.where((call) => call.method == 'embed'), isNotEmpty);
    final embed =
        calls.firstWhere((call) => call.method == 'embed').arguments as Map;
    expect(embed['process_id'], 123);
    expect(embed['width'], greaterThan(0));
    // A real drag exceeds the pan slop (kPanSlop = 36) and then delivers
    // onPanUpdate deltas. tester.drag(Offset(20, 15)) only trips onPanStart,
    // so drive the gesture manually: the first move is consumed by the
    // recognizer crossing slop, the second is a pure update the window must
    // follow with a position call to the runner.
    final drag = await tester.startGesture(
      tester.getCenter(find.text('Test app')),
    );
    await drag.moveBy(const Offset(60, 45));
    await tester.pump();
    await drag.moveBy(const Offset(10, 10));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(
      managed.origin,
      isNot(const Offset(10, 10)),
      reason: 'title-bar drag must move the window',
    );
    final position =
        calls.lastWhere((call) => call.method == 'position').arguments as Map;
    expect(position['x'], greaterThan(embed['x'] as num));
    expect(position['y'], greaterThan(embed['y'] as num));

    // The hardware buttons drive real ADB paths; assert the window contract
    // instead: minimum mount, focus/restoration repaints, minimize hides.
    core.windows.focus(managed.packageName);
    await tester.pump();
    expect(find.text('Test app'), findsOneWidget);
    core.windows.minimize(managed.packageName);
    await tester.pump();
    expect(find.text('Test app'), findsNothing);

    // Let the DoubleTapGestureRecognizer's 40 ms countdown expire before
    // tearing the tree down, otherwise the test framework's invariant check
    // fails on a pending fake-async timer.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox());
  });
}
