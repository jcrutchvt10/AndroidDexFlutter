import 'dart:io';

import 'package:path/path.dart' as p;

class AppPaths {
  AppPaths._();

  static String? _appDir;
  static String? _userDataDirOverride;

  /// Test-only: pins the app directory without the bundle probe. Pass `null`
  /// to restore the uninitialized state.
  static void debugInitForTests(String? dir) => _appDir = dir;

  /// Test-only: pins the per-user state directory.
  ///
  /// Without this seam a settings test would read (and potentially rewrite)
  /// the real `%LOCALAPPDATA%\AndroidDEX\settings.json`, because
  /// [userDataDir] reads `Platform.environment`, which cannot be stubbed.
  static void debugInitUserDataDirForTests(String? dir) =>
      _userDataDirOverride = dir;

  static String get appDir =>
      _appDir ?? (throw StateError('AppPaths not initialized'));

  static String get bundleDir => p.join(appDir, 'host_bundle');

  // The v1.2 bundle keeps the ADB runtime DLLs beside this executable.
  static File get adbExe => File(p.join(bundleDir, 'adb-windows', 'adb.exe'));
  static File get androiddexJar => File(p.join(bundleDir, 'androiddex.jar'));
  static File get androidDexApk => File(p.join(bundleDir, 'AndroidDex.apk'));

  static File get mainServerJar =>
      File(p.join(bundleDir, 'AndroidDex-main-server.jar'));
  static File get audioServerJar =>
      File(p.join(bundleDir, 'AndroidDex-audio-server.jar'));
  static File get flexDisplayServerJar =>
      File(p.join(bundleDir, 'AndroidDex-flex-display-server.jar'));
  static File get vdServerJar =>
      File(p.join(bundleDir, 'AndroidDex-vd-server.jar'));

  static Directory get adbWindowsDir =>
      Directory(p.join(bundleDir, 'adb-windows'));

  /// The source checkout contains the RewriteDEX fork separately from the
  /// Android-Dex release bundle. Packaged builds copy that same runtime into
  /// host_bundle/adb-windows, so resolve both layouts here.
  static Directory get scrcpyRuntimeDir {
    final checkoutRuntime = Directory(p.join(appDir, 'third_party', 'scrcpy'));
    if (File(p.join(checkoutRuntime.path, 'scrcpy-fork.exe')).existsSync()) {
      return checkoutRuntime;
    }
    return adbWindowsDir;
  }

  static bool get usesRewriteDexScrcpy =>
      File(p.join(scrcpyRuntimeDir.path, 'scrcpy-fork.exe')).existsSync();

  static File get scrcpyServer =>
      File(p.join(scrcpyRuntimeDir.path, 'scrcpy-server'));
  static File get scrcpyExe => File(
    p.join(
      scrcpyRuntimeDir.path,
      usesRewriteDexScrcpy ? 'scrcpy-fork.exe' : 'scrcpy.exe',
    ),
  );

  static Directory get dataDir => Directory(p.join(bundleDir, 'data'));

  /// Per-user host state (`settings.json`, `dev.log`), kept outside the
  /// installation directory so packaged builds remain read-only.
  static Directory get userDataDir {
    final override = _userDataDirOverride;
    if (override != null) return Directory(override);
    final base =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory(p.join(base, 'AndroidDEX'));
  }

  static Future<void> initialize() async {
    final candidates = <Directory>[
      Directory.current,
      Directory(p.dirname(Platform.resolvedExecutable)),
      Directory(
        p.join(
          p.dirname(Platform.resolvedExecutable),
          'data',
          'flutter_assets',
        ),
      ),
    ];
    for (final dir in candidates) {
      if (await File(p.join(dir.path, 'host_bundle', 'adb-windows', 'adb.exe'))
          .exists()) {
        _appDir = dir.path;
        return;
      }
    }
    throw StateError(
      'The Android DEX host bundle is missing. Reinstall the application.',
    );
  }
}
