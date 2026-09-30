import 'package:flutter/material.dart';

import 'package:androiddex_host/app.dart';
import 'package:androiddex_host/services/device_manager.dart';

/// Entry point.
///
/// Command line arguments select the ADB target before the UI starts:
///
/// ```
/// androiddex_host.exe --usb          # pin the attached USB device
/// androiddex_host.exe 192.168.1.5    # pin a Wi-Fi ADB device (:5555)
/// androiddex_host.exe                # auto-detect
/// ```
void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final deviceManager = DeviceManager()..setFromArgs(args);
  runApp(AndroidDexHostApp(deviceManager: deviceManager));
}
