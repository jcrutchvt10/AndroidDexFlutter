import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../host/notification_data_manager.dart';

/// Bridges [NotificationDataManager] events to a tiny event stream that the
/// toast overlay consumes. Emits one event per notable change so the overlay
/// can animate in/out without owning the device connection itself.
///
/// Lives beside the overlay widget it feeds — the split across `home/` and
/// `services/` made imports ambiguous.
class NotificationToastBridge {
  NotificationToastBridge(this.core) {
    core.notifications.addListener(_onManagerChanged);
  }

  final AndroidCore core;

  final _controller = StreamController<ToastEvent>.broadcast();
  Stream<ToastEvent> get events => _controller.stream;

  String? _lastKey;
  DexNotification? _lastNotification;

  void _onManagerChanged() {
    final manager = core.notifications;
    if (!manager.connected) {
      _controller.add(const ToastEvent(kind: ToastKind.disconnected));
      _lastKey = null;
      _lastNotification = null;
      return;
    }
    if (manager.isEmpty) {
      if (_lastKey != null) {
        _controller.add(const ToastEvent(kind: ToastKind.clearAll));
        _lastKey = null;
        _lastNotification = null;
      }
      return;
    }
    final latest = manager.items.first;
    if (latest.ongoing) {
      _lastKey = latest.key;
      _lastNotification = latest;
      return;
    }
    if (latest.key == _lastKey) {
      if (_lastNotification?.hasSamePresentationAs(latest) ?? false) {
        return;
      }
      _lastNotification = latest;
      _controller.add(
        ToastEvent(
          key: latest.key,
          kind: ToastKind.refreshed,
          notification: latest,
        ),
      );
      return;
    }
    _controller.add(
      ToastEvent(
        key: latest.key,
        kind: ToastKind.newArrival,
        notification: latest,
      ),
    );
    _lastKey = latest.key;
    _lastNotification = latest;
  }

  void dismiss(String key) {
    if (key != _lastKey) return;
    _lastKey = null;
    _lastNotification = null;
    _controller.add(ToastEvent(key: key, kind: ToastKind.dismissed));
  }

  void clearAll() {
    _lastKey = null;
    _lastNotification = null;
    _controller.add(const ToastEvent(kind: ToastKind.clearAll));
  }

  void dispose() {
    core.notifications.removeListener(_onManagerChanged);
    _controller.close();
  }
}

enum ToastKind { newArrival, refreshed, dismissed, clearAll, disconnected }

class ToastEvent {
  const ToastEvent({required this.kind, this.key = '', this.notification});

  final ToastKind kind;
  final String key;
  final DexNotification? notification;
}

/// Constants controlling toast appearance and timing.
class _ToastConstants {
  static const Duration dismissDelay = Duration(seconds: 6);
  static const double maxWidth = 360.0;
  static const double rightMargin = 16.0;
  static const double slideOffset = 40.0;
}

/// Overlay widget that renders toast notifications for incoming device
/// notifications. Anchors to the top-right of the desktop and stacks
/// vertically with a slide + fade entrance and a progress bar for the
/// auto-dismiss countdown.
class NotificationToastOverlay extends StatefulWidget {
  const NotificationToastOverlay({
    super.key,
    required this.core,
    required this.bridge,
  });

  final AndroidCore core;
  final NotificationToastBridge bridge;

  @override
  State<NotificationToastOverlay> createState() =>
      _NotificationToastOverlayState();
}

