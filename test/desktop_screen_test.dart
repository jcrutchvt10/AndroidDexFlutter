import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/home/desktop_screen.dart';

void main() {
  for (final size in [const Size(1280, 720), const Size(720, 600)]) {
    testWidgets('desktop panels work at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = AndroidCore();
      await tester.pumpWidget(MaterialApp(home: DesktopScreen(core: core)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Apps'));
      await tester.pump();
      expect(find.text('No apps found'), findsOneWidget);
      await tester.tap(find.byTooltip('Close panel'));
      await tester.pump();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pump();
      expect(find.text('Desktop wallpaper'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      core.dispose();
    });
  }
}
