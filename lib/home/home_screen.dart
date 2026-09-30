import 'desktop_screen.dart';

import 'package:flutter/material.dart';
import 'package:androiddex_host/core/android_core.dart';

/// The unlocked desktop.
///
/// The legacy Material scaffold that used to live here (task bar, welcome
/// card, quick actions, end drawer) was unreachable dead code: [build] simply
/// returned `DesktopScreen`. It has been removed; the real shell lives in
/// `desktop_screen.dart` and its panels.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.core});

  final AndroidCore core;

  @override
  Widget build(BuildContext context) => DesktopScreen(core: core);
}