class _NotificationToastOverlayState extends State<NotificationToastOverlay>
    with SingleTickerProviderStateMixin {
  final List<_ToastEntry> _entries = [];

  /// One pending auto-dismiss timer per toast key.
  ///
  /// Keying by toast key (rather than firing a fire-and-forget `Timer` per
  /// event) is what makes a *reset* possible: a notification that keeps
  /// updating in place must have its countdown restarted, otherwise it never
  /// expires.
  final Map<String, Timer> _dismissTimers = {};
  StreamSubscription<ToastEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.bridge.events.listen(_onEvent);
  }

  @override
  void didUpdateWidget(NotificationToastOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bridge != widget.bridge) {
      _subscription?.cancel();
      _subscription = widget.bridge.events.listen(_onEvent);
    }
  }

  void _onEvent(ToastEvent event) {
    switch (event.kind) {
      case ToastKind.newArrival:
        _showNew(event);
      case ToastKind.refreshed:
        _refresh(event);
      case ToastKind.dismissed:
        _remove(event.key);
      case ToastKind.clearAll:
        _clearAll();
      case ToastKind.disconnected:
        _clearAll();
    }
  }

  void _showNew(ToastEvent event) {
    final index = _entries.indexWhere((e) => e.key == event.key);
    if (index >= 0) {
      final entry = _entries[index];
      entry.notification = event.notification!;
      entry.controller
        ..reset()
        ..forward();
      _entries.removeAt(index);
      _entries.insert(0, entry);
      _stackPositions();
      if (mounted) setState(() {});
      _startDismissTimer(event.key);
      return;
    }
    _entries.insert(
      0,
      _ToastEntry(
        key: event.key,
        notification: event.notification!,
        controller: AnimationController(
          duration: const Duration(milliseconds: 280),
          vsync: this,
        )..forward(),
      ),
    );
    _stackPositions();
    if (mounted) setState(() {});
    _startDismissTimer(event.key);
  }

  void _refresh(ToastEvent event) {
    final index = _entries.indexWhere((e) => e.key == event.key);
    if (index < 0) return;
    _entries[index].notification = event.notification!;
    // A refreshed notification (same key, new content — e.g. a download
    // ticking from 10% to 80%) replaces the content in place rather than
    // re-entering, so its countdown would otherwise never restart and the
    // toast would linger well past the dismiss delay.
    _startDismissTimer(event.key);
    if (mounted) setState(() {});
  }

  void _remove(String key) {
    _dismissTimers.remove(key)?.cancel();
    final index = _entries.indexWhere((e) => e.key == key);
    if (index < 0) return;
    final entry = _entries.removeAt(index);
    entry.controller
        .animateTo(0.0, duration: const Duration(milliseconds: 220))
        .then((_) {
          entry.controller.dispose();
          if (mounted) {
            _stackPositions();
            setState(() {});
          }
        });
  }

  void _clearAll() {
    for (final timer in _dismissTimers.values) {
      timer.cancel();
    }
    _dismissTimers.clear();
    final toDispose = _entries.toSet();
    _entries.clear();
    for (final entry in toDispose) {
      entry.controller
          .animateTo(0.0, duration: const Duration(milliseconds: 200))
          .then((_) => entry.controller.dispose());
    }
    if (mounted) setState(() {});
  }

  void _stackPositions() {
    // Offset is computed during build from index; nothing to store here.
  }

  void _startDismissTimer(String key) {
    // Cancel first: re-arming for a key that already has a pending timer is
    // the normal path for a refreshed notification, and two live timers would
    // both fire and animate the same toast out twice.
    _dismissTimers[key]?.cancel();
    _dismissTimers[key] = Timer(_ToastConstants.dismissDelay, () {
      if (mounted) _remove(key);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    for (final timer in _dismissTimers.values) {
      timer.cancel();
    }
    _dismissTimers.clear();
    for (final entry in _entries) {
      entry.controller.dispose();
    }
    _entries.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) return const SizedBox.shrink();

    // Iterate a snapshot and bind each entry to a local. Reading `_entries[i]`
    // from inside the `AnimatedBuilder` builder (rather than from the local)
    // deferred the lookup until the next animation tick, by which time the
    // list could have shrunk and thrown a RangeError — which happens whenever
    // one toast animates out while another is still on screen.
    final entries = List<_ToastEntry>.of(_entries);

    return Positioned.fill(
      child: Stack(
        children: [
          for (final entry in entries)
            AnimatedBuilder(
              animation: entry.controller,
              builder: (context, child) {
                final alpha = entry.controller.value;
                final offsetY = (1 - alpha) * _ToastConstants.slideOffset;
                return Transform.translate(
                  offset: Offset(0, offsetY),
                  child: Opacity(opacity: alpha, child: child),
                );
              },
              child: _ToastCard(
                key: ValueKey(entry.key),
                notification: entry.notification,
                progress: entry.progress,
                onDismiss: () => widget.bridge.dismiss(entry.key),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToastEntry {
  _ToastEntry({
    required this.key,
    required this.notification,
    required this.controller,
  });

  final String key;
  late DexNotification notification;
  final AnimationController controller;
  double progress = 0.0;
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({
    super.key,
    required this.notification,
    required this.progress,
    required this.onDismiss,
  });

  final DexNotification notification;
  final double progress;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = _notificationIcon(
      context: context,
      packageName: notification.packageName,
      appName: notification.appName,
      iconBase64: notification.iconBase64,
    );

    return IgnorePointer(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: _ToastConstants.maxWidth,
          margin: EdgeInsets.only(
            top: 12,
            right: _ToastConstants.rightMargin,
            left: 12,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF25303B),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                  color: const Color(0xFF3A4A5A),
                ),
                child: Row(
                  children: [
                    SizedBox(width: 32, height: 32, child: icon),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DefaultTextStyle(
                        style: theme.textTheme.titleSmall!.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                        child: Text(
                          notification.title.isEmpty
                              ? notification.label
                              : notification.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: onDismiss,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
              if (notification.body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  child: Text(
                    notification.body,
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: Colors.white.withValues(alpha: 0.75),
                      height: 1.25,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (progress > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.white.withValues(alpha: 0.5),
                      ),
                      minHeight: 2.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _notificationIcon({
    required BuildContext context,
    required String packageName,
    required String appName,
    required String iconBase64,
  }) {
    try {
      if (iconBase64.isNotEmpty) {
        return Image.memory(
          base64Decode(iconBase64),
          width: 32,
          height: 32,
          errorBuilder: (_, _, _) => _defaultIcon(context: context),
        );
      }
    } catch (_) {
      // fall through
    }
    return _defaultIcon(context: context);
  }

  Widget _defaultIcon({required BuildContext context}) {
    final short = notification.packageName.split('.').last;
    final seed = notification.packageName.hashCode & 0xFFFFFF;
    final color = Color(0xFF10000000 | seed);
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          short.isNotEmpty ? short[0].toUpperCase() : '?',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
