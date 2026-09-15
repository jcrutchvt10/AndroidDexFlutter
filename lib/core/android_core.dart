import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:androiddex_host/core/android_core_messages.dart';
import 'package:androiddex_host/core/app_paths.dart';
import 'package:androiddex_host/services/boot_service.dart';
import 'package:androiddex_host/services/native_desktop_windows.dart';

class AndroidAppInfo {
  const AndroidAppInfo({
    required this.name,
    required this.packageName,
    required this.versionName,
    required this.iconBase64,
  });

  factory AndroidAppInfo.fromJson(Map<String, dynamic> json) => AndroidAppInfo(
    name: json['app_name'] as String? ?? json['package_name'] as String? ?? '',
    packageName: json['package_name'] as String? ?? '',
    versionName: json['version_name'] as String? ?? '',
    iconBase64: json['icon_base64'] as String? ?? '',
  );

  final String name;
  final String packageName;
  final String versionName;
  final String iconBase64;
}

class DesktopAppWindow {
  const DesktopAppWindow({
    required this.app,
    required this.startedAt,
    required this.processId,
  });

  final AndroidAppInfo app;
  final DateTime startedAt;
  final int processId;
}

/// Central reactive state store mirroring the Android-Dex `AndroidCore` host
/// state model. The Flutter UI reads from these fields and rebuilds when
/// their notifiers change.
class AndroidCore extends ChangeNotifier {
  AndroidCore()
    : appProgress = ValueNotifier<double>(0),
      jarProgress = ValueNotifier<double>(0),
      appLabel = ValueNotifier<String>(''),
      jarLabel = ValueNotifier<String>('') {
    _boot = BootService(this);
  }

  BootService get boot => _boot!;
  BootService? _boot;

  bool _bootFinished = false;
  bool _jarConnected = false;
  bool _apkConnected = false;
  bool _allConnected = false;

  final ValueNotifier<bool> jarConnected = ValueNotifier<bool>(false);
  final ValueNotifier<bool> apkConnected = ValueNotifier<bool>(false);
  final ValueNotifier<bool> allConnected = ValueNotifier<bool>(false);

  final ValueNotifier<String> status = ValueNotifier<String>('Initializing…');
  final ValueNotifier<bool> bootError = ValueNotifier<bool>(false);
  final ValueNotifier<String> bootErrorMessage = ValueNotifier<String>('');

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

  final String _deviceId = '';
  String get deviceId => _deviceId;

  List<AndroidAppInfo> _apps = const [];
  bool _appsLoading = false;
  String _appsError = '';
  final Map<String, Process> _appProcesses = {};
  final List<DesktopAppWindow> _desktopWindows = [];
  String _launchError = '';
  bool _disposed = false;

  List<AndroidAppInfo> get apps => _apps;
  bool get appsLoading => _appsLoading;
  String get appsError => _appsError;
  List<DesktopAppWindow> get desktopWindows =>
      List.unmodifiable(_desktopWindows);
  String get launchError => _launchError;

  bool get bootFinished => _bootFinished;
  bool get jarConnectedValue => _jarConnected;
  bool get apkConnectedValue => _apkConnected;
  bool get allConnectedValue => _allConnected;

