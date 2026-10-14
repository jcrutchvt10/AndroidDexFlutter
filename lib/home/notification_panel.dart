import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../host/notification_data_manager.dart';

/// Notification Center: the device notification stream, grouped by app.
///
/// Replaces the reference implementation's tray balloons with a real panel fed
/// by the 3700 callback channel.
class NotificationPanel extends StatelessWidget {
  const NotificationPanel({super.key, required this.core});

  final AndroidCore core;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: core.notifications,
      builder: (context, _) {
        final manager = core.notifications;
        if (manager.isEmpty) {
          return _EmptyState(
            connected: manager.connected,
            message: manager.connected
                ? 'No notifications yet.'
                : 'Waiting for notification access on the device…',
          );
        }
        final groups = manager.byPackage;
        return Column(
          children: [
            if (!manager.connected) const _OfflineBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: [
                  Text(
                    '${manager.unreadCount} notification'
                    '${manager.unreadCount == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: manager.clearAll,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('Clear all'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  for (final entry in groups.entries)
                    _PackageGroup(
                      packageName: entry.key,
                      items: entry.value,
                      onClear: () => manager.clearPackage(entry.key),
                      onDismiss: manager.remove,
                      onOpen: core.launchAppByPackage,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PackageGroup extends StatelessWidget {
  const _PackageGroup({
    required this.packageName,
    required this.items,
    required this.onClear,
    required this.onDismiss,
    required this.onOpen,
  });

  final String packageName;
  final List<DexNotification> items;
  final VoidCallback onClear;
  final void Function(String key) onDismiss;
  final void Function(String packageName) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: Colors.white.withValues(alpha: 0.06),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
            child: Row(
              children: [
                const Icon(Icons.notifications_outlined, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    items.first.label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text('${items.length}', style: theme.textTheme.bodySmall),
                IconButton(
                  tooltip: 'Open $packageName',
                  onPressed: () => onOpen(packageName),
                  icon: const Icon(Icons.open_in_new, size: 16),
                ),
                IconButton(
                  tooltip: 'Clear all from $packageName',
                  onPressed: onClear,
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
          ),
          for (final item in items)
            ListTile(
              dense: true,
              onTap: () => onOpen(packageName),
              mouseCursor: SystemMouseCursors.click,
              leading: Icon(
                item.ongoing ? Icons.sync : Icons.circle_notifications_outlined,
                size: 20,
              ),
              title: Text(
                item.title.isEmpty ? item.label : item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${item.body}\n${formatRelativeTime(item.timestamp)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              trailing: IconButton(
                tooltip: 'Dismiss notification',
                onPressed: () => onDismiss(item.key),
                icon: const Icon(Icons.clear, size: 16),
              ),
            ),
        ],
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Colors.orange.withValues(alpha: 0.16),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: const Text(
      'Notification access is not granted on the device. '
      'Some notifications will be missing.',
      style: TextStyle(fontSize: 12),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.connected, required this.message});

  final bool connected;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(connected ? Icons.notifications_none : Icons.link_off, size: 40),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(message, textAlign: TextAlign.center),
        ),
      ],
    ),
  );
}

/// Compact "5m ago" formatting, kept locale-free on purpose.
String formatRelativeTime(DateTime timestamp) {
  final delta = DateTime.now().difference(timestamp);
  if (delta.inSeconds < 60) return 'Just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}
