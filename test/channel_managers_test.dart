import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/host/media_data_manager.dart';
import 'package:androiddex_host/host/notification_data_manager.dart';

void main() {
  test('media channel accepts the hello handshake and sessions', () {
    final manager = MediaDataManager();
    addTearDown(manager.dispose);

    manager.apply({'type': 'media.hello'});
    expect(manager.connected, isTrue);
    expect(manager.hasSession, isFalse);

    manager.apply({
      'type': 'media_update',
      'media': {
        'package': 'com.spotify.music',
        'title': 'Midnight City',
        'artist': 'M83',
        'playing': true,
        'position': 61000,
        'duration': 243000,
      },
    });
    expect(manager.hasSession, isTrue);
    final session = manager.current!;
    expect(session.title, 'Midnight City');
    expect(session.subtitle, 'M83');
    expect(session.playing, isTrue);
    expect(session.progress, closeTo(61000 / 243000, 0.0001));

    // A bare pause keeps the metadata.
    manager.apply({'type': 'media_update', 'playing': false});
    expect(manager.current!.title, 'Midnight City');
    expect(manager.current!.playing, isFalse);

    // Unknown payloads are ignored, never fatal.
    manager.apply({'noise': true});
    expect(manager.current!.title, 'Midnight City');
  });

  test('notification channel rings a bounded, grouped list', () {
    final manager = NotificationDataManager();
    addTearDown(manager.dispose);

    manager.apply({'type': 'notification.hello'});
    expect(manager.connected, isTrue);

    manager.apply({
      'type': 'notification.posted',
      'notification': {
        'key': '0|com.example|1',
        'package': 'com.example',
        'app_name': 'Example',
        'title': 'Hello',
        'text': 'World',
        'timestamp': 1750000000000,
      },
    });
    expect(manager.unreadCount, 1);
    expect(manager.byPackage.keys, ['com.example']);

    // A resend of the same key replaces instead of duplicating.
    manager.apply({
      'type': 'notification.posted',
      'key': '0|com.example|1',
      'package': 'com.example',
      'title': 'Hello again',
    });
    expect(manager.unreadCount, 1);
    expect(manager.items.first.title, 'Hello again');

    manager.apply({'type': 'notification.removed', 'key': '0|com.example|1'});
    expect(manager.isEmpty, isTrue);

    manager.apply({'type': 'notification.clear_all'});
    expect(manager.isEmpty, isTrue);
  });

  test('identical notification refreshes do not trigger listener churn', () {
    final manager = NotificationDataManager();
    addTearDown(manager.dispose);

    var changes = 0;
    manager.addListener(() => changes++);

    final notification = DexNotification(
      key: '0|com.google.android.aicore|253',
      packageName: 'com.google.android.aicore',
      appName: 'Android AICore',
      title: 'feature_253',
      text: 'Waiting for WiFi connection',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
      ongoing: true,
    );
    manager.push(notification);
    manager.push(
      DexNotification(
        key: notification.key,
        packageName: notification.packageName,
        appName: notification.appName,
        title: notification.title,
        text: notification.text,
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
        ongoing: notification.ongoing,
      ),
    );

    expect(changes, 1);
    expect(manager.unreadCount, 1);
  });

  test('notification bulk resends populate the stream', () {
    final manager = NotificationDataManager();
    addTearDown(manager.dispose);

    manager.apply({
      'type': 'notification.resend',
      'notifications': [
        {'key': 'a', 'package': 'com.a', 'title': 'A'},
        {'key': 'b', 'package': 'com.b', 'title': 'B'},
      ],
    });
    expect(manager.unreadCount, 2);
    expect(manager.byPackage.keys, containsAll(['com.a', 'com.b']));
  });
}
