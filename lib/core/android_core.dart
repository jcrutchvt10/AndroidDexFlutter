import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

import 'package:androiddex_host/core/android_core_messages.dart';
import 'package:androiddex_host/core/app_paths.dart';
import 'package:androiddex_host/core/dev_log.dart';
import 'package:androiddex_host/core/error_messages.dart';
import 'package:androiddex_host/core/models.dart';
import 'package:androiddex_host/core/protocol.dart';
import 'package:androiddex_host/core/scrcpy_arguments.dart';
import 'package:androiddex_host/host/media_data_manager.dart';
import 'package:androiddex_host/host/notification_data_manager.dart';
import 'package:androiddex_host/services/boot_service.dart';
import 'package:androiddex_host/services/device_manager.dart';
import 'package:androiddex_host/services/native_desktop_windows.dart';
import 'package:androiddex_host/services/reconnection_manager.dart';
import 'package:androiddex_host/services/settings_store.dart';
import 'package:androiddex_host/services/window_manager.dart';
import 'package:androiddex_host/services/window_thumbnail_service.dart';

// `AndroidAppInfo` and `DesktopAppWindow` now live in `core/models.dart` so the
// window manager can use them without a cyclic dependency. They are
// re-exported here to keep existing imports of `android_core.dart` working.
export 'package:androiddex_host/core/models.dart'
    show AndroidAppInfo, DesktopAppWindow;

/// Central reactive state store mirroring the Android-Dex `AndroidCore` host
/// state model. The Flutter UI reads from these fields and rebuilds when
/// their notifiers change.
class AndroidCore extends ChangeNotifier {
  AndroidCore({DeviceManager? deviceManager, SettingsStore? settingsStore})
    : settings = settingsStore ?? SettingsStore.instance,
      appProgress = ValueNotifier<double>(0),
      jarProgress = ValueNotifier<double>(0),
      appLabel = ValueNotifier<String>(''),
      jarLabel = ValueNotifier<String>('') {
    _boot = BootService(this, deviceManager: deviceManager);
    _reconnection = ReconnectionManager(this);
  }

  BootService get boot => _boot!;
  BootService? _boot;

  /// Persistent host preferences (wallpaper, last device).
  final SettingsStore settings;

  /// Device media session mirror, fed by the 3701 callback channel.
  final MediaDataManager media = MediaDataManager();

  /// Device notification mirror, fed by the 3700 callback channel.
  final NotificationDataManager notifications = NotificationDataManager();

  /// Open app windows: geometry, z-order, tiling.
  final WindowManager windows = WindowManager();

  ReconnectionManager? _reconnection;
  ReconnectionManager get reconnection => _reconnection!;

  bool _bootFinished = false;
  bool _jarConnected = false;
  bool _apkConnected = false;
  bool _allConnected = false;

  final ValueNotifier<bool> jarConnected = ValueNotifier<bool>(false);
  final ValueNotifier<bool> apkConnected = ValueNotifier<bool>(false);
  final ValueNotifier<bool> allConnected = ValueNotifier<bool>(false);

  /// Aliases used by completer-based waiters that must not depend on the
  /// `ChangeNotifier` side of this class (avoids listener aliasing).
  ValueListenable<bool> get jarConnectedNotifier => jarConnected;
  ValueListenable<bool> get apkConnectedNotifier => apkConnected;

  final ValueNotifier<String> status = ValueNotifier<String>('Initializing…');
  final ValueNotifier<bool> bootError = ValueNotifier<bool>(false);
  final ValueNotifier<String> bootErrorMessage = ValueNotifier<String>('');

  /// Mirrors `BootService.isRunning` so the UI can disable retry actions
  /// while an initialization attempt is still in flight.
  final ValueNotifier<bool> bootInProgress = ValueNotifier<bool>(false);

  /// A non-fatal post-boot problem: an optional device channel did not come
  /// up. The desktop is usable, but the affected panel will stay empty, so
  /// the warning has to outlive the boot screen to be seen.
  final ValueNotifier<String> bootWarning = ValueNotifier<String>('');

