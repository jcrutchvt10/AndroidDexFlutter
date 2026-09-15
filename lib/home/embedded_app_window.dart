import 'dart:async';

import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../services/native_desktop_windows.dart';

class EmbeddedAppWindow extends StatefulWidget {
  const EmbeddedAppWindow({
    super.key,
    required this.window,
    required this.bounds,
    required this.onClose,
  });
  final DesktopAppWindow window;
  final Size bounds;
  final VoidCallback onClose;
  @override
  State<EmbeddedAppWindow> createState() => _EmbeddedAppWindowState();
}

class _EmbeddedAppWindowState extends State<EmbeddedAppWindow> {
  final surface = GlobalKey();
  Offset origin = const Offset(160, 80);
  Size extent = const Size(850, 520);
  Timer? retry;
  bool attached = false;
  bool busy = false;
  String? error;
  int attempts = 0;
  @override
  void initState() {
    super.initState();
    retry = Timer.periodic(const Duration(milliseconds: 250), (_) => sync());
  }

  Future<void> sync() async {
    if (!mounted || busy || error != null) return;
    final box = surface.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    busy = true;
    try {
      if (!attached) {
        final ok = await NativeDesktopWindows.embed(
          widget.window.processId,
          rect,
        );
        if (!mounted) return;
        if (ok) {
          setState(() => attached = true);
          retry?.cancel();
        } else if (++attempts >= 80) {
          retry?.cancel();
          setState(
            () => error =
                'Android window did not become ready. Close it and try again.',
          );
        }
      } else {
        await NativeDesktopWindows.position(widget.window.processId, rect);
      }
    } catch (failure) {
      if (mounted) {
        setState(() => error = 'Unable to embed Android window: $failure');
      }
      retry?.cancel();
    } finally {
      busy = false;
    }
  }

  @override
  void dispose() {
    retry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = extent.width.clamp(
      280.0,
      widget.bounds.width.clamp(280.0, double.infinity),
    );
    final height = extent.height.clamp(
      200.0,
      (widget.bounds.height - 76).clamp(200.0, double.infinity),
    );
    final left = origin.dx.clamp(
      0.0,
      (widget.bounds.width - width).clamp(0.0, double.infinity),
    );
    final top = origin.dy.clamp(
      0.0,
      (widget.bounds.height - 76 - height).clamp(0.0, double.infinity),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => sync());
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Material(
        elevation: 16,
        color: const Color(0xff151b24),
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            GestureDetector(
              onPanUpdate: (event) =>
                  setState(() => origin = Offset(left, top) + event.delta),
              onTap: () => NativeDesktopWindows.focus(widget.window.processId),
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
                        widget.window.app.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close app window',
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Container(
                key: surface,
                color: Colors.black,
                alignment: Alignment.center,
                child: error != null
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(error!),
                      )
                    : attached
                    ? const SizedBox()
                    : const CircularProgressIndicator(),
              ),
            ),
            GestureDetector(
              onPanUpdate: (event) => setState(
                () => extent = Size(
                  width + event.delta.dx,
                  height + event.delta.dy,
                ),
              ),
              child: Container(
                height: 18,
                alignment: Alignment.centerRight,
                color: const Color(0xff222b38),
                child: const Icon(Icons.drag_handle, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
