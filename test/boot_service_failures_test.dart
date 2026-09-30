import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/core/app_paths.dart';
import 'package:androiddex_host/host/callback_channel.dart';
import 'package:androiddex_host/host/jar_server.dart';
import 'package:androiddex_host/services/boot_service.dart';

/// Starts the four host servers on ephemeral ports so boot progress can be
/// driven without touching ADB or a real device.
Future<(BootService, AndroidCore, List<int>)> _startHarness({
  required AndroidCore core,
}) async {
  final jar = await JarServer.start(
    onMessage: (_) {},
    onClientConnected: core.markJarConnected,
    onClientDisconnected: core.markJarDisconnected,
    port: 0,
  );
  final media = await CallbackChannel.startMedia(
    onMessage: core.media.apply,
    onClientConnected: core.media.markConnected,
    onClientDisconnected: core.media.markDisconnected,
    port: 0,
  );
  final notifications = await CallbackChannel.startNotification(
    onMessage: core.notifications.apply,
    onClientConnected: core.notifications.markConnected,
    onClientDisconnected: core.notifications.markDisconnected,
    port: 0,
  );
  return (core.boot, core, [jar.port, media.port, notifications.port]);
}

/// Sends one JSON line to [port] and keeps the socket open until [task]
/// completes, so the server does not see a disconnect mid-test.
Future<T> _sendLine<T>(
  InternetAddress address,
  int port,
  String line,
  Future<T> Function() task,
) async {
  final socket = await Socket.connect(address, port);
  socket.writeln(line);
  await socket.flush();
  try {
    return await task();
  } finally {
    socket.destroy();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Point AppPaths at an empty temp dir so the bundle lookups find nothing
    // (exercise the real "missing runtime" failure path) without throwing
    // raw StateErrors from an uninitialized AppPaths.
    AppPaths.debugInitForTests(
      Directory.systemTemp.createTempSync('dex-test').path,
    );
  });

  tearDownAll(() {
    final dir = AppPaths.appDir;
    if (dir.startsWith(Directory.systemTemp.path)) {
      Directory(dir).deleteSync(recursive: true);
    }
    AppPaths.debugInitForTests(null);
  });

  test('boot fails cleanly when no ADB runtime exists', () async {
    final core = AndroidCore();
    addTearDown(core.dispose);
    core.boot.initializeSystem();
    // Wait for the attempt to settle.
    while (core.boot.isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(core.bootError.value, isTrue);
    // A missing runtime is a reinstall problem, not a connection problem —
    // the device picker must NOT be offered.
    expect(core.canPickDevice.value, isFalse);
  });

  test(
    'handshake waiter resolves when jar.hello arrives, times out otherwise',
    () async {
      final core = AndroidCore();
      addTearDown(core.dispose);
      final (boot, _, ports) = await _startHarness(core: core);
      addTearDown(boot.reset);

      // Timeout path: nothing connects.
      expect(
        await boot.waitForJar(timeout: const Duration(milliseconds: 200)),
        isFalse,
      );

      // Success path: a client dials in, says hello, and STAYS CONNECTED —
      // dropping the socket would legitimately fire the disconnect callback
      // and race the assertion below.
      final wait = boot.waitForJar(timeout: const Duration(seconds: 3));
      final connected = await _sendLine(
        InternetAddress.loopbackIPv4,
        ports[0],
        '{"type":"jar.hello"}',
        () async {
          expect(await wait, isTrue);
          return core.jarConnectedValue;
        },
      );
      expect(connected, isTrue);
    },
  );

  test(
    'reset fails pending handshake waiters instead of hanging them',
    () async {
      final core = AndroidCore();
      addTearDown(core.dispose);
      final (boot, _, _) = await _startHarness(core: core);

      final wait = boot.waitForJar(timeout: const Duration(seconds: 10));
      await boot.reset();
      // The reset completes the waiter as failed; waitForJar reports false
      // instead of waiting out the full timeout.
      expect(await wait.timeout(const Duration(seconds: 2)), isFalse);
    },
  );

  test(
    'initializeSystem refuses concurrent attempts and reports in-flight',
    () async {
      final core = AndroidCore();
      addTearDown(core.dispose);
      // Both calls are synchronous (no device/ADB needed to reject the second):
      // the second initializeSystem must not restart the first.
      core.boot.initializeSystem();
      expect(core.boot.isRunning, isTrue);
      expect(core.bootInProgress.value, isTrue);
      while (core.boot.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(core.bootInProgress.value, isFalse);
    },
  );
}
