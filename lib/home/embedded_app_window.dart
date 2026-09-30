import 'dart:async';

import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../services/native_desktop_windows.dart';
import '../services/window_manager.dart';

/// A single embedded Android app window.
///
/// Geometry, tiling and z-order all come from [WindowManager]; this widget only
/// paints the Flutter chrome and keeps the native scrcpy surface locked to the
/// area it occupies. It listens to [WindowManager] for focus/minimize/maximize
/// changes so the frame and chrome repaint promptly.
@immutable
class EmbeddedAppWindow extends StatefulWidget {
  const EmbeddedAppWindow({
    super.key,
    required this.core,
    required this.managed,
    required this.desktop,
  });

  final AndroidCore core;
  final ManagedWindow managed;
  final Size desktop;

  @override
  State<EmbeddedAppWindow> createState() => _EmbeddedAppWindowState();
}

class _EmbeddedAppWindowState extends State<EmbeddedAppWindow> {
  final surface = GlobalKey();
  Timer? _retry;
  bool _attached = false;
  bool _busy = false;
  String? _error;
  int _attempts = 0;
  Rect? _lastSentRect;

  /// Set when a sync request arrives while one is already in flight; replayed
  /// by the in-flight call's `finally` block.
  bool _pendingSync = false;

  static const _maxAttachAttempts = 80;

  ManagedWindow get managed => widget.managed;
  int get processId => managed.window.processId;
  String get packageName => managed.packageName;

  @override
  void initState() {
    super.initState();
    widget.core.windows.addListener(_onWindowsChanged);
    _startSync();
  }

