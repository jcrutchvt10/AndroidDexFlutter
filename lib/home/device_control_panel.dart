import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/android_core.dart';
import '../core/error_messages.dart';
import '../core/protocol.dart';

/// Lightweight control panel that lets the user toggle common device settings
/// directly from the desktop.
///
/// Toggles are backed by ADB shell passthrough commands, clipboard actions by
/// the verified JAR clipboard commands. Mirrors the reference host's "Android
/// Control" feature set as far as the bundled JAR/ADB commands support it.
/// There is deliberately **no torch tile**: no torch command exists anywhere
/// in the v1.2 JAR/APK string tables, so the old toggle was a silent no-op.
class DeviceControlPanel extends StatefulWidget {
  const DeviceControlPanel({super.key, required this.core});

  final AndroidCore core;

  @override
  State<DeviceControlPanel> createState() => _DeviceControlPanelState();
}

class _DeviceControlPanelState extends State<DeviceControlPanel> {
  AndroidCore get core => widget.core;

  @override
  Widget build(BuildContext context) {
    final core = widget.core;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Device controls', style: textTheme.titleMedium),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Toggle common settings on the connected Android device. '
              'Every action sends an ADB shell command.',
              style: textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _section(context, 'Display & orientation', [
            _switchTile(
              context,
              Icons.screen_rotation,
              'Auto-rotate',
              core.rotationLock ? 'Rotation locked' : 'Rotation unlocked',
              core.rotationLock,
              (v) => _adbShell(
                context,
                core,
                v
                    ? 'settings put system accelerometer_rotation 1'
                    : 'settings put system accelerometer_rotation 0',
              ),
            ),
            _sliderTile(
              context,
              Icons.brightness_6,
              'Brightness',
              _brightnessSliderValue,
              1.0,
              // Portable ADB path: the v1.2 `display.power.set` is screen
              // on/off, not brightness. The handle keeps its session value
              // because the shell command reports no state back.
              (v) {
                setState(() => _brightnessSliderValue = v);
                unawaited(
                  _adbShell(
                    context,
                    core,
                    'settings put system screen_brightness '
                    '${(v * 255).round().clamp(1, 255)}',
                  ),
                );
              },
            ),
          ]),
          const SizedBox(height: 16),
          _section(context, 'Connectivity', [
            _switchTile(
              context,
              Icons.wifi,
              'Wi-Fi',
              core.wifi ? 'Connected to ${core.wifiName}' : 'Off',
              core.wifi,
              (v) => _adbShell(
                context,
                core,
                v
                    ? 'cmd wifi set-wifi-enabled true'
                    : 'cmd wifi set-wifi-enabled false',
              ),
            ),
            _switchTile(
              context,
              Icons.bluetooth,
              'Bluetooth',
              core.bluetooth ? 'On' : 'Off',
              core.bluetooth,
              (v) => _adbShell(
                context,
                core,
                v
                    ? 'cmd bluetooth_manager enable'
                    : 'cmd bluetooth_manager disable',
              ),
            ),
            _switchTile(
              context,
              Icons.data_usage,
              'Mobile data',
              core.mobileData ? 'On' : 'Off',
              core.mobileData,
              (v) => _adbShell(
                context,
                core,
                v ? 'svc data enable' : 'svc data disable',
              ),
            ),
            _switchTile(
              context,
              Icons.flight,
              'Airplane mode',
              core.airplane ? 'On' : 'Off',
              core.airplane,
              (v) => _adbShell(
                context,
                core,
                v ? 'cmd airplane_mode set 1' : 'cmd airplane_mode set 0',
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _section(context, 'System', [
            _switchTile(
              context,
              Icons.volume_up,
              'Silent mode',
              core.mute ? 'Muted' : 'Sound on',
              core.mute,
              (v) => _adbShell(
                context,
                core,
                v ? 'input keyevent 164' : 'input keyevent 165',
              ),
            ),
            _actionTile(
              context,
              Icons.content_paste_off_outlined,
              'Copy clipboard from device',
              'Pulls clipboard via the companion service',
              () => _pullClipboardFromDevice(context, core),
            ),
            _actionTile(
              context,
              Icons.content_paste,
              'Push clipboard to device',
              'Sends current desktop clipboard',
              () => _syncClipboardToDevice(context, core),
            ),
          ]),
          if (core.permissionMessage.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.error.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      core.permissionMessage,
                      style: textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The slider has no device-side source of truth over this channel, so the
  /// handle stays where the user last set it during this session.
  double _brightnessSliderValue = 0.6;

  Future<void> _adbShell(
    BuildContext context,
    AndroidCore core,
    String cmd,
  ) async {
    try {
      await core.boot.sendJarCommand(
        DexProtocol.jarShell,
        arguments: {'command': cmd},
      );
      if (!context.mounted) return;
      _pushNotification(context, core, 'Command sent to device');
    } catch (error) {
      if (!context.mounted) return;
      _pushNotification(context, core, userMessageFor(error));
    }
  }

  /// Reads the device clipboard through the JAR `clipboard.text` command and
  /// copies the answer into the desktop clipboard.
  Future<void> _pullClipboardFromDevice(
    BuildContext context,
    AndroidCore core,
  ) async {
    try {
      final response = await core.boot.sendJarCommand(
        DexProtocol.jarClipboardText,
        timeout: const Duration(seconds: 5),
      );
      if (!context.mounted) return;
      final text = response['text']?.toString() ?? '';
      if (text.isEmpty) {
        _pushNotification(context, core, 'Device clipboard is empty');
        return;
      }
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      _pushNotification(context, core, 'Clipboard copied from device');
    } catch (error) {
      if (!context.mounted) return;
      _pushNotification(context, core, userMessageFor(error));
    }
  }

  /// Pushes desktop clipboard text through the JAR `clipboard.set` command,
  /// which handles arbitrary content without shell-escaping pitfalls.
  Future<void> _syncClipboardToDevice(
    BuildContext context,
    AndroidCore core,
  ) async {
    final text = await Clipboard.getData(Clipboard.kTextPlain);
    if (!context.mounted) return;
    if (text == null || text.text == null || text.text!.isEmpty) {
      _pushNotification(context, core, 'Desktop clipboard is empty');
      return;
    }
    try {
      await core.boot.sendJarCommand(
        DexProtocol.jarClipboardSet,
        arguments: {'text': text.text},
        timeout: const Duration(seconds: 5),
      );
      if (!context.mounted) return;
      _pushNotification(context, core, 'Clipboard sent to device');
    } catch (error) {
      if (!context.mounted) return;
      _pushNotification(context, core, userMessageFor(error));
    }
  }

  void _pushNotification(
    BuildContext context,
    AndroidCore core,
    String message,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        Card(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          child: Column(
            children: children
                .map(
                  (c) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: c,
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _switchTile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return ListTile(
      leading: Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      trailing: SizedBox(
        width: 48,
        child: Switch(value: value, onChanged: onChanged),
      ),
      dense: true,
    );
  }

  Widget _sliderTile(
    BuildContext context,
    IconData icon,
    String title,
    double value,
    double max,
    ValueChanged<double> onChange,
  ) {
    return ListTile(
      leading: Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        '${(value * 100).round()}%',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: SizedBox(
        width: 80,
        child: Slider(
          value: value.clamp(0.0, max),
          max: max,
          onChanged: onChange,
        ),
      ),
      dense: true,
    );
  }

  Widget _actionTile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      onTap: onTap,
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}
