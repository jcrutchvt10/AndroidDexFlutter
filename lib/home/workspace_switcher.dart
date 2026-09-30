import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../services/window_manager.dart';
import '../services/window_thumbnail_service.dart';

/// Host-side workspaces; selection and window assignment belong to the desktop.
class WorkspaceSwitcher extends StatelessWidget {
  const WorkspaceSwitcher({
    super.key,
    required this.core,
    required this.names,
    required this.selected,
    required this.workspaceFor,
    required this.onSelected,
    required this.onPreviewChanged,
  });

  final AndroidCore core;
  final List<String> names;
  final int selected;
  final int Function(String packageName) workspaceFor;
  final ValueChanged<int> onSelected;
  final ValueChanged<bool> onPreviewChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
    tooltip: 'Switch workspace',
    onSelected: onSelected,
    itemBuilder: (menuContext) => [
      for (var i = 0; i < names.length; i++)
        PopupMenuItem(
          value: i,
          child: Row(
            children: [
              Icon(i == selected ? Icons.desktop_windows : Icons.desktop_mac, size: 18),
              const SizedBox(width: 8),
              Text(names[i]),
              const Spacer(),
              IconButton(
                tooltip: 'Preview ${names[i]}',
                icon: const Icon(Icons.preview_outlined, size: 18),
                onPressed: () {
                  Navigator.pop(menuContext);
                  _showPreview(context, i);
                },
              ),
            ],
          ),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.desktop_windows, size: 18),
          const SizedBox(width: 8),
          Text(names[selected]),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    ),
  );

  Future<void> _showPreview(BuildContext context, int index) async {
    final windows = core.windows.ordered
        .where((w) => workspaceFor(w.packageName) == index)
        .toList();
    await WindowThumbnailService.instance.refresh([
      for (final window in windows) window.window.processId,
    ]);
    if (!context.mounted) return;
    onPreviewChanged(true);
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(names[index]),
          content: SizedBox(
            width: 420,
            height: 300,
            child: windows.isEmpty
                ? const Center(child: Text('No windows in this workspace.'))
                : ListenableBuilder(
                    listenable: WindowThumbnailService.instance,
                    builder: (context, _) => GridView.builder(
                      itemCount: windows.length,
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 200,
                        mainAxisExtent: 150,
                      ),
                      itemBuilder: (context, i) => _preview(windows[i]),
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                onSelected(index);
              },
              child: const Text('Switch'),
            ),
          ],
        ),
      );
    } finally {
      onPreviewChanged(false);
    }
  }

  Widget _preview(ManagedWindow managed) {
    final frame = WindowThumbnailService.instance.frameFor(managed.window.processId);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: frame == null
                ? const Center(child: Icon(Icons.android, size: 40))
                : Image.memory(frame, fit: BoxFit.cover, width: double.infinity),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(managed.window.app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