  @override
  void didUpdateWidget(covariant EmbeddedAppWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.core.windows != widget.core.windows) {
      oldWidget.core.windows.removeListener(_onWindowsChanged);
      widget.core.windows.addListener(_onWindowsChanged);
    }
  }

  @override
  void dispose() {
    widget.core.windows.removeListener(_onWindowsChanged);
    _retry?.cancel();
    super.dispose();
  }

  void _onWindowsChanged() {
    if (mounted) setState(() {});
  }

  /// Retries embed after an initial failed attempt, until the native
  /// surface is ready.
  ///
  /// The *first* attach attempt is driven by the post-frame callback in
  /// [build] so the window appears on the very first frame instead of after a
  /// 250ms tick; this timer owns retries only. Once attached the timer is
  /// cancelled and position updates come from the post-frame path. Giving
  /// each path exactly one job is what stops pre-attachment frames from
  /// firing duplicate `embed()` calls for a surface that is not ready yet.
  void _startSync() {
    _retry?.cancel();
    _retry = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _sync(allowAttach: true),
    );
  }

  /// Pushes the current surface rect to the runner.
  ///
  /// When a sync is already in flight the request is *coalesced* rather than
  /// dropped: [_pendingSync] replays it once the current call settles, so a
  /// drag that outruns the platform channel still lands on the final rect.
  Future<void> _sync({bool allowAttach = false}) async {
    if (!mounted || _error != null) return;
    if (_busy) {
      _pendingSync = true;
      return;
    }
    if (managed.minimized) return;
    final box = surface.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    // Once attached, an unchanged rect must not trigger another SetWindowPos —
    // every frame used to push a redundant position call to the runner.
    if (_attached && rect == _lastSentRect) return;
    // Attach responsibility: the first attempt is driven by the post-frame
    // callback so the surface appears on the very first frame rather than
    // after a 250ms timer tick; retries after a failure belong to the timer.
    // Without this split either path alone is wrong — timer-only shows an
    // empty window for a quarter second, frame-only never retries.
    final firstAttach = !_attached && _attempts == 0;
    if (!_attached && !allowAttach && !firstAttach) return;
    _busy = true;
    try {
      if (!_attached) {
        final ok = await NativeDesktopWindows.embed(processId, rect);
        if (!mounted) return;
        if (ok) {
          setState(() => _attached = true);
          _lastSentRect = rect;
          // Attachment succeeded: stop the retry timer permanently.
          _retry?.cancel();
          _retry = null;
        } else if (++_attempts >= _maxAttachAttempts) {
          setState(() => _error = 'Android window did not become ready.');
          _retry?.cancel();
          _retry = null;
        }
      } else {
        await NativeDesktopWindows.position(processId, rect);
        _lastSentRect = rect;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Unable to embed Android window: $e');
        _retry?.cancel();
        _retry = null;
      }
    } finally {
      _busy = false;
      if (_pendingSync) {
        _pendingSync = false;
        // Re-run on the next frame so the replay does not recurse through the
        // microtask queue.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_sync());
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final windows = widget.core.windows;
    final focused = windows.focusedPackage == packageName;
    if (managed.minimized) return const SizedBox.shrink();

    final width = managed.extent.width.clamp(
      ManagedWindow.minWidth,
      widget.desktop.width,
    );
    final height = managed.extent.height.clamp(
      ManagedWindow.minHeight,
      (widget.desktop.height - WindowManager.taskbarHeight).clamp(
        ManagedWindow.minHeight,
        double.infinity,
      ),
    );
    final left = managed.origin.dx.clamp(
      0.0,
      (widget.desktop.width - width).clamp(0.0, double.infinity),
    );
    final top = managed.origin.dy.clamp(
      0.0,
      (widget.desktop.height - WindowManager.taskbarHeight - height).clamp(
        0.0,
        double.infinity,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Material(
        elevation: focused ? 18 : 8,
        color: const Color(0xff151b24),
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            Column(
              children: [
                _titleBar(context, widget.desktop, windows),
                Expanded(
                  child: Container(
                    key: surface,
                    color: Colors.black,
                    alignment: Alignment.center,
                    child: _error != null
                        ? Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xFFFF6B6B)),
                            ),
                          )
                        : _attached
                        ? const SizedBox()
                        : const CircularProgressIndicator(),
                  ),
                ),
                _resizeGrip(width, height),
              ],
            ),
            // Slim hit zones inside each border for pointer resizing, in
            // addition to the corner grip below.
            _edgeResize(
              alignment: Alignment.centerLeft,
              width: 6,
              cursor: SystemMouseCursors.resizeLeftRight,
              onDrag: (delta) {
                managed.moveTo(
                  Offset(managed.origin.dx + delta.dx, managed.origin.dy),
                );
                managed.resizeTo(
                  Size(managed.extent.width - delta.dx, managed.extent.height),
                );
              },
            ),
            _edgeResize(
              alignment: Alignment.centerRight,
              width: 6,
              cursor: SystemMouseCursors.resizeLeftRight,
              onDrag: (delta) => managed.resizeTo(
                Size(managed.extent.width + delta.dx, managed.extent.height),
              ),
            ),
            _edgeResize(
              alignment: Alignment.topCenter,
              height: 6,
              cursor: SystemMouseCursors.resizeUpDown,
              onDrag: (delta) {
                managed.moveTo(
                  Offset(managed.origin.dx, managed.origin.dy + delta.dy),
                );
                managed.resizeTo(
                  Size(managed.extent.width, managed.extent.height - delta.dy),
                );
              },
            ),
            _edgeResize(
              alignment: Alignment.bottomCenter,
              height: 6,
              cursor: SystemMouseCursors.resizeUpDown,
              onDrag: (delta) => managed.resizeTo(
                Size(managed.extent.width, managed.extent.height + delta.dy),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The classic bottom-right grip: dragging resizes from the corner.
  Widget _resizeGrip(double width, double height) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (event) => setState(() {
        managed.resizeTo(Size(width + event.delta.dx, height + event.delta.dy));
      }),
      child: Container(
        height: 18,
        alignment: Alignment.centerRight,
        color: const Color(0xff222b38),
        child: const Icon(Icons.drag_handle, size: 16),
      ),
    );
  }

  /// A slim invisible strip anchored to one window edge; dragging it resizes
  /// the window through the [WindowManager] geometry.
  Widget _edgeResize({
    required Alignment alignment,
    required MouseCursor cursor,
    required ValueChanged<Offset> onDrag,
    double? width,
    double? height,
  }) {
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (event) => setState(() => onDrag(event.delta)),
          child: MouseRegion(
            cursor: cursor,
            child: SizedBox(width: width, height: height),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(BuildContext context, Size desktop, WindowManager windows) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        windows.focus(packageName);
        unawaited(NativeDesktopWindows.focus(processId));
      },
      onDoubleTap: () => windows.toggleMaximize(packageName, desktop),
      onPanUpdate: (event) {
        setState(() {
          managed.moveTo(managed.origin + event.delta);
        });
        // Dragging the title bar against the top edge maximizes, mirroring
        // the DeX/Windows drag-to-top snap affordance.
        if (!managed.maximized && managed.origin.dy <= 0) {
          windows.toggleMaximize(packageName, desktop);
        }
      },
      child: Container(
        height: 38,
        padding: const EdgeInsets.only(left: 14),
        color: const Color(0xff222b38),
        child: Row(
          children: [
            const Icon(Icons.android, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                managed.window.app.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Snap window left',
              onPressed: () =>
                  windows.snap(packageName, WindowSnap.left, desktop),
              icon: const Icon(Icons.align_horizontal_left, size: 17),
            ),
            IconButton(
              tooltip: 'Snap window right',
              onPressed: () =>
                  windows.snap(packageName, WindowSnap.right, desktop),
              icon: const Icon(Icons.align_horizontal_right, size: 17),
            ),
            IconButton(
              tooltip: managed.maximized ? 'Restore window' : 'Maximize window',
              onPressed: () => windows.toggleMaximize(packageName, desktop),
              icon: Icon(
                managed.maximized ? Icons.fullscreen_exit : Icons.fullscreen,
                size: 18,
              ),
            ),
            IconButton(
              tooltip: 'Minimize window',
              onPressed: () => windows.minimize(packageName),
              icon: const Icon(Icons.remove, size: 18),
            ),
            IconButton(
              tooltip: 'Close app window',
              onPressed: () => widget.core.closeAppWindow(managed.window),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
