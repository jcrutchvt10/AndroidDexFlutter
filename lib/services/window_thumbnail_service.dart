import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_desktop_windows.dart';

/// Captures and caches thumbnail frames of embedded Android windows.
///
/// Feeds the Recents / Task View panel. Capture is best effort: a surface that
/// refuses `PrintWindow` simply yields no thumbnail and the panel falls back to
/// the app icon.
class WindowThumbnailService extends ChangeNotifier {
  WindowThumbnailService._();

  static final WindowThumbnailService instance = WindowThumbnailService._();

  /// Minimum age before a cached frame is refreshed.
  static const refreshInterval = Duration(seconds: 5);

  final Map<int, Uint8List> _frames = {};
  final Map<int, DateTime> _capturedAt = {};
  bool _busy = false;

  bool get busy => _busy;

  Uint8List? frameFor(int processId) => _frames[processId];

  bool needsRefresh(int processId) {
    final stamp = _capturedAt[processId];
    if (stamp == null) return true;
    return DateTime.now().difference(stamp) > refreshInterval;
  }

  /// Captures stale frames for [processIds] one at a time.
  Future<void> refresh(Iterable<int> processIds) async {
    if (_busy) return;
    _busy = true;
    try {
      for (final processId in processIds) {
        if (!needsRefresh(processId)) continue;
        final frame = await NativeDesktopWindows.thumbnail(processId);
        if (frame == null) {
          // Record the attempt so a hostile surface is not retried in a loop.
          _capturedAt[processId] = DateTime.now();
          continue;
        }
        _frames[processId] = frame;
        _capturedAt[processId] = DateTime.now();
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
  }

  void forget(int processId) {
    final removed = _frames.remove(processId) != null;
    _capturedAt.remove(processId);
    if (removed) notifyListeners();
  }

  void clear() {
    if (_frames.isEmpty && _capturedAt.isEmpty) return;
    _frames.clear();
    _capturedAt.clear();
    notifyListeners();
  }
}
