import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/core/app_paths.dart';
import 'package:androiddex_host/host/android_core_messages.dart'
    show AndroidCoreMessage, AndroidCoreMessageType;
import 'package:androiddex_host/host/jar_server.dart';
import 'package:androiddex_host/host/apk_server.dart';
import 'package:androiddex_host/host/media_server.dart';
import 'package:androiddex_host/host/notification_server.dart';

const androidDexPackage = 'com.shrey.androiddex';
const androidDexService =
    'com.shrey.androiddex/.init_start_server.ServerStartService';
const androidDexJarMainClass = 'com.shrey.androiddex.server.Main';
// Port 8457 is intentionally absent: AndroidDex.apk binds it locally so the
// on-device JAR can forward commands to the APK.
const androidDexReversePorts = <int>[3698, 3699, 3700, 3701];

List<String> parseConnectedAdbDevices(String output) {
  final devices = <String>[];
  for (final line in const LineSplitter().convert(output)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1] == 'device') {
      devices.add(parts[0]);
    }
  }
  return devices;
}

List<List<String>> buildAdbReverseCommands(String serial) => [
  for (final port in androidDexReversePorts)
    ['-s', serial, 'reverse', 'tcp:$port', 'tcp:$port'],
];

class BootService {
  BootService(this.core);

  final AndroidCore core;

  JarServer? _jarServer;
  ApkServer? _apkServer;
  MediaServer? _mediaServer;
  NotificationServer? _notificationServer;
  Process? _jarProcess;
  final Map<String, Completer<Map<String, dynamic>>> _apkRequests = {};
  final Map<String, Completer<Map<String, dynamic>>> _jarRequests = {};
  int _nextRequestId = 0;

  JarServer? get jarServer => _jarServer;
  ApkServer? get apkServer => _apkServer;
  MediaServer? get mediaServer => _mediaServer;
  NotificationServer? get notificationServer => _notificationServer;

  Future<void> initializeSystem() async {
    try {
      core.updateAppProgress(0.02, 'Starting ADB server…');
      await _startAdbServer();

      core.updateAppProgress(0.10, 'Connecting to Android device…');
      final device = await _selectDevice();
      if (device == null) {
        core.setBootError('No Android device available.');
        return;
      }
      await _forwardPorts(device);

      core.updateAppProgress(
        0.20,
        'Device connected — network bridge configured',
      );
      core.updateAppProgress(0.28, 'Starting local communication servers…');
      await _startHostServers();

      core.updateAppProgress(
        0.38,
        'Deploying service module to Android device…',
      );
      await _deployJar(device);
      await _startJarRuntime(device);

      core.updateAppProgress(0.55, 'Verifying companion app on device…');
      final installed = await _isPackageInstalled(device);
      if (!installed) {
        core.updateAppProgress(
          0.65,
          'Companion app not found — installing now…',
        );
        await _installApk(device);
      }

      core.updateAppProgress(0.72, 'Launching Android companion services…');
      await _startServerService(device);

      core.updateAppProgress(
        0.84,
        'Waiting for background service to connect…',
      );
      final jarOk = await _waitForJarHandshake();
      if (!jarOk) {
        core.setBootError(
          'Background service timed out. The device may be busy or unreachable.',
        );
        return;
      }

      core.updateAppProgress(0.93, 'Waiting for companion app to connect…');
      final apkOk = await _waitForApkHandshake();
      if (!apkOk) {
        core.setBootError(
          'Companion app timed out. Ensure it is installed and running on the device.',
        );
        return;
      }

      core.updateAppProgress(
        0.97,
        'Activating media and notification services…',
      );
      await _startExtendedServices();

      core.updateAppProgress(1.00, 'System ready');
      core.setBootFinished();
    } catch (error) {
      core.setBootError('$error');
    }
  }

  Future<void> _startAdbServer() async {
    final adb = AppPaths.adbExe;
    if (!await adb.exists()) {
      throw Exception('adb.exe not found at ${adb.path}');
    }
    final result = await Process.run(adb.path, [
      'start-server',
    ], workingDirectory: adb.parent.path);
    if (result.exitCode != 0) {
      throw Exception('Unable to start ADB: ${result.stderr}');
    }
  }