  /// True when the current boot failure can be resolved by choosing a
  /// different ADB target, which reveals the "Open ADB Manager" button.
  final ValueNotifier<bool> canPickDevice = ValueNotifier<bool>(false);

  final ValueNotifier<double> appProgress;
  final ValueNotifier<double> jarProgress;
  final ValueNotifier<String> appLabel;
  final ValueNotifier<String> jarLabel;

  int _batteryPercentage = -1;
  bool _batteryCharging = false;
  int _batteryPlugged = 0;
  bool _batterySaver = false;
  double _batteryTemperature = 0;
  double _batteryVoltage = 0;
  int _batteryCurrentMa = 0;
  String _batteryHealth = 'Unknown';
  String _batteryTechnology = 'Unknown';
  String _batteryPlugType = 'None';

  int get batteryPercentage => _batteryPercentage;
  bool get batteryCharging => _batteryCharging;
  int get batteryPlugged => _batteryPlugged;
  bool get batterySaver => _batterySaver;
  double get batteryTemperature => _batteryTemperature;
  double get batteryVoltage => _batteryVoltage;
  int get batteryCurrentMa => _batteryCurrentMa;
  String get batteryHealth => _batteryHealth;
  String get batteryTechnology => _batteryTechnology;
  String get batteryPlugType => _batteryPlugType;

  final ValueNotifier<int> batteryPercentageNotifier = ValueNotifier<int>(-1);

  Map<String, int> _volumeCurrent = {};
  Map<String, int> _volumeMax = {};
  Map<String, bool> _volumeAvailable = {};

  int volumeCurrent(String name) => _volumeCurrent[name] ?? 0;
  int volumeMax(String name) => _volumeMax[name] ?? 0;
  bool volumeAvailable(String name) => _volumeAvailable[name] ?? false;

  bool _wifi = false;
  String _wifiName = '';
  bool _bluetooth = false;
  String _bluetoothName = '';
  bool _mobileData = false;
  bool _airplane = false;
  bool _mute = false;
  bool _rotationLock = false;
  bool _location = false;
  bool _torch = false;

  bool get wifi => _wifi;
  String get wifiName => _wifiName;
  bool get bluetooth => _bluetooth;
  String get bluetoothName => _bluetoothName;
  bool get mobileData => _mobileData;
  bool get airplane => _airplane;
  bool get mute => _mute;
  bool get rotationLock => _rotationLock;
  bool get location => _location;
  bool get torch => _torch;

  String _permissionLevel = 'unknown';
  String _permissionMessage = '';
  final Map<String, bool> _permissionsData = {};
  int _permissionTimestamp = 0;

  String get permissionLevel => _permissionLevel;
  String get permissionMessage => _permissionMessage;
  bool permissionGranted(String key) => _permissionsData[key] ?? false;
  int get permissionTimestamp => _permissionTimestamp;

  String _deviceId = '';
  String get deviceId => _deviceId;

  /// The ADB target currently in use (`-d`, a serial, or `ip:port`).
  DeviceManager get devices => _boot!.devices;

  List<AndroidAppInfo> _apps = const [];
  bool _appsLoading = false;
  String _appsError = '';
  final Map<String, Process> _appProcesses = {};
  final List<DesktopAppWindow> _desktopWindows = [];
  String _launchError = '';
  AndroidAppInfo? _lastFailedApp;
  bool _disposed = false;

  List<AndroidAppInfo> get apps => _apps;
  bool get appsLoading => _appsLoading;
  String get appsError => _appsError;
  List<DesktopAppWindow> get desktopWindows =>
      List.unmodifiable(_desktopWindows);
  String get launchError => _launchError;

  /// The app that most recently failed to launch, if any. The desktop offers a
  /// one-click relaunch for it next to the error banner.
  AndroidAppInfo? get lastFailedApp => _lastFailedApp;

  bool get bootFinished => _bootFinished;
  bool get jarConnectedValue => _jarConnected;
  bool get apkConnectedValue => _apkConnected;
  bool get allConnectedValue => _allConnected;

