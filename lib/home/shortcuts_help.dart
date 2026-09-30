import 'package:flutter/material.dart';

/// Shortcuts implemented by DesktopScreen's key handler.
class ShortcutsHelp extends StatelessWidget {
  const ShortcutsHelp({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      for (final (keys, description) in const <(String, String)>[
        ('Ctrl + /', 'Show or hide this list'),
        ('Esc', 'Close panel or exit fullscreen'),
        ('F11 / Ctrl + F', 'Toggle fullscreen'),
        ('Ctrl + Tab', 'Cycle app windows'),
        ('Ctrl + 1–4', 'Switch workspaces'),
        ('Ctrl + W', 'Close focused app window'),
        ('Ctrl + M', 'Minimize focused app window'),
        ('Ctrl + Shift + Left / Right', 'Snap focused window'),
        ('Ctrl + Shift + Up / Down', 'Maximize / restore focused window'),
        ('Ctrl + Alt + Up / Down', 'Show / hide Android surfaces'),
        ('Ctrl + Alt + Left / Right', 'Open device switcher'),
        ('Ctrl + G', 'Toggle gaming mode'),
      ])
        ListTile(
          dense: true,
          leading: const Icon(Icons.keyboard, size: 18),
          title: Text(keys),
          subtitle: Text(description),
        ),
    ],
  );
}
