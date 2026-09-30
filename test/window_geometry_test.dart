import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/core/app_paths.dart';
import 'package:androiddex_host/core/models.dart';
import 'package:androiddex_host/services/settings_store.dart';
import 'package:androiddex_host/services/window_manager.dart';

void main() {
  group('SettingsStore validation', () {
    late Directory temp;

    setUpAll(() {
      temp = Directory.systemTemp.createTempSync('dex-settings-');
      AppPaths.debugInitUserDataDirForTests(temp.path);
      // A hand-edited or partially written file must not be able to put an
      // unknown codec or an out-of-range fps onto the scrcpy command line.
      File('${temp.path}${Platform.pathSeparator}settings.json')
          .writeAsStringSync('''
{
  "video_bitrate_mbps": 9999,
  "video_fps": 5000,
  "video_codec": "not-a-codec"
}
''');
    });

    tearDownAll(() {
      AppPaths.debugInitUserDataDirForTests(null);
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('clamps out-of-range transport values loaded from disk', () async {
      // SettingsStore is a singleton with a one-shot load, so this has to be
      // the single disk-read assertion for the file written in setUpAll.
      final store = SettingsStore.instance;
      await store.load();

      expect(store.videoBitrateMbps, SettingsStore.maxBitrateMbps);
      expect(store.videoFps, SettingsStore.maxVideoFps);
      expect(store.videoCodec, SettingsStore.defaultCodec);
    });

    test('setters reject values outside the supported range', () async {
      final store = SettingsStore.instance;

      await store.setVideoFps(9999);
      await store.setVideoBitrateMbps(500);
      await store.setVideoCodec('vp9');

      expect(store.videoFps, SettingsStore.maxVideoFps);
      expect(store.videoBitrateMbps, SettingsStore.maxBitrateMbps);
      expect(store.videoCodec, isNot('vp9'));
    });
  });

  group('ManagedWindow geometry', () {
    DesktopAppWindow window(String package) => DesktopAppWindow(
      app: AndroidAppInfo(
        name: package,
        packageName: package,
        versionName: '',
        iconBase64: '',
      ),
      startedAt: DateTime(2026),
      processId: 1,
    );

    test('clampInto never produces a negative origin', () {
      final managed = ManagedWindow(
        window: window('com.example.app'),
        origin: const Offset(-500, -300),
        extent: const Size(400, 300),
      );

      managed.clampInto(const Size(1200, 800), WindowManager.taskbarHeight);

      expect(managed.origin.dx, greaterThanOrEqualTo(0.0));
      expect(managed.origin.dy, greaterThanOrEqualTo(0.0));
      expect(managed.origin.dx, lessThanOrEqualTo(1200 - 400));
      expect(
        managed.origin.dy,
        lessThanOrEqualTo(800 - WindowManager.taskbarHeight - 300),
      );
    });

    test('restoring a snapped window captures a restore rect', () {
      final managed = ManagedWindow(
        window: window('com.example.app'),
        origin: const Offset(160, 80),
        extent: const Size(850, 520),
        snap: WindowSnap.left,
      );

      // Restoring must not throw and must leave the window tileable.
      expect(() => managed.unSnap(), returnsNormally);
      expect(managed.snap, WindowSnap.none);
      expect(managed.extent, const Size(850, 520));
    });

    test('re-tiling the same snap keeps the original restore rect', () {
      final managed = ManagedWindow(
        window: window('com.example.app'),
        origin: const Offset(160, 80),
        extent: const Size(850, 520),
      );
      final desktop = const Size(1200, 800);

      managed.applySnap(WindowSnap.left, desktop, WindowManager.taskbarHeight);
      expect(managed.origin, Offset.zero);
      final tiledLeft = managed.extent;

      // A second snap to the same edge (e.g. a desktop resize) must not
      // overwrite the pre-snap geometry with the already-tiled rect.
      managed.applySnap(WindowSnap.left, desktop, WindowManager.taskbarHeight);
      managed.unSnap();

      expect(managed.origin, const Offset(160, 80));
      expect(managed.extent, const Size(850, 520));
      expect(tiledLeft, isNot(managed.extent));
    });

    test('open carries a persisted snap through to the window', () {
      final manager = WindowManager();
      addTearDown(manager.dispose);

      final managed = manager.open(
        window('com.example.app'),
        origin: const Offset(160, 80),
        extent: const Size(850, 520),
        snap: WindowSnap.right,
      );

      expect(managed.snap, WindowSnap.right);
    });
  });
}
