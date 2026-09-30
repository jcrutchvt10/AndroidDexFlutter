import 'dart:convert' show LineSplitter;
import 'dart:io' show Process;

import 'package:flutter/foundation.dart';

import '../core/app_paths.dart';
import '../core/dev_log.dart';
import '../core/error_messages.dart';

class AdbDevice {
  const AdbDevice(this.id, this.state);

  final String id;
  final String state;

  bool get isConnected => state == 'device';
  bool get isUnauthorized => state == 'unauthorized';
  bool get isOffline => state == 'offline';

  /// USB serials carry no colon; Wi-Fi targets are `ip:port`.
  bool get isWifi => id.contains(':');

  String get label => isWifi ? id : 'USB Device';
  String get detail =>
      isWifi ? 'Wi-Fi ADB — tap to connect' : '$id — tap to connect';
}

/// Parses `adb devices -l` into structured entries.
List<AdbDevice> parseAdbDevices(String output) {
  final devices = <AdbDevice>[];
  for (final line in const LineSplitter().convert(output)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('List of devices')) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      devices.add(AdbDevice(parts[0], parts[1]));
    }
  }
  return devices;
}

/// Result of a single ADB invocation.
class AdbResult {
  const AdbResult(this.success, this.output);

  final bool success;
  final String output;
}

/// Holds *which* ADB device every command in the system targets.
///
/// Mirrors the reference `DeviceManager` singleton contract: [adbArgs] is the
/// only place the selector is built, so USB (`-d`) and Wi-Fi (`ip:port`)
/// targets flow through one code path.
class DeviceManager extends ChangeNotifier {
  DeviceManager({this.runner});

  /// Injectable ADB runner; production uses the bundled `adb.exe`.
  final Future<AdbResult> Function(List<String> args)? runner;

  /// `-d` selects the only attached USB device.
  static const usbSelector = '-d';

  String _deviceId = usbSelector;
  bool _needsDeviceSelection = false;
  List<AdbDevice> _devices = const [];

  String get deviceId => _deviceId;
  bool get needsDeviceSelection => _needsDeviceSelection;
  bool get isUsb => _deviceId == usbSelector;
  bool get isWifi => !isUsb;
  List<AdbDevice> get devices => List.unmodifiable(_devices);

  /// `['-d']` for USB, `['-s', id]` for a pinned serial or Wi-Fi address.
  List<String> get adbArgs => isUsb ? const [usbSelector] : ['-s', _deviceId];

  /// Prefixes an argument list with the resolved device selector.
  List<String> onDevice(List<String> args) => [...adbArgs, ...args];

  /// Parses CLI arguments. `--usb` pins USB; a bare address pins Wi-Fi.
  void setFromArgs(List<String> args) {
    for (final arg in args) {
      if (arg == '--usb') {
        selectDevice(usbSelector);
        return;
      }
    }
    for (final arg in args) {
      if (arg.startsWith('-')) continue;
      if (_looksLikeAddress(arg)) {
        selectDevice(normaliseWifiAddress(arg));
        return;
      }
    }
  }

  /// Resolves a target from the currently attached devices.
  ///
  /// Exactly one online device is claimed silently; zero or several set the
  /// selection flag so the ADB Manager dialog is shown instead.
  Future<void> autoDetect() async {
    final devices = await refresh();
    final online = devices.where((device) => device.isConnected).toList();
    _needsDeviceSelection = online.length != 1;
    if (online.isEmpty) {
      _deviceId = usbSelector;
    } else if (online.length == 1 && !online.single.isWifi) {
      _deviceId = usbSelector;
    } else {
      _deviceId = online.first.id;
    }
    notifyListeners();
  }

  /// Rescans `adb devices -l`.
  Future<List<AdbDevice>> refresh() async {
    final result = await _invoke(['devices', '-l']);
    if (!result.success) {
      _devices = const [];
      notifyListeners();
      return _devices;
    }
    _devices = parseAdbDevices(result.output);
    notifyListeners();
    return _devices;
  }

  /// Applies a device chosen in the ADB Manager dialog.
  void selectDevice(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return;
    _deviceId = trimmed == usbSelector || !trimmed.contains(':')
        ? usbSelector
        : trimmed;
    _needsDeviceSelection = false;
    notifyListeners();
  }

  /// Runs `adb connect ip:5555`, returning a user-facing error or `null`.
  Future<String?> connectIp(String address) async {
    final target = normaliseWifiAddress(address.trim());
    if (target.isEmpty) return kIpAddressRequired;
    try {
      final result = await _invoke(['connect', target]);
      final output = result.output.toLowerCase();
      if (result.success &&
          (output.contains('connected') ||
              output.contains('already connected'))) {
        selectDevice(target);
        return null;
      }
      return kIpConnectFailed(target);
    } catch (error) {
      DevLog.logError(error, scope: 'device');
      return kIpConnectCrashed;
    }
  }

  /// Appends `:5555` when the user typed a bare address.
  static String normaliseWifiAddress(String address) {
    if (address.isEmpty) return '';
    if (address.contains(':')) return address;
    return '$address:5555';
  }

  static bool _looksLikeAddress(String value) =>
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}(:\d+)?$').hasMatch(value);

  Future<AdbResult> _invoke(List<String> args) async {
    final adbRunner = runner;
    if (adbRunner != null) return adbRunner(args);
    final adb = AppPaths.adbExe;
    if (!adb.existsSync()) {
      throw const AndroidDexError(
        kAdbRuntimeMissing,
        devDetail: 'adb.exe absent',
      );
    }
    final result = await Process.run(
      adb.path,
      args,
      workingDirectory: adb.parent.path,
    );
    return AdbResult(
      result.exitCode == 0,
      '${result.stdout}${result.stderr}'.trim(),
    );
  }

  void reset() {
    _deviceId = usbSelector;
    _needsDeviceSelection = false;
    _devices = const [];
  }
}
