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

  static Future<void> setVisible(bool visible) async {
    if (Platform.isWindows) {
      await _channel.invokeMethod<void>('visible', {'visible': visible});
    }
  }
}
