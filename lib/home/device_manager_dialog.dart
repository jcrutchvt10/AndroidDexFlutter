import 'dart:async';

import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../core/error_messages.dart';
import '../services/device_manager.dart';

/// ADB Manager dialog.
///
/// Opened in exactly two situations, matching the reference contract: before
/// boot when zero or several devices are attached, and after a connection
/// failure — never speculatively. The barrier is transparent so the boot
/// screen's own backdrop stays visible behind it.
class DeviceManagerDialog extends StatefulWidget {
  const DeviceManagerDialog({super.key, required this.core, this.reason});

  final AndroidCore core;

  /// Why the dialog was opened; rendered as a banner when provided.
  final String? reason;

  /// Opens the dialog and applies the chosen device to [core].
  ///
  /// Returns `true` when the user picked a device, which means the caller
  /// should expect a boot retry to already be underway.
  static Future<bool> show(
    BuildContext context, {
    required AndroidCore core,
    String? reason,
  }) async {
    final selected = await showDialog<String>(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      builder: (_) => DeviceManagerDialog(core: core, reason: reason),
    );
    if (selected == null) return false;
    core.devices.selectDevice(selected);
    await core.settings.setLastDevice(selected);
    await core.retryBoot();
    return true;
  }

  @override
  State<DeviceManagerDialog> createState() => _DeviceManagerDialogState();
}

class _DeviceManagerDialogState extends State<DeviceManagerDialog> {
  final _ipController = TextEditingController();
  List<AdbDevice> _devices = const [];
  bool _scanning = true;
  bool _connecting = false;
  String? _ipError;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final devices = await widget.core.refreshDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _scanning = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _devices = const [];
        _scanning = false;
      });
    }
  }

  Future<void> _connectIp() async {
    final address = _ipController.text.trim();
    if (address.isEmpty) {
      setState(() => _ipError = kIpAddressRequired);
      return;
    }
    setState(() {
      _connecting = true;
      _ipError = null;
    });
    final error = await widget.core.devices.connectIp(address);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _connecting = false;
        _ipError = error;
      });
      return;
    }
    setState(() => _connecting = false);
    Navigator.of(context).pop(DeviceManager.normaliseWifiAddress(address));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Row(
                children: [
                  const Icon(Icons.tablet_android, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Android DEX — ADB Manager',
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          'Tap a device to connect instantly',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (widget.reason != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.reason!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Flexible(child: _deviceList(theme)),
            const Divider(height: 1),
            _ipSection(theme),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _scanning ? null : _scan,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Refresh devices'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ipSection(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Connect via IP Address', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ipController,
                enabled: !_connecting,
                onSubmitted: (_) => _connectIp(),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '192.168.1.100',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _connecting ? null : _connectIp,
              child: _connecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Connect'),
            ),
          ],
        ),
        if (_ipError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _ipError!,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
      ],
    ),
  );

  Widget _deviceList(ThemeData theme) {
    if (_scanning) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            const Icon(Icons.usb_off, size: 32),
            const SizedBox(height: 12),
            Text(
              'No ADB devices found. Connect a device over USB, or use Wi-Fi '
              'ADB below.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [for (final device in _devices) _DeviceRow(device: device)],
    );
  }
}

/// One row in the device list. Hover-aware, tap = immediate connect.
class _DeviceRow extends StatefulWidget {
  const _DeviceRow({required this.device});

  final AdbDevice device;

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final usable = device.isConnected;
    return MouseRegion(
      cursor: usable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ListTile(
        enabled: usable,
        onTap: usable ? () => Navigator.of(context).pop(device.id) : null,
        leading: Icon(_iconFor(device)),
        title: Text(device.isWifi ? device.id : 'USB Device'),
        subtitle: Text(usable ? device.detail : _hintFor(device)),
        trailing: _hovered && usable ? const Icon(Icons.chevron_right) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: _hovered && usable
                ? Colors.lightBlueAccent
                : Colors.transparent,
          ),
        ),
      ),
    );
  }

  /// Explains *why* an unusable device cannot be selected.
  ///
  /// `adb devices` reports `unauthorized` and `offline` as plainly as it
  /// reports `device`, but the fix for each is entirely on the handset, so
  /// echoing the raw state back left the user with nothing to act on.
  static String _hintFor(AdbDevice device) {
    if (device.isUnauthorized) {
      return 'Unlock the phone and accept the "Allow USB debugging" prompt, '
          'then refresh.';
    }
    if (device.isOffline) {
      return 'Offline. Reconnect the cable, or pair it again with '
          '"adb connect ${device.id}".';
    }
    return '${device.id} is ${device.state} — it cannot be used yet.';
  }

  static IconData _iconFor(AdbDevice device) {
    if (device.isUnauthorized) return Icons.lock_outline;
    if (device.isOffline) return Icons.cloud_off_outlined;
    return device.isWifi ? Icons.wifi : Icons.usb;
  }
}