  void start() {
    boot.initializeSystem();
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

  void _applyState(AndroidCoreState state) {
    if (state.wifi != null) {
      _wifi = state.wifi!;
      notifyListeners();
    }
    if (state.wifiName != null) {
      _wifiName = state.wifiName!;
      notifyListeners();
    }
    if (state.bluetooth != null) {
      _bluetooth = state.bluetooth!;
      notifyListeners();
    }
    if (state.bluetoothName != null) {
      _bluetoothName = state.bluetoothName!;
      notifyListeners();
    }
    if (state.mobileData != null) {
      _mobileData = state.mobileData!;
      notifyListeners();
    }
    if (state.airplaneMode != null) {
      _airplane = state.airplaneMode!;
      notifyListeners();
    }
    if (state.mute != null) {
      _mute = state.mute!;
      notifyListeners();
    }
    if (state.rotationLock != null) {
      _rotationLock = state.rotationLock!;
      notifyListeners();
    }
    if (state.location != null) {
      _location = state.location!;
      notifyListeners();
    }
    if (state.torch != null) {
      _torch = state.torch!;
      notifyListeners();
    }
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

  void setBootError(String message) {
    bootError.value = true;
    bootErrorMessage.value = message;
    status.value = message;
  }

  void setStatus(String value) {
    status.value = value;
  }

  Future<void> refreshApps() async {
    if (_appsLoading) return;
    _appsLoading = true;
    _appsError = '';
    notifyListeners();
    try {
      final response = await boot.sendApkCommand('get_all_apps');
      if (response['status'] != 'success') {
        throw StateError(response['message']?.toString() ?? 'App list failed');
      }
      final rawApps = response['apps'];
      if (rawApps is! List) throw const FormatException('Missing app list');
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
      _appsError = error.toString().replaceFirst('Bad state: ', '');
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
    try {
      final executable = AppPaths.scrcpyExe;
      if (!await executable.exists()) {
        throw StateError('The bundled Android window runtime is missing.');
      }
      final server = AppPaths.scrcpyServer;
      if (!await server.exists()) {
        throw StateError('The matching Android window server is missing.');
      }
      final transportSizing = AppPaths.usesRewriteDexScrcpy
          ? '--desktop-transport'
          : '--flex-display';
      final environment = Map<String, String>.from(Platform.environment)
        ..['SCRCPY_SERVER_PATH'] = server.path
        ..['SCRCPY_ICON_DIR'] = AppPaths.scrcpyRuntimeDir.path;
      final process = await Process.start(
        executable.path,
        [
          '--new-display=1280x720/240',
          transportSizing,
          '--render-fit=unscaled',
          '--display-ime-policy=local',
          '--no-vd-system-decorations',
          '--start-app=${app.packageName}',
          '--window-title=Android DEX · ${app.name}',
          '--window-x=-32000',
          '--window-y=-32000',
          '--window-borderless',
          '--no-window-aspect-ratio-lock',
          '--max-fps=60',
          '--video-codec=h264',
        ],
        environment: environment,
        workingDirectory: AppPaths.scrcpyRuntimeDir.path,
        mode: ProcessStartMode.normal,
      );
      _appProcesses[app.packageName] = process;
      _desktopWindows.add(
        DesktopAppWindow(
          app: app,
          startedAt: DateTime.now(),
          processId: process.pid,
        ),
      );
      notifyListeners();

      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      unawaited(
        process.exitCode.then((code) {
          _appProcesses.remove(app.packageName);
          _desktopWindows.removeWhere(
            (window) => window.app.packageName == app.packageName,
          );
          if (code != 0) {
            _launchError = '${app.name} could not open (exit $code).';
          }
          if (!_disposed) notifyListeners();
        }),
      );
    } catch (error) {
      _launchError = error.toString().replaceFirst('Bad state: ', '');
      notifyListeners();
    }
  }

  Future<void> closeAppWindow(DesktopAppWindow window) async {
    final process = _appProcesses[window.app.packageName];
    if (process != null) await _closeScrcpyProcess(process);
    _appProcesses.remove(window.app.packageName);
    _desktopWindows.removeWhere(
      (candidate) => candidate.app.packageName == window.app.packageName,
    );
    notifyListeners();
    try {
      await boot.sendJarCommand(
        'app.force_stop',
        arguments: {'package_name': window.app.packageName},
      );
    } catch (_) {
      // The native scrcpy window is already closed; device cleanup is best effort.
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
    jarConnected.dispose();
    apkConnected.dispose();
    allConnected.dispose();
    status.dispose();
    bootError.dispose();
    bootErrorMessage.dispose();
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
