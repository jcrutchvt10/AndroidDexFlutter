import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/core/android_core_messages.dart';

void main() {
  test('parses the flat battery_small payload used by AndroidDex.apk v1.2', () {
    final message = AndroidCoreMessage.fromJson({
      'type': 'battery_small',
      'device_id': 'phone-1',
      'percentage': 87,
      'charging': true,
      'plugged': 2,
      'battery_saver': false,
      'states': {'wifi': true, 'bluetooth': false},
    });

    expect(message.type, AndroidCoreMessageType.batterySmall);
    expect(message.batterySmall?.percentage, 87);
    expect(message.states?.single.wifi, isTrue);

    final core = AndroidCore();
    addTearDown(core.dispose);
    core.updateFromMessage(message);
    expect(core.batteryPercentage, 87);
    expect(core.batteryCharging, isTrue);
    expect(core.wifi, isTrue);
  });

  test('parses flat permission reports and handshake messages', () {
    final permissions = AndroidCoreMessage.fromJson({
      'type': 'apk.permissions',
      'level': 'warning',
      'message': 'Some permissions are not granted',
      'timestamp': 123,
      'data': {'READ_CONTACTS': true, 'CALL_PHONE': false},
    });
    final hello = AndroidCoreMessage.fromJson({
      'type': 'apk.hello',
      'status': 'ready',
      'version': '1.2',
    });

    expect(permissions.apkPermissions?.level, 'warning');
    expect(permissions.apkPermissions?.data?['CALL_PHONE'], isFalse);
    expect(hello.type, AndroidCoreMessageType.apkHello);
  });

  test('keeps unmodeled v1.2 events parseable', () {
    final message = AndroidCoreMessage.fromJson({
      'type': 'app.count',
      'count': 42,
    });
    expect(message.type, AndroidCoreMessageType.unknown);
  });

  test('parses app-list entries returned by the APK channel', () {
    final app = AndroidAppInfo.fromJson({
      'app_name': 'Camera',
      'package_name': 'com.example.camera',
      'version_name': '2.1',
      'icon_base64': 'aWNvbg==',
    });

    expect(app.name, 'Camera');
    expect(app.packageName, 'com.example.camera');
    expect(app.versionName, '2.1');
  });
}
