import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Positions native scrcpy surfaces inside Flutter-drawn desktop window frames.
class NativeDesktopWindows {
  NativeDesktopWindows._();

  static const _channel = MethodChannel('androiddex/windows');

  static Future<bool> embed(int processId, Rect rect) async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('embed', {
          'process_id': processId,
          'x': rect.left,
          'y': rect.top,
          'width': rect.width,
          'height': rect.height,
        }) ??
        false;
  }

  static Future<void> position(int processId, Rect rect) async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('position', {
      'process_id': processId,
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    });
  }

  static Future<void> focus(int processId) async {
    if (Platform.isWindows) {
      await _channel.invokeMethod<void>('focus', {'process_id': processId});
    }
  }

  /// Ask SDL to close cleanly so its Android virtual display is released.
  /// The caller may fall back to terminating the process if it does not exit.
  static Future<void> close(int processId) async {
    if (Platform.isWindows) {
      await _channel.invokeMethod<void>('close', {'process_id': processId});
    }
  }

  /// Shows or hides every embedded surface at once.
  static Future<void> setVisible(bool visible) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('visible', {'visible': visible});
    } catch (_) {
      // A stock runner without the handler must not fault the UI thread.
    }
  }

  /// Puts the host window into borderless fullscreen, or restores it.
  ///
  /// Fire-and-forget: a stock runner without the handler must not break the
  /// shortcut, so transport errors are swallowed.
  static void setFullscreen(bool value) =>
      _fireAndForget('fullscreen', {'fullscreen': value});

  /// Hides a single embedded surface without tearing the process down.
  static void setWindowVisible(int processId, bool visible) => _fireAndForget(
    'window_visible',
    {'process_id': processId, 'visible': visible},
  );

  /// Raises the embedded surface above its siblings.
  static void raise(int processId) =>
      _fireAndForget('raise', {'process_id': processId});

  static void _fireAndForget(String method, [Map<String, Object?>? args]) {
    if (!Platform.isWindows) return;
    unawaited(
      _channel.invokeMethod<void>(method, args).catchError((Object _) {}),
    );
  }

  /// Captures the current surface as PNG bytes for the Recents panel.
  ///
  /// Returns `null` when the surface cannot be captured (for example a
  /// GPU-composited window that refuses `PrintWindow`), so callers fall back
  /// to the app icon.
  static Future<Uint8List?> thumbnail(int processId) async {
    if (!Platform.isWindows) return null;
    try {
      final path = await _channel.invokeMethod<String>('thumbnail', {
        'process_id': processId,
      });
      if (path == null || path.isEmpty) return null;
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      unawaited(file.delete().then((_) {}, onError: (_) {}));
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }
}
