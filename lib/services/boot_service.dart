import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/core/android_core_messages.dart'
    show AndroidCoreMessage;
import 'package:androiddex_host/core/app_paths.dart';
import 'package:androiddex_host/core/dev_log.dart';
import 'package:androiddex_host/core/error_messages.dart';
import 'package:androiddex_host/core/protocol.dart';
import 'package:androiddex_host/host/apk_server.dart';
import 'package:androiddex_host/host/callback_channel.dart';
import 'package:androiddex_host/host/jar_server.dart';
import 'package:androiddex_host/services/device_manager.dart';
import 'package:flutter/foundation.dart';

/// Authorized, online device ids parsed out of `adb devices` output.
List<String> parseConnectedAdbDevices(String output) =>
    parseAdbDevices(output)
        .where((device) => device.isConnected)
        .map((device) => device.id)
        .toList();

/// One `adb reverse` invocation per bridged port, prefixed with the target
/// selector so USB (`-d`) and Wi-Fi (`-s ip:port`) both work.
List<List<String>> buildAdbReverseCommands(List<String> deviceSelector) => [
  for (final port in DexProtocol.reversePorts)
    [...deviceSelector, 'reverse', 'tcp:$port', 'tcp:$port'],
];

/// Removes the obsolete loopback mapping older hosts installed on 8457.
List<List<String>> buildAdbReverseRemovals(List<String> deviceSelector) => [
  [
    ...deviceSelector,
    'reverse',
    '--remove',
    'tcp:${DexProtocol.apkLocalBridgePort}',
  ],
];

/// Orchestrates the full boot sequence and owns the four host servers.
///
/// Errors raised anywhere below are normalised to plain-English
/// [AndroidDexError] messages; technical detail goes to [DevLog] only.
class BootService {
  BootService(this.core, {DeviceManager? deviceManager})
    : devices = deviceManager ?? DeviceManager();

  final AndroidCore core;
  final DeviceManager devices;

  /// Every ADB invocation is bounded so an offline device or a stuck daemon
  /// cannot hang the boot sequence forever.
  static const adbTimeout = Duration(seconds: 20);

  /// Test seam: overrides how raw processes (the on-device JAR runtime) are
  /// spawned. Production spawns the bundled `adb.exe` directly.
  @visibleForTesting
  Future<Process> Function(List<String> args)? processSpawner;

  JarServer? _jarServer;
  ApkServer? _apkServer;
  CallbackChannel? _mediaChannel;
  CallbackChannel? _notificationChannel;
  Process? _jarProcess;

  final Map<String, Completer<Map<String, dynamic>>> _apkRequests = {};
  final Map<String, Completer<Map<String, dynamic>>> _jarRequests = {};
  final Map<int, Completer<void>> _handshakeWaiters = {};
  int _nextWaiterId = 0;
  int _nextRequestId = 0;
  bool _running = false;

  /// True while an initialization attempt is in flight. `initializeSystem`
  /// refuses to start a second concurrent attempt; callers can check this to
  /// disable retry buttons instead of silently no-oping.
  bool get isRunning => _running;

  JarServer? get jarServer => _jarServer;
  ApkServer? get apkServer => _apkServer;
  CallbackChannel? get mediaChannel => _mediaChannel;
  CallbackChannel? get notificationChannel => _notificationChannel;

