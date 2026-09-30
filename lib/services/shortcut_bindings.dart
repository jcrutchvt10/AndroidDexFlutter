import 'package:flutter/services.dart';

/// Supported host chords avoid operating-system keys and fixed window chords.
class ShortcutBindings {
  ShortcutBindings._();

  static const defaults = <String, String>{
    'fullscreen': 'Ctrl+F',
    'game_mode': 'Ctrl+G',
    'help': 'Ctrl+/',
  };

  static const labels = <String, String>{
    'fullscreen': 'Toggle fullscreen',
    'game_mode': 'Toggle gaming mode',
    'help': 'Show shortcut help',
  };

  static const keys = <String, LogicalKeyboardKey>{
    'Ctrl+F': LogicalKeyboardKey.keyF,
    'Ctrl+G': LogicalKeyboardKey.keyG,
    'Ctrl+H': LogicalKeyboardKey.keyH,
    'Ctrl+J': LogicalKeyboardKey.keyJ,
    'Ctrl+K': LogicalKeyboardKey.keyK,
    'Ctrl+L': LogicalKeyboardKey.keyL,
    'Ctrl+P': LogicalKeyboardKey.keyP,
    'Ctrl+/': LogicalKeyboardKey.slash,
  };

  static bool matches(String chord, LogicalKeyboardKey key, {
    required bool control,
    required bool alt,
    required bool shift,
  }) => control && !alt && !shift && keys[chord] == key;
}
