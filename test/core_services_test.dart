import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/services/device_manager.dart';
import 'package:androiddex_host/services/window_manager.dart';

void main() {
  test('device manager resolves USB, Wi-Fi and selection flows', () async {
    List<String> seen = const [];
    final devices = DeviceManager(
      runner: (args) async {
        seen = args;
        if (args.first == 'devices') {
          return const AdbResult(
            true,
            'List of devices attached\n'
            'USB123\tdevice product:pixel\n'
            '192.168.1.20:5555\tdevice\n',
          );
        }
        return const AdbResult(true, 'already connected to 192.168.1.20:5555');
      },
    );
    addTearDown(devices.dispose);

    await devices.autoDetect();
    expect(devices.needsDeviceSelection, isTrue);
    expect(devices.deviceId, 'USB123');
    expect(devices.devices, hasLength(2));
    expect(devices.devices.first.label, 'USB Device');
    expect(devices.devices.last.isWifi, isTrue);
    expect(seen.first, 'devices');

    devices.selectDevice('USB123');
    expect(devices.needsDeviceSelection, isFalse);
    expect(devices.deviceId, DeviceManager.usbSelector);
    expect(devices.adbArgs, [DeviceManager.usbSelector]);

    devices.selectDevice('192.168.1.20:5555');
    expect(devices.isWifi, isTrue);
    expect(devices.adbArgs, ['-s', '192.168.1.20:5555']);
  });

  test('device manager parses CLI args and normalises IPs', () async {
    final devices = DeviceManager(
      runner: (_) async => const AdbResult(true, ''),
    );
    addTearDown(devices.dispose);

    devices.setFromArgs(['--usb']);
    expect(devices.deviceId, DeviceManager.usbSelector);

    devices.setFromArgs(['192.168.1.5']);
    expect(devices.deviceId, '192.168.1.5:5555');

    devices.setFromArgs(['192.168.1.5:6666']);
    expect(devices.deviceId, '192.168.1.5:6666');

    expect(await devices.connectIp(''), 'Enter a valid IP address');
  });

  test('window manager keeps a single focus order with tiling', () {
    const desktop = Size(1280, 720);
    final windows = WindowManager();
    addTearDown(windows.dispose);

    DesktopAppWindow app(String package) => DesktopAppWindow(
      app: AndroidAppInfo(
        name: package,
        packageName: package,
        versionName: '',
        iconBase64: '',
      ),
      startedAt: DateTime(2026),
      processId: package.hashCode,
    );

    final first = windows.open(
      app('com.first'),
      origin: const Offset(10, 10),
      extent: const Size(400, 300),
    );
    windows.open(
      app('com.second'),
      origin: const Offset(60, 60),
      extent: const Size(400, 300),
    );
    expect(windows.focusedPackage, 'com.second');
    expect(windows.ordered.last, isNot(windows.ordered.first));

    windows.focus('com.first');
    expect(windows.focusedPackage, 'com.first');

    windows.cycleFocus();
    expect(windows.focusedPackage, 'com.second');

    windows.snap('com.second', WindowSnap.left, desktop);
    expect(first.packageName, 'com.first');
    final snapped = windows.forPackage('com.second')!;
    expect(snapped.snap, WindowSnap.left);
    expect(snapped.extent.width, 640);
    expect(snapped.origin, Offset.zero);

    // Reopening a focused app is a focus, not a second entry.
    windows.open(
      app('com.first'),
      origin: Offset.zero,
      extent: const Size(10, 10),
    );
    expect(windows.length, 2);
    expect(windows.focusedPackage, 'com.first');

    windows.minimize('com.first');
    expect(windows.forPackage('com.first')!.minimized, isTrue);
    windows.restore('com.first');
    expect(windows.forPackage('com.first')!.minimized, isFalse);

    windows.close('com.first');
    expect(windows.isOpen('com.first'), isFalse);
    expect(windows.length, 1);
  });

  test('boot error publishes a renderable change', () {
    final core = AndroidCore();
    addTearDown(core.dispose);

    var notified = 0;
    core.addListener(() => notified++);

    core.setBootError('Companion app timed out.', canPickDevice: true);
    expect(core.bootError.value, isTrue);
    expect(core.bootErrorMessage.value, 'Companion app timed out.');
    expect(core.canPickDevice.value, isTrue);
    expect(notified, greaterThan(0));

    // A reset publishes the change as well, so a retry redraws clean.
    core.clearBootError();
    expect(core.bootError.value, isFalse);
    expect(core.canPickDevice.value, isFalse);
  });
}