  /// Runs the whole initialization protocol, emitting both progress bars.
  Future<void> initializeSystem() async {
    if (_running) {
      // Keep the UI's in-flight indicator honest instead of silently
      // ignoring a second click.
      core.bootInProgress.value = true;
      return;
    }
    _running = true;
    core.bootInProgress.value = true;
    try {
      core.clearBootError();

      core.updateAppProgress(0.02, 'Starting ADB server…');
      await _startAdbServer();

      core.updateAppProgress(0.10, 'Connecting to Android device…');
      await _resolveDevice();
      if (devices.needsDeviceSelection) {
        // The boot screen offers "Open ADB Manager" for this failure.
        core.setBootError(kNoDeviceSelected, canPickDevice: true);
        return;
      }

      await _forwardPorts();
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
      await _deployJar(devices.adbArgs);

      core.updateAppProgress(0.55, 'Verifying companion app on device…');
      if (!await _isPackageInstalled()) {
        core.updateAppProgress(
          0.65,
          'Companion app not found — installing now…',
        );
        await _installApk();
      }

      core.updateAppProgress(0.72, 'Launching Android companion services…');
      await _startServerService();

      core.updateAppProgress(
        0.84,
        'Waiting for background service to connect…',
      );
      if (!await _waitForJarHandshake()) {
        core.setBootError(kJarHandshakeTimeout, canPickDevice: true);
        return;
      }

      core.updateAppProgress(0.93, 'Waiting for companion app to connect…');
      if (!await _waitForApkHandshake()) {
        core.setBootError(kApkHandshakeTimeout, canPickDevice: true);
        return;
      }

      core.updateAppProgress(
        0.97,
        'Activating media and notification services…',
      );
      await _startExtendedServices();

      core.updateAppProgress(1.00, 'System ready');
      core.setBootFinished();
      core.startMonitoring();
      await core.settings.setLastDevice(devices.deviceId);
    } catch (error) {
      final message = userMessageFor(error);
      DevLog.logError(error, scope: 'boot');
      core.setBootError(
        message,
        canPickDevice: error is ConnectionFailure || isConnectionError(message),
      );
    } finally {
      _running = false;
      core.bootInProgress.value = false;
    }
  }

  /// Tears the attempt down so a retry starts from a clean state.
  ///
  /// Without this a retry re-binds ports 3698-3701 that the previous attempt
  /// still holds, so it fails with a socket error instead of retrying.
  Future<void> reset() async {
    _failHandshakeWaiters('Reset');
    _failRequests(_apkRequests, 'Reset');
    _failRequests(_jarRequests, 'Reset');

    _jarProcess?.kill();
    _jarProcess = null;

    _jarServer?.dispose();
    _apkServer?.dispose();
    _mediaChannel?.dispose();
    _notificationChannel?.dispose();
    _jarServer = null;
    _apkServer = null;
    _mediaChannel = null;
    _notificationChannel = null;

    devices.reset();
    core.resetRuntimeState();
  }

  // --- ADB ---------------------------------------------------------------

  Future<AdbResult> _adb(List<String> args, {String? failure}) async {
    final adb = AppPaths.adbExe;
    if (!adb.existsSync()) {
      throw AndroidDexError(kAdbRuntimeMissing, devDetail: adb.path);
    }
    String output;
    int exitCode;
    try {
      final process = await Process.run(
        adb.path,
        args,
        workingDirectory: adb.parent.path,
      ).timeout(adbTimeout);
      output = '${process.stdout}${process.stderr}'.trim();
      exitCode = process.exitCode;
    } on TimeoutException {
      throw AndroidDexError(
        kAdbCommandTimedOut,
        devDetail:
            'adb ${args.join(' ')} did not finish in '
            '${adbTimeout.inSeconds}s',
      );
    } catch (error) {
      throw ConnectionFailure(
        kAdbCommandFailed,
        devDetail: 'adb ${args.join(' ')}: $error',
      );
    }
    DevLog.log('adb ${args.join(' ')} → exit $exitCode', scope: 'adb');
    if (exitCode != 0 && failure != null) {
      throw AndroidDexError(
        failure,
        devDetail: 'adb ${args.join(' ')} → exit $exitCode: $output',
      );
    }
    return AdbResult(exitCode == 0, output);
  }

  Future<void> _startAdbServer() async {
    final adb = AppPaths.adbExe;
    if (!adb.existsSync()) {
      throw AndroidDexError(kAdbRuntimeMissing, devDetail: adb.path);
    }
    final result = await _adb(['start-server']);
    if (!result.success) throw const AndroidDexError(kAdbServerFailed);
  }

