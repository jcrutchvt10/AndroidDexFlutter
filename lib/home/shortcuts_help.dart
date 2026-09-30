import 'package:flutter/material.dart';

import '../services/settings_store.dart';
import '../services/shortcut_bindings.dart';

/// Shows fixed desktop shortcuts and lets users customize the three shell actions.
class ShortcutsHelp extends StatelessWidget {
  const ShortcutsHelp({super.key, required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Customize shell shortcuts', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        for (final action in ShortcutBindings.defaults.keys)
          ListTile(
            title: Text(ShortcutBindings.labels[action]!),
            trailing: DropdownButton<String>(
              value: settings.shortcutFor(action),
              onChanged: settings.shortcutsEnabled
                  ? (chord) {
                      if (chord != null) settings.setShortcut(action, chord);
                    }
                  : null,
              items: [
                for (final chord in ShortcutBindings.keys.keys)
                  DropdownMenuItem(
                    value: chord,
                    enabled: !settings.shortcutChords.entries.any(
                      (entry) => entry.key != action && entry.value == chord,
                    ),
                    child: Text(chord),
                  ),
              ],
            ),
          ),
        TextButton(
          onPressed: settings.shortcutsEnabled ? settings.resetShortcuts : null,
          child: const Text('Restore defaults'),
        ),
        const Divider(),
        for (final (keys, description) in const <(String, String)>[
          ('Esc', 'Close panel or exit fullscreen'),
          ('F11', 'Toggle fullscreen'),
          ('Ctrl + Tab', 'Cycle app windows'),
          ('Ctrl + 1–4', 'Switch workspaces'),
          ('Ctrl + W', 'Close focused app window'),
          ('Ctrl + M', 'Minimize focused app window'),
          ('Ctrl + Shift + Left / Right', 'Snap focused window'),
          ('Ctrl + Shift + Up / Down', 'Maximize / restore focused window'),
          ('Ctrl + Alt + Up / Down', 'Show / hide Android surfaces'),
          ('Ctrl + Alt + Left / Right', 'Open device switcher'),
        ])
          ListTile(
            dense: true,
            leading: const Icon(Icons.keyboard, size: 18),
            title: Text(keys),
            subtitle: Text(description),
          ),
      ],
    ),
  );
}
