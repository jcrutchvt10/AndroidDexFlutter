import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'native_desktop_windows.dart';

/// How a window is currently tiled.
enum WindowSnap {
  none,
  left,
  right,
  maximized,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// Mutable per-window geometry and lifecycle state.
///
/// Geometry lives here rather than in widget state so snapping, maximizing and
/// z-ordering all operate on one source of truth.
class ManagedWindow {
  ManagedWindow({
    required this.window,
    required this.origin,
    required this.extent,
    this.snap = WindowSnap.none,
    this.pinned = false,
  });

  final DesktopAppWindow window;

  Offset origin;
  Size extent;

  WindowSnap snap;
  bool minimized = false;
  bool pinned = false;
  Offset? _restoreOrigin;
  Size? _restoreExtent;

  String get packageName => window.packageName;
  bool get maximized => snap == WindowSnap.maximized;

  void togglePin() => pinned = !pinned;

  /// Windows cannot be shrunk below the usable minimum.
  static const minWidth = 320.0;
  static const minHeight = 240.0;

  void moveTo(Offset value) {
    if (snap != WindowSnap.none) unSnap(); // Dragging un-snaps and restores geometry.
    origin = value;
  }

  void resizeTo(Size value) {
    if (snap != WindowSnap.none) unSnap();
    extent = Size(
      value.width.clamp(minWidth, 4096.0),
      value.height.clamp(minHeight, 4096.0),
    );
  }

  /// Tiles the window using the supplied desktop geometry.
  void applySnap(WindowSnap target, Size desktop, double taskbarHeight) {
    if (target == WindowSnap.none) {
      snap = WindowSnap.none;
      return;
    }
    final usableHeight = (desktop.height - taskbarHeight).clamp(
      minHeight,
      double.infinity,
    );
    // Save the pre-snap geometry so un-snap can restore it. When re-tiling
    // the same snap (desktop resize) we must not clobber the saved restore
    // rect — but if none was saved yet (a restored snapped window), capture
    // its current geometry so the user can un-snap it later.
    if (snap != target) {
      _restoreOrigin = origin;
      _restoreExtent = extent;
    } else if (_restoreOrigin == null) {
      _restoreOrigin = origin;
      _restoreExtent = extent;
    }
    minimized = false;
    snap = target;
    final halfWidth = desktop.width / 2;
    final halfHeight = usableHeight / 2;
    switch (target) {
      case WindowSnap.left:
        origin = Offset.zero;
        extent = Size(halfWidth, usableHeight);
      case WindowSnap.right:
        origin = Offset(halfWidth, 0);
        extent = Size(halfWidth, usableHeight);
      case WindowSnap.maximized:
        origin = Offset.zero;
        extent = Size(desktop.width, usableHeight);
      case WindowSnap.topLeft:
        origin = Offset.zero;
        extent = Size(halfWidth, halfHeight);
      case WindowSnap.topRight:
        origin = Offset(halfWidth, 0);
        extent = Size(halfWidth, halfHeight);
      case WindowSnap.bottomLeft:
        origin = Offset(0, halfHeight);
        extent = Size(halfWidth, halfHeight);
      case WindowSnap.bottomRight:
        origin = Offset(halfWidth, halfHeight);
        extent = Size(halfWidth, halfHeight);
      case WindowSnap.none:
        break;
    }
  }

  /// Restores the pre-snap geometry.
  void unSnap() {
    snap = WindowSnap.none;
    if (_restoreOrigin != null) origin = _restoreOrigin!;
    if (_restoreExtent != null) extent = _restoreExtent!;
  }

  void toggleMaximize(Size desktop, double taskbarHeight) => maximized
      ? unSnap()
      : applySnap(WindowSnap.maximized, desktop, taskbarHeight);

  void clampInto(Size desktop, double taskbarHeight) {
    if (snap != WindowSnap.none) {
      applySnap(snap, desktop, taskbarHeight);
      return;
    }
    final maxX = (desktop.width - extent.width).clamp(0.0, double.infinity);
    final maxY = (desktop.height - taskbarHeight - extent.height).clamp(
      0.0,
      double.infinity,
    );
    origin = Offset(origin.dx.clamp(0.0, maxX), origin.dy.clamp(0.0, maxY));
  }