  Future<void> _resolveDevice() async {
    if (devices.isWifi) {
      // A pinned Wi-Fi target still needs `adb connect` before use.
      final error = await devices.connectIp(devices.deviceId);
      if (error != null) throw ConnectionFailure(error);
      return;
    }
    await devices.autoDetect();
  }

  Future<void> _forwardPorts() async {
    final selector = devices.adbArgs;
    for (final args in buildAdbReverseRemovals(selector)) {
      // Absence of the old mapping is expected; never fatal.
      await _adb(args);
    }
    for (final args in buildAdbReverseCommands(selector)) {
      final port = int.tryParse(args.last.split(':').last) ?? 0;
      await _adb(args, failure: kBridgeFailed(port));
    }
  }

  // --- Servers -----------------------------------------------------------

  Future<void> _startHostServers() async {
    _jarServer = await JarServer.start(
      onMessage: _onJarMessage,
      onClientConnected: () {
        core.markJarConnected();
        core.updateJarProgress(1.00, 'Service connected — handshake confirmed');
      },
      onClientDisconnected: () {
        core.markJarDisconnected();
        _failRequests(_jarRequests, 'Background service disconnected');
      },
    );
    _apkServer = await ApkServer.start(
      onMessage: _onApkMessage,
      onClientConnected: core.markApkConnected,
      onClientDisconnected: () {
        core.markApkDisconnected();
        _failRequests(_apkRequests, 'Companion app disconnected');
      },
    );
    _mediaChannel = await CallbackChannel.startMedia(
      onMessage: core.media.apply,
      onClientConnected: core.media.markConnected,
      onClientDisconnected: core.media.markDisconnected,
    );
    _notificationChannel = await CallbackChannel.startNotification(
      onMessage: core.notifications.apply,
      onClientConnected: core.notifications.markConnected,
      onClientDisconnected: core.notifications.markDisconnected,
    );
  }

  /// Activates the media and notification services.
  ///
  /// Only commands verified in the v1.2 artifact are sent. The companion app
  /// dials the two callback ports on its own, so this asks for the current
  /// device state and then waits briefly for the two connect-backs.
  ///
  /// Unlike the two required channels, these two are *optional*: the desktop
  /// is fully usable without them, so a timeout downgrades the boot status to
  /// a warning instead of failing the whole sequence. Failing silently was
  /// worse — the user got a permanently "waiting…" media panel with no
  /// indication that anything had gone wrong.
  Future<void> _startExtendedServices() async {
    for (final command in const [
      DexProtocol.apkPermissionsGet,
      DexProtocol.apkStateGetAll,
    ]) {
      try {
        await sendApkCommand(command, timeout: const Duration(seconds: 5));
      } catch (error) {
        DevLog.logError(error, scope: 'boot');
      }
    }
    final mediaUp = await _waitForChannel(
      core.media.connectedListenable,
      const Duration(seconds: 5),
    );
    final notificationsUp = await _waitForChannel(
      core.notifications.connectedListenable,
      const Duration(seconds: 5),
    );
    if (!mediaUp || !notificationsUp) {
      final missing = [
        if (!mediaUp) 'media',
        if (!notificationsUp) 'notifications',
      ].join(' and ');
      DevLog.log('optional channel(s) unavailable: $missing', scope: 'boot');
      core.warnIfChannelMissing(missing);
    }
  }

  // --- JAR deployment ----------------------------------------------------