  Future<String?> _selectDevice() async {
    final adb = AppPaths.adbExe;
    final result = await Process.run(adb.path, [
      'devices',
    ], workingDirectory: adb.parent.path);
    if (result.exitCode != 0) {
      throw Exception('Unable to list Android devices: ${result.stderr}');
    }
    final devices = parseConnectedAdbDevices(result.stdout as String);
    if (devices.length > 1) {
      throw Exception(
        'Multiple Android devices are connected. Disconnect all but one and retry.',
      );
    }
    return devices.isEmpty ? null : devices.single;
  }

  Future<void> _forwardPorts(String serial) async {
    final adb = AppPaths.adbExe;
    // Clean up mappings produced by older host builds. The APK owns this port
    // on Android and cannot start its local command bridge while it is reversed.
    await Process.run(adb.path, [
      '-s',
      serial,
      'reverse',
      '--remove',
      'tcp:8457',
    ], workingDirectory: adb.parent.path);
    for (final args in buildAdbReverseCommands(serial)) {
      final result = await Process.run(
        adb.path,
        args,
        workingDirectory: adb.parent.path,
      );
      if (result.exitCode != 0) {
        throw Exception(
          'adb reverse failed for ${args.last}: ${result.stderr}',
        );
      }
    }
  }

  Future<void> _startHostServers() async {
    _jarServer = await JarServer.start(
      onMessage: _onJarMessage,
      onClientConnected: () {
        core.markJarConnected();
        core.updateJarProgress(1, 'Service connected — handshake confirmed');
      },
      onClientDisconnected: () {
        core.markJarDisconnected();
        _failRequests(_jarRequests, 'JAR channel disconnected');
      },
    );
    _apkServer = await ApkServer.start(
      onMessage: _onApkMessage,
      onClientConnected: () => core.markApkConnected(),
      onClientDisconnected: () {
        core.markApkDisconnected();
        _failRequests(_apkRequests, 'APK channel disconnected');
      },
    );
    _mediaServer = await MediaServer.start();
    _notificationServer = await NotificationServer.start();
  }

  Future<void> _deployJar(String serial) async {
    final adb = AppPaths.adbExe;
    final jar = AppPaths.androiddexJar;
    await Process.run(adb.path, [
      '-s',
      serial,
      'shell',
      'pkill',
      '-f',
      androidDexJarMainClass,
    ], workingDirectory: adb.parent.path);
    if (!await jar.exists()) {
      throw Exception('androiddex.jar not found at ${jar.path}');
    }
    final push = await Process.run(adb.path, [
      '-s',
      serial,
      'push',
      jar.path,
      '/data/local/tmp/androiddex.jar',
    ], workingDirectory: adb.parent.path);
    if (push.exitCode != 0) {
      throw Exception('Failed to push androiddex.jar: ${push.stderr}');
    }
  }

  Future<void> _startJarRuntime(String serial) async {
    final adb = AppPaths.adbExe;
    core.updateJarProgress(0.82, 'Launching service runtime on device…');
    _jarProcess = await Process.start(adb.path, [
      '-s',
      serial,
      'shell',
      'CLASSPATH=/data/local/tmp/androiddex.jar',
      'app_process',
      '/',
      androidDexJarMainClass,
    ], workingDirectory: adb.parent.path);
    _jarProcess!.stdout.transform(utf8.decoder).listen((_) {});
    _jarProcess!.stderr.transform(utf8.decoder).listen((_) {});
    core.updateJarProgress(0.92, 'Service is running — awaiting connection…');
  }

  Future<bool> _isPackageInstalled(String serial) async {
    final adb = AppPaths.adbExe;
    final check = await Process.run(adb.path, [
      '-s',
      serial,
      'shell',
      'pm',
      'path',
      androidDexPackage,
    ], workingDirectory: adb.parent.path);
    if (check.exitCode != 0) return false;
    return (check.stdout as String).contains('package:');
  }

  Future<void> _installApk(String serial) async {
    final adb = AppPaths.adbExe;
    final apk = AppPaths.androidDexApk;
    if (!await apk.exists()) {
      throw Exception('AndroidDex.apk not found at ${apk.path}');
    }
    final install = await Process.run(adb.path, [
      '-s',
      serial,
      'install',
      '-r',
      apk.path,
    ], workingDirectory: adb.parent.path);
    if (install.exitCode != 0) {
      throw Exception('Failed to install APK: ${install.stderr}');
    }
  }