  void start() {
    boot.initializeSystem();
  }

  /// Requests another boot unless one is already running.
  ///
  /// `initializeSystem` silently ignores concurrent calls, which made the
  /// retry button look broken; surfacing the state keeps the UI honest.
  Future<void> retryBoot() async {
    if (boot.isRunning) {
      bootInProgress.value = true;
      return;
    }
    _reconnection?.stopMonitoring();
    await _boot?.reset();
    start();
  }

  void markJarConnected() {
    _jarConnected = true;
    jarConnected.value = true;
    allConnectedValueChanged();
  }

  void markApkConnected() {
    _apkConnected = true;
    apkConnected.value = true;
    allConnectedValueChanged();
  }

  void markJarDisconnected() {
    _jarConnected = false;
    jarConnected.value = false;
    allConnectedValueChanged();
  }

  void markApkDisconnected() {
    _apkConnected = false;
    apkConnected.value = false;
    allConnectedValueChanged();
  }

  void allConnectedValueChanged() {
    final all = _jarConnected && _apkConnected;
    _allConnected = all;
    allConnected.value = all;
  }

  void updateFromMessage(AndroidCoreMessage message) {
    // Every message may carry the reporting device id; keep it so the desktop
    // can label which handset is attached.
    final reportedId = message.deviceId;
    if (reportedId != null &&
        reportedId.isNotEmpty &&
        reportedId != _deviceId) {
      _deviceId = reportedId;
      notifyListeners();
    }
    for (final state in message.states ?? <AndroidCoreState>[]) {
      _applyState(state);
    }

    switch (message.type) {
      case AndroidCoreMessageType.batterySmall:
        final battery = message.batterySmall;
        if (battery != null) _applyBatterySmall(battery);
      case AndroidCoreMessageType.batteryUpdate:
        final battery = message.batteryUpdate;
        if (battery != null) _applyBatteryUpdate(battery);
      case AndroidCoreMessageType.volumeUpdate:
        final volume = message.volumeUpdate;
        if (volume != null) _applyVolumeUpdate(volume);
      case AndroidCoreMessageType.apkPermissions:
        final permissions = message.apkPermissions;
        if (permissions != null) _applyPermissions(permissions);
      default:
        break;
    }
  }