  Future<void> _deployJar(List<String> selector) async {
    core.updateJarProgress(0.00, 'Preparing service deployment…');

    core.updateJarProgress(0.15, 'Stopping previous service on device…');
    await _adb([...selector, 'shell', 'pkill', '-f', DexProtocol.jarMainClass]);

    core.updateJarProgress(0.30, 'Locating service module…');
    final jar = AppPaths.androiddexJar;
    if (!jar.existsSync()) {
      throw AndroidDexError(kServiceModuleMissing, devDetail: jar.path);
    }

    core.updateJarProgress(0.50, 'Uploading service module to device…');
    await _adb([
      ...selector,
      'push',
      jar.path,
      DexProtocol.jarRemotePath,
    ], failure: kServiceTransferFailed);
    core.updateJarProgress(0.70, 'Service module uploaded successfully');

    core.updateJarProgress(0.82, 'Launching service runtime on device…');
    final adb = AppPaths.adbExe;
    final spawn = processSpawner;
    _jarProcess = spawn != null
        ? await spawn([
            ...selector,
            'shell',
            'CLASSPATH=${DexProtocol.jarRemotePath}',
            'app_process',
            '/',
            DexProtocol.jarMainClass,
          ])
        : await Process.start(adb.path, [
            ...selector,
            'shell',
            'CLASSPATH=${DexProtocol.jarRemotePath}',
            'app_process',
            '/',
            DexProtocol.jarMainClass,
          ], workingDirectory: adb.parent.path);
    _jarProcess!.stdout.transform(utf8.decoder).listen((line) {
      if (line.trim().isNotEmpty) DevLog.log(line, scope: 'jar');
    });
    _jarProcess!.stderr.transform(utf8.decoder).listen((line) {
      if (line.trim().isNotEmpty) DevLog.log(line, scope: 'jar');
    });
    core.updateJarProgress(0.92, 'Service is running — awaiting connection…');
  }

  Future<bool> _isPackageInstalled() async {
    final result = await _adb([
      ...devices.adbArgs,
      'shell',
      'pm',
      'path',
      DexProtocol.package,
    ]);
    return result.output.contains('package:');
  }

  Future<void> _installApk() async {
    final apk = AppPaths.androidDexApk;
    if (!apk.existsSync()) {
      throw AndroidDexError(kCompanionApkMissing, devDetail: apk.path);
    }
    await _adb([
      ...devices.adbArgs,
      'install',
      '-r',
      apk.path,
    ], failure: kAppInstallFailed);
  }

  Future<void> _startServerService() async {
    final result = await _adb([
      ...devices.adbArgs,
      'shell',
      'am',
      'start-foreground-service',
      '-n',
      DexProtocol.serviceComponent,
    ]);
    if (!result.success || result.output.contains('Error')) {
      throw AndroidDexError(kServiceLaunchFailed, devDetail: result.output);
    }
  }

  // --- Handshakes --------------------------------------------------------

  Future<bool> _waitForJarHandshake({
    Duration timeout = const Duration(seconds: 15),
  }) => _waitForChannel(core.jarConnectedNotifier, timeout);

  Future<bool> _waitForApkHandshake({
    Duration timeout = const Duration(seconds: 15),
  }) => _waitForChannel(core.apkConnectedNotifier, timeout);

  /// Resolves as soon as [notifier] flips true — no polling. Completers are
  /// failed on reset/dispose so waiters never hang past a teardown.
  Future<bool> _waitForChannel(
    ValueListenable<bool> notifier,
    Duration timeout,
  ) async {
    if (notifier.value) return true;
    final id = ++_nextWaiterId;
    final completer = Completer<void>();
    _handshakeWaiters[id] = completer;
    void listener() {
      if (!notifier.value) return;
      _handshakeWaiters.remove(id);
      if (!completer.isCompleted) completer.complete();
    }

    notifier.addListener(listener);
    try {
      await completer.future.timeout(timeout);
      return notifier.value;
    } on TimeoutException {
      return false;
    } on AndroidDexError {
      // The attempt was reset mid-wait; the caller's boot flow is unwinding.
      return false;
    } finally {
      notifier.removeListener(listener);
      _handshakeWaiters.remove(id);
    }
  }

  /// True once both protocol handshakes are satisfied.
  bool get systemReady => core.allConnectedValue;

  // --- Recovery hooks (used by ReconnectionManager) ----------------------

  /// Phase 1: re-establish the loopback bridge without redeploying anything.
  Future<void> reapplyPortBridge() => _forwardPorts();

