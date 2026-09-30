import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:androiddex_host/core/app_paths.dart';
import 'package:androiddex_host/services/settings_store.dart';
import 'package:androiddex_host/services/shortcut_bindings.dart';

void main() {
  test('workspace selection, assignments and shortcut reset persist', () async {
    final directory = await Directory.systemTemp.createTemp('dex-preferences-');
    AppPaths.debugInitUserDataDirForTests(directory.path);
    addTearDown(() async {
      AppPaths.debugInitUserDataDirForTests(null);
      await directory.delete(recursive: true);
    });
    final file = File('${directory.path}${Platform.pathSeparator}settings.json');
    await file.writeAsString('{"selected_workspace": 99}');

    final settings = SettingsStore.instance;
    await settings.load();
    expect(settings.selectedWorkspace, 3);
    settings.setSelectedWorkspace(2);
    settings.setWindowState('com.example.app', {
      'x': 10,
      'y': 20,
      'width': 400,
      'height': 300,
      'snap': 0,
      'workspace': 2,
    });
    await settings.setShortcut('fullscreen', 'Ctrl+H');
    await settings.setShortcut('help', 'Ctrl+J');
    expect(settings.shortcutFor('fullscreen'), 'Ctrl+H');
    expect(settings.shortcutFor('help'), 'Ctrl+J');

    await settings.resetShortcuts();
    expect(settings.shortcutChords, ShortcutBindings.defaults);
    settings.setSelectedWorkspace(7);
    expect(settings.selectedWorkspace, 2);
    await settings.flush();

    final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(saved['selected_workspace'], 2);
    expect((saved['window_states'] as Map)['com.example.app']['workspace'], 2);
    expect(saved['shortcut_chords'], ShortcutBindings.defaults);
  });
}
