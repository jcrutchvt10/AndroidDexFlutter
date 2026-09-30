import 'package:flutter/foundation.dart';

import '../core/json_read.dart';

/// One mirrored notification. Metadata only — no action intents are executed.
@immutable
class DexNotification {
  const DexNotification({
    required this.key,
    required this.packageName,
    required this.appName,
    required this.title,
    required this.text,
    required this.timestamp,
    required this.ongoing,
    this.iconBase64 = '',
  });

  final String key;
  final String packageName;
  final String appName;
  final String title;
  final String text;
  final DateTime timestamp;
  final bool ongoing;
  final String iconBase64;

  String get label => appName.isNotEmpty ? appName : packageName;

  String get body => text.isNotEmpty ? text : title;

  bool hasSamePresentationAs(DexNotification other) =>
      key == other.key &&
      packageName == other.packageName &&
      appName == other.appName &&
      title == other.title &&
      text == other.text &&
      ongoing == other.ongoing &&
      iconBase64 == other.iconBase64;

  static DexNotification? fromJson(Map<String, dynamic> json) {
    final source =
        readObject(json, const ['notification', 'notify', 'data']) ?? json;
    final key = readString(source, const ['key', 'id', 'notification_id']);
    final package = readString(source, const ['package', 'package_name']);
    final title = readString(source, const ['title']);
    final text = readString(source, const ['text', 'body', 'content']);
    if (key.isEmpty && package.isEmpty && title.isEmpty && text.isEmpty) {
      return null;
    }
    final stamp = readInt(source, const ['timestamp', 'time', 'when']);
    return DexNotification(
      key: key.isEmpty ? '$package-$title' : key,
      packageName: package,
      appName: readString(source, const ['app_name', 'appName', 'app_label']),
      title: title,
      text: text,
      timestamp: stamp == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(
              stamp < 100000000000 ? stamp * 1000 : stamp,
            ),
      ongoing: readBool(source, const ['ongoing', 'is_ongoing']) ?? false,
    );
  }
}

/// Bounded notification stream mirroring the reference device behaviour:
/// newest first, grouped by package, capped ring.
class NotificationDataManager extends ChangeNotifier {
  /// Matches the bounded ring used by the reference notification bridge.
  static const maxEntries = 24;

  final List<DexNotification> _items = [];
  bool _connected = false;

  bool get connected => _connected;

  /// Connection state as a listenable for completer-based waiters.
  ValueListenable<bool> get connectedListenable => _connectedListenable;
  final ValueNotifier<bool> _connectedListenable = ValueNotifier<bool>(false);

  List<DexNotification> get items => List.unmodifiable(_items);
  int get unreadCount => _items.length;
  bool get isEmpty => _items.isEmpty;

  /// Newest-first, grouped by package, preserving arrival order of groups.
  Map<String, List<DexNotification>> get byPackage {
    final groups = <String, List<DexNotification>>{};
    for (final item in _items) {
      groups.putIfAbsent(item.packageName, () => []).add(item);
    }
    return groups;
  }

  void markConnected() {
    if (_connected) return;
    _connected = true;
    _connectedListenable.value = true;
    notifyListeners();
  }

  void markDisconnected() {
    if (!_connected) return;
    _connected = false;
    _connectedListenable.value = false;
    notifyListeners();
  }

  /// Applies one decoded message from the notification channel.
  void apply(Map<String, dynamic> json) {
    if (isHandshake(json, 'notification.hello')) {
      markConnected();
      return;
    }
    final type = messageType(json);
    if (type == 'notification.clear' || type == 'notification.removed') {
      final key = readString(json, const ['key', 'id']);
      if (key.isNotEmpty) remove(key);
      return;
    }
    if (type == 'notification.clear_all') {
      clearAll();
      return;
    }
    // A bulk resend after reconnect arrives as a list.
    final bulk = readObjects(json, const ['notifications', 'items', 'data']);
    if (bulk.isNotEmpty) {
      for (final entry in bulk) {
        final parsed = DexNotification.fromJson(entry);
        if (parsed != null) push(parsed);
      }
      return;
    }
    final parsed = DexNotification.fromJson(json);
    if (parsed != null) push(parsed);
  }

  void push(DexNotification notification) {
    final existingIndex = _items.indexWhere(
      (item) => item.key == notification.key,
    );
    if (existingIndex == 0 &&
        _items.first.hasSamePresentationAs(notification)) {
      return;
    }
    if (existingIndex >= 0) {
      _items.removeAt(existingIndex);
    }
    _items.insert(0, notification);
    if (_items.length > maxEntries) {
      _items.removeRange(maxEntries, _items.length);
    }
    notifyListeners();
  }

  void remove(String key) {
    final before = _items.length;
    _items.removeWhere((item) => item.key == key);
    if (_items.length != before) notifyListeners();
  }

  void clearPackage(String packageName) {
    final before = _items.length;
    _items.removeWhere((item) => item.packageName == packageName);
    if (_items.length != before) notifyListeners();
  }

  void clearAll() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }
}
