import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/home/notification_toast_overlay.dart';
import 'package:androiddex_host/host/notification_data_manager.dart';

void main() {
  testWidgets(
    'ongoing notifications do not toast and refreshes do not resurrect expired toasts',
    (tester) async {
      final core = AndroidCore();
      core.notifications.markConnected();
      final bridge = NotificationToastBridge(core);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [NotificationToastOverlay(core: core, bridge: bridge)],
            ),
          ),
        ),
      );

      core.notifications.push(
        DexNotification(
          key: '0|com.google.android.aicore|253',
          packageName: 'com.google.android.aicore',
          appName: 'Android AICore',
          title: 'feature_253',
          text: 'Waiting for WiFi connection',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          ongoing: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('feature_253'), findsNothing);

      core.notifications.push(
        DexNotification(
          key: 'message-1',
          packageName: 'com.example.messages',
          appName: 'Messages',
          title: 'Hello',
          text: 'First message',
          timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
          ongoing: false,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Hello'), findsNothing);

      core.notifications.push(
        DexNotification(
          key: 'message-1',
          packageName: 'com.example.messages',
          appName: 'Messages',
          title: 'Hello',
          text: 'Updated message',
          timestamp: DateTime.fromMillisecondsSinceEpoch(3000),
          ongoing: false,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Hello'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      bridge.dispose();
      core.dispose();
    },
  );

  testWidgets(
    'refreshing a still-visible toast restarts its auto-dismiss countdown',
    (tester) async {
      final core = AndroidCore();
      core.notifications.markConnected();
      final bridge = NotificationToastBridge(core);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [NotificationToastOverlay(core: core, bridge: bridge)],
            ),
          ),
        ),
      );

      DexNotification progress(int percent) => DexNotification(
        key: 'download-1',
        packageName: 'com.example.downloads',
        appName: 'Downloads',
        title: 'Downloading',
        text: '$percent%',
        timestamp: DateTime.fromMillisecondsSinceEpoch(4000 + percent),
        ongoing: false,
      );

      core.notifications.push(progress(10));
      await tester.pump();
      await tester.pump();
      expect(find.text('10%'), findsOneWidget);

      // Let most of the 6s window elapse, then refresh in place. Without a
      // countdown reset the toast would vanish on the original timer despite
      // still receiving fresh content.
      await tester.pump(const Duration(seconds: 5));
      core.notifications.push(progress(80));
      await tester.pump();
      await tester.pump();
      expect(find.text('80%'), findsOneWidget);

      // The original deadline has now passed, but the refresh bought a fresh
      // one: the toast is still up.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('80%'), findsOneWidget);

      // And it does eventually expire, rather than lingering forever.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('80%'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      bridge.dispose();
      core.dispose();
    },
  );
}