  Future<void> _startServerService(String serial) async {
    final adb = AppPaths.adbExe;
    final args = [
      '-s',
      serial,
      'shell',
      'am',
      'start-foreground-service',
      '-n',
      androidDexService,
    ];
    final start = await Process.run(
      adb.path,
      args,
      workingDirectory: adb.parent.path,
    );
    if (start.exitCode != 0) {
      throw Exception('Failed to start companion service: ${start.stderr}');
    }
  }

  Future<bool> _waitForJarHandshake({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    var remaining = timeout.inMilliseconds;
    while (remaining > 0) {
      if (core.jarConnectedValue) return true;
      await Future.delayed(const Duration(milliseconds: 150));
      remaining -= 150;
    }
    return core.jarConnectedValue;
  }

  Future<bool> _waitForApkHandshake({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    var remaining = timeout.inMilliseconds;
    while (remaining > 0) {
      if (core.apkConnectedValue) return true;
      await Future.delayed(const Duration(milliseconds: 150));
      remaining -= 150;
    }
    return core.apkConnectedValue;
  }

  Future<void> _startExtendedServices() async {
    await Future.delayed(const Duration(milliseconds: 300));
  }

  void _onJarMessage(String raw) {
    final json = _parseJson(raw);
    if (json != null && _completeRequest(_jarRequests, json)) return;
    final msg = _parse(raw);
    if (msg == null) return;
    if (msg.type == AndroidCoreMessageType.batterySmall ||
        msg.type == AndroidCoreMessageType.batteryUpdate) {
      core.updateFromMessage(msg);
      return;
    }
    if (msg.type == AndroidCoreMessageType.volumeUpdate) {
      core.updateFromMessage(msg);
      return;
    }
  }

  void _onApkMessage(String raw) {
    final json = _parseJson(raw);
    if (json != null && _completeRequest(_apkRequests, json)) return;
    final msg = _parse(raw);
    if (msg == null) return;
    core.updateFromMessage(msg);
  }

  AndroidCoreMessage? _parse(String raw) {
    try {
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      return AndroidCoreMessage.fromJson(parsed);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _parseJson(String raw) {
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  bool _completeRequest(
    Map<String, Completer<Map<String, dynamic>>> requests,
    Map<String, dynamic> response,
  ) {
    final id = response['id']?.toString();
    if (id == null) return false;
    final completer = requests.remove(id);
    if (completer == null) return false;
    completer.complete(response);
    return true;
  }

  Future<Map<String, dynamic>> sendApkCommand(
    String command, {
    Map<String, dynamic> arguments = const {},
    Duration timeout = const Duration(seconds: 15),
  }) {
    return _sendRequest(
      command: command,
      arguments: arguments,
      requests: _apkRequests,
      send: (message) => _apkServer?.sendJson(message) ?? false,
      channelName: 'APK',
      timeout: timeout,
    );
  }

  Future<Map<String, dynamic>> sendJarCommand(
    String command, {
    Map<String, dynamic> arguments = const {},
    Duration timeout = const Duration(seconds: 15),
  }) {
    return _sendRequest(
      command: command,
      arguments: arguments,
      requests: _jarRequests,
      send: (message) => _jarServer?.sendJson(message) ?? false,
      channelName: 'JAR',
      timeout: timeout,
    );
  }

  Future<Map<String, dynamic>> _sendRequest({
    required String command,
    required Map<String, dynamic> arguments,
    required Map<String, Completer<Map<String, dynamic>>> requests,
    required bool Function(Map<String, dynamic>) send,
    required String channelName,
    required Duration timeout,
  }) async {
    final id = 'host-${++_nextRequestId}';
    final completer = Completer<Map<String, dynamic>>();
    requests[id] = completer;
    final message = <String, dynamic>{
      ...arguments,
      'id': id,
      'command': command,
    };
    if (!send(message)) {
      requests.remove(id);
      throw StateError('$channelName channel is not connected');
    }
    try {
      return await completer.future.timeout(timeout);
    } finally {
      requests.remove(id);
    }
  }

  void _failRequests(
    Map<String, Completer<Map<String, dynamic>>> requests,
    String message,
  ) {
    for (final request in requests.values) {
      if (!request.isCompleted) request.completeError(StateError(message));
    }
    requests.clear();
  }

  void dispose() {
    _failRequests(_apkRequests, 'Boot service disposed');
    _failRequests(_jarRequests, 'Boot service disposed');
    _jarProcess?.kill();
    _jarServer?.dispose();
    _apkServer?.dispose();
    _mediaServer?.dispose();
    _notificationServer?.dispose();
  }
}