  /// Phase 2: redeploy the Logic Engine and re-launch the companion service.
  Future<void> redeployService() async {
    await _deployJar(devices.adbArgs);
    await _startServerService();
  }

  Future<bool> waitForJar({Duration timeout = const Duration(seconds: 15)}) =>
      _waitForJarHandshake(timeout: timeout);

  Future<bool> waitForApk({Duration timeout = const Duration(seconds: 15)}) =>
      _waitForApkHandshake(timeout: timeout);

  // --- Message routing ---------------------------------------------------

  void _onJarMessage(String raw) {
    final json = _parseJson(raw);
    if (json != null && _completeRequest(_jarRequests, json)) return;
    final message = _parse(raw);
    if (message == null) return;
    core.updateFromMessage(message);
  }

  void _onApkMessage(String raw) {
    final json = _parseJson(raw);
    if (json != null && _completeRequest(_apkRequests, json)) return;
    final message = _parse(raw);
    if (message == null) return;
    if (_isAppCatalogEvent(json)) core.refreshApps();
    core.updateFromMessage(message);
  }

  /// `apk.app_added` / `apk.app_removed` / `apk.app_count` keep the launcher in
  /// sync without the user pressing refresh.
  bool _isAppCatalogEvent(Map<String, dynamic>? json) {
    final type = json?['type'] as String?;
    return type == 'apk.app_added' ||
        type == 'apk.app_removed' ||
        type == 'apk.app_count';
  }

  AndroidCoreMessage? _parse(String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return null;
      return AndroidCoreMessage.fromJson(parsed.cast<String, dynamic>());
    } catch (_) {
      // Non-JSON lines on a protocol socket are ignored.
      return null;
    }
  }

  Map<String, dynamic>? _parseJson(String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map) return parsed.cast<String, dynamic>();
    } catch (_) {
      // Non-JSON lines on a protocol socket are ignored.
    }
    return null;
  }

  bool _completeRequest(
    Map<String, Completer<Map<String, dynamic>>> requests,
    Map<String, dynamic> response,
  ) {
    final id = response['id']?.toString();
    if (id == null) return false;
    final completer = requests.remove(id);
    if (completer == null) return false;
    if (!completer.isCompleted) completer.complete(response);
    return true;
  }

  // --- Outbound commands -------------------------------------------------

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
      channelName: 'Companion app',
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
      channelName: 'Background service',
      timeout: timeout,
    );
  }

  /// Asks the device to place [packageName] on [displayId].
  Future<void> startAppOnDisplay(String packageName, {int? displayId}) async {
    await sendJarCommand(
      DexProtocol.jarStartOnDisplay,
      arguments: {'package_name': packageName, 'display_id': ?displayId},
      timeout: const Duration(seconds: 10),
    );
  }

  /// Stops [packageName] on the device.
  Future<void> forceStop(String packageName) async {
    await sendJarCommand(
      DexProtocol.jarForceStop,
      arguments: {'package_name': packageName},
      timeout: const Duration(seconds: 10),
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
      throw AndroidDexError('$channelName is not connected.');
    }
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw AndroidDexError('$channelName did not answer in time.');
    } finally {
      requests.remove(id);
    }
  }

  void _failRequests(
    Map<String, Completer<Map<String, dynamic>>> requests,
    String message,
  ) {
    for (final request in requests.values) {
      if (!request.isCompleted) request.completeError(AndroidDexError(message));
    }
    requests.clear();
  }

  void _failHandshakeWaiters(String message) {
    for (final completer in _handshakeWaiters.values) {
      if (!completer.isCompleted) {
        completer.completeError(AndroidDexError(message));
      }
    }
    _handshakeWaiters.clear();
  }

  void dispose() {
    _failHandshakeWaiters('Host shut down');
    _failRequests(_apkRequests, 'Host shut down');
    _failRequests(_jarRequests, 'Host shut down');
    _jarProcess?.kill();
    _jarServer?.dispose();
    _apkServer?.dispose();
    _mediaChannel?.dispose();
    _notificationChannel?.dispose();
  }
}