  Rect get rect => origin & extent;
}

/// Tracks every open app window: creation, focus, z-order, tiling, lifecycle.
///
/// Paint order is the list order — the last entry is the topmost window, which
/// is also the focused one.
class WindowManager extends ChangeNotifier {
  static const taskbarHeight = 76.0;

  final List<ManagedWindow> _windows = [];

  List<ManagedWindow> get ordered => List.unmodifiable(_windows);
  int get length => _windows.length;
  bool get isEmpty => _windows.isEmpty;

  ManagedWindow? get focused => _windows.isEmpty ? null : _windows.last;
  String? get focusedPackage => focused?.packageName;

  bool isOpen(String packageName) =>
      _windows.any((entry) => entry.packageName == packageName);

  ManagedWindow? forPackage(String packageName) {
    for (final entry in _windows) {
      if (entry.packageName == packageName) return entry;
    }
    return null;
  }

  /// Registers a newly launched window, focusing it immediately.
  ManagedWindow open(
    DesktopAppWindow window, {
    required Offset origin,
    required Size extent,
    WindowSnap snap = WindowSnap.none,
  }) {
    final existing = forPackage(window.packageName);
    if (existing != null) {
      focus(window.packageName);
      return existing;
    }
    final managed = ManagedWindow(
      window: window,
      origin: origin,
      extent: extent,
      snap: snap,
    );
    _windows.add(managed);
    notifyListeners();
    return managed;
  }

  void close(String packageName) {
    final before = _windows.length;
    _windows.removeWhere((entry) => entry.packageName == packageName);
    if (_windows.length != before) notifyListeners();
  }

  /// Raises a window to the top of the z-order.
  void focus(String packageName) {
    final entry = forPackage(packageName);
    if (entry == null) return;
    final wasMinimized = entry.minimized;
    entry.minimized = false;
    if (identical(_windows.last, entry)) {
      if (wasMinimized) {
        // Even if already focused, ensure Win32 HWND is on top after restore.
        NativeDesktopWindows.raise(entry.window.processId);
        notifyListeners();
      }
      return;
    }
    _windows
      ..remove(entry)
      ..add(entry);
    // Keep Win32 sibling z-order in sync with Dart focus order.
    NativeDesktopWindows.raise(entry.window.processId);
    notifyListeners();
  }

  /// Focuses the next window in the z-order (Alt+Tab style cycling).
  void cycleFocus() {
    if (_windows.length < 2) return;
    final top = _windows.removeLast();
    _windows.insert(0, top);
    notifyListeners();
  }

  void minimize(String packageName) {
    final entry = forPackage(packageName);
    if (entry == null || entry.minimized) return;
    entry.minimized = true;
    // A minimized window drops out of the focus order.
    _windows
      ..remove(entry)
      ..insert(0, entry);
    notifyListeners();
  }

  void restore(String packageName) {
    final entry = forPackage(packageName);
    if (entry == null) return;
    entry.minimized = false;
    focus(packageName);
  }

  void toggleMinimize(String packageName) {
    final entry = forPackage(packageName);
    if (entry == null) return;
    if (entry.minimized) {
      restore(packageName);
    } else {
      minimize(packageName);
    }
  }

  void snap(String packageName, WindowSnap target, Size desktop) {
    final entry = forPackage(packageName);
    if (entry == null) return;
    entry.applySnap(target, desktop, taskbarHeight);
    focus(packageName);
  }

  void toggleMaximize(String packageName, Size desktop) {
    final entry = forPackage(packageName);
    if (entry == null) return;
    entry.toggleMaximize(desktop, taskbarHeight);
    focus(packageName);
  }

  void togglePin(String packageName) {
    final entry = forPackage(packageName);
    if (entry == null) return;
    entry.togglePin();
    notifyListeners();
  }

  /// Re-tiles and clamps everything after a desktop resize.
  void relayout(Size desktop) {
    if (_windows.isEmpty) return;
    for (final entry in _windows) {
      entry.clampInto(desktop, taskbarHeight);
    }
    notifyListeners();
  }

  void clear() {
    if (_windows.isEmpty) return;
    _windows.clear();
    notifyListeners();
  }
}
