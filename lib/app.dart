import 'package:flutter/material.dart';

import 'package:androiddex_host/home/home_screen.dart';
import 'package:androiddex_host/boot/boot_screen.dart';
import 'package:androiddex_host/boot/onboarding_screen.dart';
import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/core/app_paths.dart';
import 'package:androiddex_host/core/dev_log.dart';
import 'package:androiddex_host/services/device_manager.dart';

class AndroidDexHostApp extends StatelessWidget {
  const AndroidDexHostApp({super.key, this.deviceManager});

  /// ADB target resolved from the command line, if any.
  final DeviceManager? deviceManager;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Android DEX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'SamsungSharpSans',
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1fb6ff),
          brightness: Brightness.light,
        ),
        cardTheme: const CardThemeData(elevation: 1, margin: EdgeInsets.zero),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      darkTheme: ThemeData(
        fontFamily: 'SamsungSharpSans',
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1fb6ff),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: AppRoot(deviceManager: deviceManager),
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key, this.deviceManager});

  final DeviceManager? deviceManager;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late final AndroidCore _core;
  bool _bootComplete = false;
  bool _guideDismissed = false;

  @override
  void initState() {
    super.initState();
    _core = AndroidCore(deviceManager: widget.deviceManager);
    _initialize().then((_) {
      if (!mounted) return;
      _core.start();
      setState(() {
        _bootComplete = true;
      });
    });
  }

  Future<void> _initialize() async {
    try {
      await AppPaths.initialize();
      DevLog.initialize(AppPaths.userDataDir.path);
      await _core.settings.load();
    } catch (error) {
      // A missing bundle must not stop the UI from rendering an explanation.
      DevLog.logError(error, scope: 'startup');
    }
  }

  @override
  void dispose() {
    _core.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_bootComplete) {
      return const _InitializingRoot();
    }
    if (!_core.settings.onboardingComplete && !_guideDismissed) {
      return OnboardingScreen(
        core: _core,
        onDone: () => setState(() => _guideDismissed = true),
      );
    }

    return ListenableBuilder(
      listenable: _core,
      builder: (context, _) {
        if (!_core.bootFinished) {
          return BootScreen(core: _core);
        }
        return HomeScreen(core: _core);
      },
    );
  }
}

class _InitializingRoot extends StatelessWidget {
  const _InitializingRoot();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Starting Android DEX',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