  /// Applies a device-state delta. Fields are merged first and listeners are
  /// notified once — per-field notifications were fanning a single message out
  /// into up to ten desktop rebuilds.
  void _applyState(AndroidCoreState state) {
    var changed = false;
    if (state.wifi != null) {
      _wifi = state.wifi!;
      changed = true;
    }
    if (state.wifiName != null) {
      _wifiName = state.wifiName!;
      changed = true;
    }
    if (state.bluetooth != null) {
      _bluetooth = state.bluetooth!;
      changed = true;
    }
    if (state.bluetoothName != null) {
      _bluetoothName = state.bluetoothName!;
      changed = true;
    }
    if (state.mobileData != null) {
      _mobileData = state.mobileData!;
      changed = true;
    }
    if (state.airplaneMode != null) {
      _airplane = state.airplaneMode!;
      changed = true;
    }
    if (state.mute != null) {
      _mute = state.mute!;
      changed = true;
    }
    if (state.rotationLock != null) {
      _rotationLock = state.rotationLock!;
      changed = true;
    }
    if (state.location != null) {
      _location = state.location!;
      changed = true;
    }
    if (state.torch != null) {
      _torch = state.torch!;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _applyBatterySmall(BatterySmall small) {
    if (small.percentage != null) {
      _batteryPercentage = small.percentage!;
      batteryPercentageNotifier.value = small.percentage!;
    }
    if (small.charging != null) {
      _batteryCharging = small.charging!;
    }
    if (small.plugged != null) {
      _batteryPlugged = small.plugged!;
    }
    if (small.batterySaver != null) {
      _batterySaver = small.batterySaver!;
    }
    notifyListeners();
  }

  void _applyBatteryUpdate(BatteryUpdate update) {
    final b = update.battery;
    if (b == null) return;
    if (b.percentage != null) {
      _batteryPercentage = b.percentage!;
      batteryPercentageNotifier.value = b.percentage!;
    }
    if (b.charging != null) _batteryCharging = b.charging!;
    if (b.plugged != null) _batteryPlugged = b.plugged!;
    if (b.voltage != null) _batteryVoltage = b.voltage!;
    if (b.temperature != null) _batteryTemperature = b.temperature!;
    if (b.currentMa != null) _batteryCurrentMa = b.currentMa!;
    if (b.health != null) _batteryHealth = b.health!;
    if (b.technology != null) _batteryTechnology = b.technology!;
    if (b.plugType != null) _batteryPlugType = b.plugType!;
    if (b.batterySaver != null) _batterySaver = b.batterySaver!;
    notifyListeners();
  }

  void _applyVolumeUpdate(VolumeUpdate update) {
    _volumeCurrent = {};
    _volumeMax = {};
    _volumeAvailable = {};
    for (final stream in update.streams ?? <VolumeStream>[]) {
      _volumeCurrent[stream.streamName ?? ''] = stream.current ?? 0;
      _volumeMax[stream.streamName ?? ''] = stream.max ?? 0;
      _volumeAvailable[stream.streamName ?? ''] = stream.available ?? false;
    }
    notifyListeners();
  }

  void _applyPermissions(ApkPermissions permissions) {
    if (permissions.level != null) {
      _permissionLevel = permissions.level!;
    }
    if (permissions.message != null) {
      _permissionMessage = permissions.message!;
    }
    if (permissions.timestamp != null) {
      _permissionTimestamp = permissions.timestamp!;
    }
    _permissionsData.clear();
    for (final entry in (permissions.data ?? <String, bool>{}).entries) {
      _permissionsData[entry.key] = entry.value;
    }
    notifyListeners();
  }

  void updateAppProgress(double value, String label) {
    appProgress.value = value;
    appLabel.value = label;
  }

  void updateJarProgress(double value, String label) {
    jarProgress.value = value;
    jarLabel.value = label;
  }

  void setBootFinished() {
    _bootFinished = true;
    notifyListeners();
  }

  /// Publishes a boot failure.
  ///
  /// The error panel in `BootScreen` is gated on [bootError], which is read
  /// directly during `build()` rather than through a `ValueListenableBuilder`.
  /// The notifier flip therefore has to notify this [ChangeNotifier] as well,
  /// otherwise the owner never rebuilds and the message never reaches the user.
  void setBootError(String message, {bool canPickDevice = false}) {
    bootError.value = true;
    bootErrorMessage.value = message;
    this.canPickDevice.value = canPickDevice;
    status.value = message;
    notifyListeners();
  }

  void clearBootError() {
    bootError.value = false;
    bootErrorMessage.value = '';
    canPickDevice.value = false;
    notifyListeners();
  }

  /// Clears per-attempt connection state so a retry starts from scratch.
  void resetRuntimeState() {
    _jarConnected = false;
    _apkConnected = false;
    _allConnected = false;
    jarConnected.value = false;
    apkConnected.value = false;
    allConnected.value = false;
    appProgress.value = 0;
    jarProgress.value = 0;
    canPickDevice.value = false;
    bootWarning.value = '';
    media.markDisconnected();
    notifications.clearAll();
    notifyListeners();
  }

  /// Starts the post-boot connection watchdog. Idempotent.
  void startMonitoring() => _reconnection?.startMonitoring();

  /// Rescans the attached ADB devices for the ADB Manager dialog.
  Future<List<AdbDevice>> refreshDevices() => devices.refresh();

  void setStatus(String value) {
    status.value = value;
    notifyListeners();
  }

  /// Records a degraded-but-usable boot state, naming the channels that did
  /// not respond. Emptying the string clears the warning.
  void warnIfChannelMissing(String channels) {
    bootWarning.value = channels.isEmpty
        ? ''
        : 'Connected, but the device $channels channel did not respond. '
              'Those panels will stay empty until the companion app is '
              'restarted.';
    notifyListeners();
  }

  Future<void> refreshApps() async {
    if (_appsLoading) return;
    _appsLoading = true;
    _appsError = '';
    notifyListeners();
    try {
      final response = await boot.sendApkCommand(DexProtocol.apkGetAllApps);
      if (response['status'] != 'success') {
        throw AndroidDexError(
          'The app list could not be read from the device.',
          devDetail: response['message']?.toString(),
        );
      }
      final rawApps = response['apps'];
      if (rawApps is! List) {
        throw const AndroidDexError(
          'The app list could not be read from the device.',
          devDetail: 'missing "apps" array',
        );
      }
      final apps =
          rawApps
              .whereType<Map>()
              .map(
                (json) => AndroidAppInfo.fromJson(json.cast<String, dynamic>()),
              )
              .where((app) => app.packageName.isNotEmpty)
              .toList()
            ..sort(
              (left, right) =>
                  left.name.toLowerCase().compareTo(right.name.toLowerCase()),
            );
      _apps = List.unmodifiable(apps);
    } catch (error) {
      DevLog.logError(error, scope: 'apps');
      _appsError = userMessageFor(error);
    } finally {
      _appsLoading = false;
      notifyListeners();
    }
  }

  Future<void> launchApp(AndroidAppInfo app) async {
    if (_appProcesses.containsKey(app.packageName)) {
      _launchError = '${app.name} is already open.';
      notifyListeners();
      return;
    }

    _launchError = '';
    _lastFailedApp = null;
    try {
      final executable = AppPaths.scrcpyExe;
      if (!await executable.exists()) {
        throw const AndroidDexError(
          kWindowRuntimeMissing,
          devDetail: 'scrcpy client missing',
        );
      }
      final server = AppPaths.scrcpyServer;
      if (!await server.exists()) {
        throw const AndroidDexError(
          kWindowServerMissing,
          devDetail: 'scrcpy-server missing',
        );
      }
      // The bundled fork implements `--start-app` itself, which is the verified
      // path. A stock scrcpy runtime has no such flag, so for that case the app
      // is placed on the new display through the JAR `app.start_on_display`
      // command instead.
      final forkRuntime = AppPaths.usesRewriteDexScrcpy;
      final transportSizing = forkRuntime
          ? '--desktop-transport'
          : '--flex-display';
      final arguments = [
        scrcpyDisplayArgument(settings.displaySize),
        transportSizing,
        '--render-fit=unscaled',
        '--display-ime-policy=local',
        '--no-vd-system-decorations',
        if (forkRuntime) '--start-app=${app.packageName}',
        '--window-title=Android DEX · ${app.name}',
        '--window-x=-32000',
        '--window-y=-32000',
        '--window-borderless',
        '--no-window-aspect-ratio-lock',
        scrcpyMaxFpsArgument(settings.videoFps),
        scrcpyVideoCodecArgument(settings.videoCodec),
        scrcpyVideoBitRateArgument(settings.videoBitrateMbps),
        if (settings.stayAwake) scrcpyStayAwakeArgument,
        if (settings.turnScreenOff) scrcpyTurnScreenOffArgument,
      ];
      final environment = Map<String, String>.from(Platform.environment)
        ..['SCRCPY_SERVER_PATH'] = server.path
        ..['SCRCPY_ICON_DIR'] = AppPaths.scrcpyRuntimeDir.path;
      final process = await Process.start(
        executable.path,
        arguments,
        environment: environment,
        workingDirectory: AppPaths.scrcpyRuntimeDir.path,
        mode: ProcessStartMode.normal,
      );
      _appProcesses[app.packageName] = process;
      final window = DesktopAppWindow(
        app: app,
        startedAt: DateTime.now(),
        processId: process.pid,
      );
      _desktopWindows.add(window);
      final saved = settings.windowStateFor(app.packageName);
      final savedSnap = saved?['snap'] as int?;
      final snap = savedSnap != null
          ? WindowSnap.values[savedSnap.clamp(0, WindowSnap.values.length - 1)]
          : WindowSnap.none;
      windows.open(
        window,
        origin: saved != null
            ? Offset(
                saved['x']?.toDouble() ?? 160,
                saved['y']?.toDouble() ?? 80,
              )
            : const Offset(160, 80),
        extent: saved != null
            ? Size(
                saved['width']?.toDouble() ?? 850,
                saved['height']?.toDouble() ?? 520,
              )
            : const Size(850, 520),
        snap: snap,
      );
      notifyListeners();

      if (!forkRuntime) {
        unawaited(_placeOnDisplay(app));
      }

      // scrcpy reports mirror failures on stderr; keep a short tail so a
      // crash can be explained instead of surfacing a bare exit code.
      final stderrTail = <String>[];
      unawaited(process.stdout.drain<void>());
      unawaited(
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(stderrTail.add)
            .asFuture<void>(),
      );
      unawaited(
        process.exitCode.then((code) {
          _appProcesses.remove(app.packageName);
          _desktopWindows.removeWhere(
            (candidate) => candidate.packageName == app.packageName,
          );
          windows.close(app.packageName);
          if (code != 0) {
            final detail = stderrTail.isEmpty
                ? ''
                : ' — ${stderrTail.take(3).join(' · ')}';
            _launchError = '${app.name} could not open (exit $code)$detail.';
            _lastFailedApp = app;
            DevLog.log(
              'scrcpy exit $code for ${app.packageName}: '
              '${stderrTail.join('\n')}',
              scope: 'launch',
            );
          }
          if (!_disposed) notifyListeners();
        }),
      );
    } catch (error) {
      DevLog.logError(error, scope: 'launch');
      _launchError = userMessageFor(error);
      notifyListeners();
    }
  }

  /// Places an app on its virtual display through the JAR command channel.
  ///
  /// Best effort: the window stays usable even when the device refuses.
  Future<void> _placeOnDisplay(AndroidAppInfo app) async {
    try {
      await boot.startAppOnDisplay(app.packageName);
    } catch (error) {
      DevLog.logError(error, scope: 'launch');
    }
  }

  Future<void> closeAppWindow(DesktopAppWindow window) async {
    final packageName = window.packageName;
    final process = _appProcesses[packageName];
    if (process != null) await _closeScrcpyProcess(process);
    _appProcesses.remove(packageName);
    _desktopWindows.removeWhere(
      (candidate) => candidate.packageName == packageName,
    );
    windows.close(packageName);
    WindowThumbnailService.instance.forget(window.processId);
    notifyListeners();
    try {
      await boot.forceStop(packageName);
    } catch (error) {
      // The native scrcpy window is already closed, so device cleanup is
      // best effort.
      DevLog.logError(error, scope: 'launch');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final process in _appProcesses.values) {
      unawaited(_closeScrcpyProcess(process));
    }
    _appProcesses.clear();
    _boot?.dispose();
    _reconnection?.dispose();
    media.dispose();
    notifications.dispose();
    windows.dispose();
    WindowThumbnailService.instance.clear();
    jarConnected.dispose();
    apkConnected.dispose();
    allConnected.dispose();
    status.dispose();
    bootError.dispose();
    bootErrorMessage.dispose();
    bootInProgress.dispose();
    bootWarning.dispose();
    canPickDevice.dispose();
    appProgress.dispose();
    jarProgress.dispose();
    appLabel.dispose();
    jarLabel.dispose();
    batteryPercentageNotifier.dispose();
    super.dispose();
  }

  Future<void> _closeScrcpyProcess(Process process) async {
    try {
      await NativeDesktopWindows.close(process.pid);
    } catch (_) {
      // The child may not have attached yet; the process fallback below still
      // guarantees that the host does not retain a dead entry.
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // A wedged transport must not block the desktop close action.
      process.kill();
    }
  }
}
