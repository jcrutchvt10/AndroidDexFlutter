import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/android_core.dart';
import '../core/dev_log.dart';
import '../core/game_profile.dart';
import '../core/protocol.dart';
import '../home/game_mode_overlay.dart';
import '../home/device_control_panel.dart';
import '../services/native_desktop_windows.dart';
import '../services/window_manager.dart';
import '../services/window_thumbnail_service.dart';
import 'device_manager_dialog.dart';
import 'embedded_app_window.dart';
import 'notification_toast_overlay.dart';
import 'media_panel.dart';
import 'notification_panel.dart';
import 'reconnecting_overlay.dart';

const _assets = 'host_bundle/data/flutter_assets/assets';

/// The DeX-style desktop shell: wallpaper, launcher, panels, taskbar, app
/// windows and every keyboard chord.
class DesktopScreen extends StatefulWidget {
  const DesktopScreen({super.key, required this.core});

  final AndroidCore core;

  @override
  State<DesktopScreen> createState() => _DesktopScreenState();
}

class _DesktopScreenState extends State<DesktopScreen> {
  static const _wallpaperCount = 5;

  final _focusNode = FocusNode(debugLabel: 'desktop-shortcuts');

  Timer? _timer;
  String? panel;
  String query = '';
  bool fullscreen = false;
  bool surfacesVisible = true;
  bool gameMode = false;

  final GameProfileStore _gameProfileStore = GameProfileStore();
  NotificationToastBridge? _toastBridge;
  bool? _lastGlobalSurfaceVisibility;
  final Set<String> _panelCoveredPackages = <String>{};
  Timer? _persistTimer;

  String get _activePackage => core.windows.focusedPackage ?? '';

  AndroidCore get core => widget.core;
  int get wallpaper => core.settings.wallpaper;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await core.settings.load();
      await _gameProfileStore.load();
      if (!mounted) return;
      if (core.apkConnectedValue) core.refreshApps();
      _focusNode.requestFocus();
      _toastBridge = NotificationToastBridge(core);
      core.windows.addListener(_onWindowsChanged);
    });
  }

  /// Persists window geometry, coalescing bursts (a drag notifies on every
  /// tick) into one delayed write.
  void _onWindowsChanged() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      for (final w in core.windows.ordered) {
        core.settings.setWindowState(w.packageName, {
          'x': w.origin.dx,
          'y': w.origin.dy,
          'width': w.extent.width,
          'height': w.extent.height,
          'snap': w.snap.index,
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _persistTimer?.cancel();
    _focusNode.dispose();
    core.windows.removeListener(_onWindowsChanged);
    _toastBridge?.dispose();
    super.dispose();
  }

  Size _desktopSize() {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) return box.size;
    return const Size(1280, 720);
  }

  void _toggleFullscreen(bool value) {
    setState(() => fullscreen = value);
    NativeDesktopWindows.setFullscreen(value);
  }

  void _setSurfacesVisible(bool visible) {
    setState(() => surfacesVisible = visible);
  }

  void _syncNativeSurfaceVisibility(bool visible) {
    if (_lastGlobalSurfaceVisibility == visible) return;
    _lastGlobalSurfaceVisibility = visible;
    unawaited(NativeDesktopWindows.setVisible(visible));
  }

  void toggle(String value) =>
      setState(() => panel = panel == value ? null : value);

  /// Validates a game-mode gesture and forwards it to the device.
  ///
  /// Unknown tokens are dropped and logged rather than forwarded, so a
  /// hand-edited or stale `game_profiles.json` cannot push an unrecognised
  /// argument into the device command.
  void _sendGameInput(String action, {double? x, double? y}) {
    final command = gameInputCommand(action, x: x, y: y);
    if (command == null) {
      DevLog.log('ignored unknown game input "$action"', scope: 'game-mode');
      return;
    }
    unawaited(
      core.boot.sendJarCommand(
        DexProtocol.jarShell,
        arguments: {'command': command},
      ),
    );
  }

  /// The on-screen rect a panel occupies, used to decide which embedded
  /// surfaces must temporarily hide.
  Rect _panelRect(Size desktop, bool compact) => Rect.fromLTWH(
    compact ? 16 : desktop.width * .17,
    90,
    compact ? desktop.width - 32 : desktop.width * .66,
    desktop.height - 90 - WindowManager.taskbarHeight,
  );

  void launch(AndroidAppInfo app) {
    setState(() => panel = null);
    core.launchApp(app);
  }

  /// Only windows that actually intersect the open panel need to hide their
  /// native surfaces — hiding everything made the whole desktop blink
  /// whenever any panel was opened.
  void _updateCoveredSurfaces(Rect panelRect, Size desktop) {
    final covered = <String>{};
    for (final managed in core.windows.ordered) {
      if (managed.minimized) continue;
      final windowRect = managed.origin & managed.extent;
      if (windowRect.overlaps(panelRect)) covered.add(managed.packageName);
    }
    final unchanged =
        covered.length == _panelCoveredPackages.length &&
        covered.containsAll(_panelCoveredPackages);
    if (unchanged) return;
    _panelCoveredPackages
      ..clear()
      ..addAll(covered);
    for (final managed in core.windows.ordered) {
      NativeDesktopWindows.setWindowVisible(
        managed.window.processId,
        !covered.contains(managed.packageName),
      );
    }
  }

  // --- Shortcuts ---------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed;
    final alt = keys.isAltPressed;
    final shift = keys.isShiftPressed;
    final key = event.logicalKey;
    final desktop = _desktopSize();

    if (key == LogicalKeyboardKey.escape) {
      if (fullscreen) {
        _toggleFullscreen(false);
        return KeyEventResult.handled;
      }
      if (panel != null) {
        setState(() => panel = null);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.f11 ||
        (ctrl && key == LogicalKeyboardKey.keyF)) {
      _toggleFullscreen(!fullscreen);
      return KeyEventResult.handled;
    }

    // Ctrl+/ — discoverability overlay listing the active chords.
    if (ctrl && key == LogicalKeyboardKey.slash) {
      toggle('Shortcuts');
      return KeyEventResult.handled;
    }

    // Ctrl+G — toggle gaming mode overlay.
    if (ctrl && key == LogicalKeyboardKey.keyG) {
      setState(() => gameMode = !gameMode);
      return KeyEventResult.handled;
    }

    // Ctrl+Alt+Up/Down — show / hide the Android surfaces.
    if (ctrl && alt && key == LogicalKeyboardKey.arrowUp) {
      _setSurfacesVisible(true);
      return KeyEventResult.handled;
    }
    if (ctrl && alt && key == LogicalKeyboardKey.arrowDown) {
      _setSurfacesVisible(false);
      return KeyEventResult.handled;
    }

    // Ctrl+Alt+Left/Right — open the device switcher.
    if (ctrl &&
        alt &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      unawaited(
        DeviceManagerDialog.show(
          context,
          core: core,
          reason: 'Switch the ADB target used by the desktop.',
        ),
      );
      return KeyEventResult.handled;
    }

    // Ctrl+Tab — cycle the window z-order. (Bare Alt+Tab is captured by the
    // OS before the app sees it, so it is intentionally not advertised.)
    if (ctrl && key == LogicalKeyboardKey.tab) {
      core.windows.cycleFocus();
      return KeyEventResult.handled;
    }

    final focused = core.windows.focusedPackage;
    if (ctrl && !alt && focused != null) {
      switch (key) {
        case LogicalKeyboardKey.keyW:
          final managed = core.windows.forPackage(focused);
          if (managed != null) unawaited(core.closeAppWindow(managed.window));
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyM:
          core.windows.minimize(focused);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowLeft when shift:
          core.windows.snap(focused, WindowSnap.left, desktop);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight when shift:
          core.windows.snap(focused, WindowSnap.right, desktop);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp when shift:
          core.windows.toggleMaximize(focused, desktop);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown when shift:
          final managed = core.windows.forPackage(focused);
          if (managed != null && managed.snap != WindowSnap.none) {
            managed.unSnap();
            core.windows.relayout(desktop);
          }
          return KeyEventResult.handled;
        default:
          break;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      core,
      core.notifications,
      core.media,
      core.windows,
    ]),
    builder: (context, _) => Theme(
      data: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: 'SamsungSharpSans',
        ),
      ),
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKey,
        child: Scaffold(
          body: LayoutBuilder(
            builder: (context, bounds) {
              final desktop = Size(bounds.maxWidth, bounds.maxHeight);
              final compact = desktop.width < 800;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || core.desktopWindows.isEmpty) return;
                if (panel == null) {
                  if (_panelCoveredPackages.isNotEmpty) {
                    // Re-show everything hidden by a panel that just closed.
                    _panelCoveredPackages.clear();
                    for (final managed in core.windows.ordered) {
                      NativeDesktopWindows.setWindowVisible(
                        managed.window.processId,
                        true,
                      );
                    }
                  }
                  _syncNativeSurfaceVisibility(surfacesVisible);
                } else {
                  _updateCoveredSurfaces(_panelRect(desktop, compact), desktop);
                }
              });
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    '$_assets/android_dex_wallpaper_$wallpaper.jpg',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: Color(0xff35566b)),
                  ),
                  const ColoredBox(color: Color(0x22000000)),
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => setState(() => panel = null),
                    ),
                  ),
                  _desktopIcons(compact),
                  if (!fullscreen) _clock(),
                  for (final managed in core.windows.ordered)
                    EmbeddedAppWindow(
                      key: ValueKey(managed.packageName),
                      core: core,
                      managed: managed,
                      desktop: desktop,
                    ),
                  if (core.launchError.isNotEmpty)
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: WindowManager.taskbarHeight + 8,
                      child: Glass(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(child: Text(core.launchError)),
                              if (core.lastFailedApp != null)
                                TextButton.icon(
                                  onPressed: () => launch(core.lastFailedApp!),
                                  icon: const Icon(Icons.refresh, size: 16),
                                  label: const Text('Relaunch'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (!fullscreen)
                    _taskbar(desktop, compact)
                  else
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: Glass(
                        child: button(
                          Icons.fullscreen_exit,
                          'Exit fullscreen (Esc)',
                          () => _toggleFullscreen(false),
                        ),
                      ),
                    ),
                  if (panel != null) _panelFrame(desktop, compact),
                  ReconnectingOverlay(core: core),
                  if (_toastBridge != null)
                    NotificationToastOverlay(
                      key: const ValueKey('toast-overlay'),
                      core: core,
                      bridge: _toastBridge!,
                    ),
                  if (gameMode)
                    GameModeOverlay(
                      key: const ValueKey('game-mode'),
                      core: core,
                      store: _gameProfileStore,
                      activePackage: _activePackage,
                      enabled: true,
                      onInput: _sendGameInput,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget button(IconData icon, String label, VoidCallback action) => IconButton(
    tooltip: label,
    onPressed: action,
    icon: Icon(icon, color: Colors.white, size: 21),
  );

  Widget appIcon(AndroidAppInfo app, {double size = 46}) {
    try {
      if (app.hasIcon) {
        return Image.memory(
          base64Decode(app.iconBase64),
          width: size,
          height: size,
          errorBuilder: (_, _, _) => Icon(Icons.android, size: size),
        );
      }
    } catch (_) {
      // Fall through to the generic icon.
    }
    return Icon(Icons.android, size: size);
  }

  Widget tile(String name, Widget icon, VoidCallback action) => SizedBox(
    width: 92,
    child: InkWell(
      onTap: action,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            SizedBox(height: 48, child: icon),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 4)],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _desktopIcons(bool compact) => Positioned(
    left: 20,
    top: 20,
    bottom: WindowManager.taskbarHeight,
    width: compact ? 280 : 440,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Glass(
          child: ListTile(
            leading: const Icon(Icons.search),
            title: const Text(
              'Search Android apps',
              style: TextStyle(fontSize: 13),
            ),
            onTap: () => toggle('Apps'),
          ),
        ),
        const SizedBox(height: 12),
        Glass(
          child: ListTile(
            leading: Icon(core.allConnectedValue ? Icons.usb : Icons.link_off),
            title: Text(
              core.allConnectedValue
                  ? 'Your Android, connected'
                  : 'Device disconnected',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              core.devices.deviceId,
              style: const TextStyle(fontSize: 11),
            ),
            onTap: () => toggle('Device'),
          ),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 16,
              children: [
                tile(
                  'Apps',
                  const Icon(Icons.apps, size: 46, color: Colors.white),
                  () => toggle('Apps'),
                ),
                tile(
                  'Notifications',
                  _badged(
                    const Icon(
                      Icons.notifications_outlined,
                      size: 46,
                      color: Colors.white,
                    ),
                    core.notifications.unreadCount,
                  ),
                  () => toggle('Notifications'),
                ),
                tile(
                  'Media',
                  const Icon(
                    Icons.play_circle_outline,
                    size: 46,
                    color: Colors.white,
                  ),
                  () => toggle('Media'),
                ),
                tile(
                  'Recents',
                  const Icon(
                    Icons.view_quilt_outlined,
                    size: 46,
                    color: Colors.white,
                  ),
                  () => toggle('Recents'),
                ),
                tile(
                  'Settings',
                  Image.asset('$_assets/dex_apps/settings.png', width: 46),
                  () => toggle('Settings'),
                ),
                for (final app in core.apps.take(12))
                  tile(app.name, appIcon(app), () => launch(app)),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _badged(Widget child, int count) {
    if (count <= 0) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -6,
          top: -6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.redAccent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _clock() => Positioned(
    top: 40,
    right: 80,
    child: Glass(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Text(
              DateFormat('h:mm').format(DateTime.now()),
              style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w300),
            ),
            Text(
              DateFormat('EEEE, MMMM d').format(DateTime.now()),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _taskbar(Size desktop, bool compact) => Positioned(
    left: 12,
    right: 12,
    bottom: 10,
    child: Row(
      children: [
        Glass(
          child: Row(
            children: [
              button(
                Icons.view_quilt_outlined,
                'Recents',
                () => toggle('Recents'),
              ),
              button(
                Icons.home_outlined,
                'Desktop',
                () => setState(() => panel = null),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Running windows: clicking focuses, clicking the icon
        // block again minimises.
        if (core.windows.length > 0)
          Flexible(
            child: Glass(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final managed in core.windows.ordered)
                      TextButton.icon(
                        onPressed: () {
                          if (core.windows.focusedPackage ==
                              managed.packageName) {
                            core.windows.toggleMinimize(managed.packageName);
                          } else {
                            core.windows.focus(managed.packageName);
                            unawaited(
                              NativeDesktopWindows.focus(
                                managed.window.processId,
                              ),
                            );
                          }
                        },
                        icon: Icon(
                          managed.minimized
                              ? Icons.minimize
                              : Icons.crop_square,
                          size: 15,
                        ),
                        label: Text(
                          managed.window.app.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        const Spacer(),
        Glass(
          child: Row(
            children: [
              button(Icons.apps, 'Apps', () => toggle('Apps')),
              button(Icons.play_circle_outline, 'Media', () => toggle('Media')),
              IconButton(
                tooltip: 'Notifications',
                onPressed: () => toggle('Notifications'),
                icon: _badged(
                  const Icon(
                    Icons.notifications_outlined,
                    color: Colors.white,
                    size: 21,
                  ),
                  core.notifications.unreadCount,
                ),
              ),
              button(
                fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                fullscreen ? 'Exit fullscreen (Esc)' : 'Fullscreen (Ctrl+F)',
                () => _toggleFullscreen(!fullscreen),
              ),
              button(
                Icons.help_outline,
                'Keyboard shortcuts (Ctrl+/)',
                () => toggle('Shortcuts'),
              ),
            ],
          ),
        ),
        const Spacer(),
        Glass(
          child: Row(
            children: [
              button(
                core.wifi ? Icons.wifi : Icons.usb,
                'Device',
                () => toggle('Device'),
              ),
              if (!compact)
                Text(
                  core.batteryPercentage < 0
                      ? '—'
                      : '${core.batteryPercentage}%',
                  style: const TextStyle(fontSize: 11),
                ),
              button(
                Icons.settings_outlined,
                'Settings',
                () => toggle('Settings'),
              ),
              button(
                Icons.games,
                'Gaming',
                () => setState(() => gameMode = !gameMode),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  DateFormat('h:mm a').format(DateTime.now()),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _panelFrame(Size desktop, bool compact) => Positioned(
    left: compact ? 16 : desktop.width * .17,
    right: compact ? 16 : desktop.width * .17,
    top: 90,
    bottom: WindowManager.taskbarHeight,
    child: Glass(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 8, 4),
            child: Row(
              children: [
                Text(panel!, style: const TextStyle(fontSize: 18)),
                const Spacer(),
                if (panel == 'Apps')
                  button(Icons.refresh, 'Refresh apps', core.refreshApps),
                button(
                  Icons.close,
                  'Close panel',
                  () => setState(() => panel = null),
                ),
              ],
            ),
          ),
          Expanded(child: content()),
        ],
      ),
    ),
  );

  Widget content() {
    switch (panel) {
      case 'Apps':
        return _appsPanel();
      case 'Recents':
        return _recentsPanel();
      case 'Notifications':
        return NotificationPanel(core: core);
      case 'Media':
        return MediaPanel(
          core: core,
          onOpened: () => setState(() => panel = null),
        );
      case 'Settings':
        return _settingsPanel();
      case 'Shortcuts':
        return _shortcutsPanel();
      default:
        return _devicePanel();
    }
  }

  Widget _appsPanel() {
    final apps = core.apps
        .where(
          (app) => '${app.name} ${app.packageName}'.toLowerCase().contains(
            query.toLowerCase(),
          ),
        )
        .toList();
    return Column(
      children: [
        if (core.appsLoading) const LinearProgressIndicator(),
        if (core.appsError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(core.appsError),
          ),
        Expanded(
          child: apps.isEmpty
              ? Center(
                  child: Text(
                    core.appsLoading ? 'Loading your apps…' : 'No apps found',
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(20),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 120,
                    mainAxisExtent: 112,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: apps.length,
                  itemBuilder: (_, index) => tile(
                    apps[index].name,
                    appIcon(apps[index]),
                    () => launch(apps[index]),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: TextField(
            onChanged: (value) => setState(() => query = value),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search apps',
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(28)),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _recentsPanel() {
    if (core.desktopWindows.isEmpty) {
      return const Center(
        child: Text('Open an app from the launcher to get started.'),
      );
    }
    // Thumbnails are captured lazily; a hostile surface falls back to the icon.
    final processIds = [for (final w in core.desktopWindows) w.processId];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(WindowThumbnailService.instance.refresh(processIds));
    });
    return ListenableBuilder(
      listenable: WindowThumbnailService.instance,
      builder: (context, _) => GridView.builder(
        padding: const EdgeInsets.all(20),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 260,
          mainAxisExtent: 200,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
        ),
        itemCount: core.desktopWindows.length,
        itemBuilder: (_, index) {
          final window = core.desktopWindows[index];
          final frame = WindowThumbnailService.instance.frameFor(
            window.processId,
          );
          return InkWell(
            onTap: () {
              core.windows.focus(window.packageName);
              unawaited(NativeDesktopWindows.focus(window.processId));
              setState(() => panel = null);
            },
            child: Card(
              color: Colors.white.withValues(alpha: 0.06),
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      color: Colors.black45,
                      alignment: Alignment.center,
                      child: frame == null
                          ? appIcon(window.app, size: 40)
                          : Image.memory(frame, fit: BoxFit.cover),
                    ),
                  ),
                  ListTile(
                    dense: true,
                    leading: appIcon(window.app, size: 22),
                    title: Text(
                      window.app.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: 'Close app window',
                      onPressed: () => core.closeAppWindow(window),
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _devicePanel() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      ListTile(
        leading: const Icon(Icons.usb),
        title: Text(
          core.allConnectedValue
              ? 'Connected to Android'
              : 'Device disconnected',
        ),
        subtitle: Text(core.devices.deviceId),
        trailing: TextButton(
          onPressed: () => unawaited(
            DeviceManagerDialog.show(
              context,
              core: core,
              reason: 'Choose the device this desktop should target.',
            ),
          ),
          child: const Text('Switch device'),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.battery_full),
        title: Text(
          core.batteryPercentage < 0
              ? 'Battery unknown'
              : 'Battery ${core.batteryPercentage}%',
        ),
        subtitle: Text(
          core.batteryCharging
              ? 'Charging · ${core.batteryTemperature.round()}°C'
              : 'On battery · ${core.batteryCurrentMa}mA',
        ),
      ),
      ListTile(
        leading: const Icon(Icons.wifi),
        title: Text(core.wifi ? 'Wi-Fi on' : 'Wi-Fi off'),
        subtitle: Text(core.wifiName),
      ),
      ListTile(
        leading: const Icon(Icons.bluetooth),
        title: Text(core.bluetooth ? 'Bluetooth on' : 'Bluetooth off'),
        subtitle: Text(core.bluetoothName),
      ),
      if (core.permissionMessage.isNotEmpty)
        ListTile(
          leading: Icon(
            core.permissionLevel == 'success'
                ? Icons.verified_user_outlined
                : Icons.gpp_maybe_outlined,
          ),
          title: const Text('Companion permissions'),
          subtitle: Text(core.permissionMessage),
        ),
    ],
  );

  Widget _settingsPanel() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text('Desktop wallpaper'),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (var n = 1; n <= _wallpaperCount; n++)
            InkWell(
              onTap: () => core.settings.setWallpaper(n),
              child: Container(
                width: 150,
                height: 96,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: wallpaper == n
                        ? Colors.lightBlueAccent
                        : Colors.white24,
                    width: 3,
                  ),
                ),
                child: Image.asset(
                  '$_assets/android_dex_wallpaper_$n.jpg',
                  fit: BoxFit.cover,
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 24),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.tablet_android),
        title: const Text('ADB Manager'),
        subtitle: Text(core.devices.deviceId),
        trailing: FilledButton(
          onPressed: () =>
              unawaited(DeviceManagerDialog.show(context, core: core)),
          child: const Text('Open'),
        ),
      ),
      SwitchListTile(
        value: core.settings.shortcutsEnabled,
        onChanged: (value) => core.settings.setShortcutsEnabled(value),
        title: const Text('Keyboard shortcuts'),
        subtitle: const Text('Press Ctrl+/ for the full list'),
      ),
      ListTile(
        leading: const Icon(Icons.speed),
        title: const Text('Video bitrate'),
        subtitle: Text(
          '${core.settings.videoBitrateMbps.toStringAsFixed(1)} Mbps — applies to newly launched app windows',
        ),
      ),
      Slider(
        value: core.settings.videoBitrateMbps.clamp(1.0, 32.0),
        min: 1.0,
        max: 32.0,
        divisions: 31,
        label: '${core.settings.videoBitrateMbps.toStringAsFixed(0)} Mbps',
        onChanged: (v) => core.settings.setVideoBitrateMbps(v),
      ),
      ListTile(
        leading: const Icon(Icons.videocam_outlined),
        title: const Text('Video codec'),
        trailing: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'h264', label: Text('H.264')),
            ButtonSegment(value: 'h265', label: Text('H.265')),
            ButtonSegment(value: 'av1', label: Text('AV1')),
          ],
          selected: {core.settings.videoCodec},
          onSelectionChanged: (selection) =>
              core.settings.setVideoCodec(selection.first),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.bolt),
        title: const Text('Frame rate cap'),
        trailing: SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 30, label: Text('30')),
            ButtonSegment(value: 60, label: Text('60')),
            ButtonSegment(value: 90, label: Text('90')),
            ButtonSegment(value: 120, label: Text('120')),
          ],
          selected: {core.settings.videoFps.clamp(30, 120)},
          onSelectionChanged: (selection) =>
              core.settings.setVideoFps(selection.first),
        ),
      ),
      SwitchListTile(
        value: core.settings.stayAwake,
        onChanged: (value) => core.settings.setStayAwake(value),
        title: const Text('Keep device awake while mirroring'),
        subtitle: const Text('Blocks the phone sleeping during use'),
      ),
      SwitchListTile(
        value: core.settings.turnScreenOff,
        onChanged: (value) => core.settings.setTurnScreenOff(value),
        title: const Text('Turn device screen off'),
        subtitle: const Text(
          'Mirror only — the phone display turns off while in use',
        ),
      ),
      ListTile(
        leading: const Icon(Icons.aspect_ratio),
        title: const Text('Virtual display size'),
        subtitle: Text(
          '${core.settings.displaySize['width']?.toInt()} × '
          '${core.settings.displaySize['height']?.toInt()} @ '
          '${core.settings.displaySize['dpi']?.toInt()} dpi — '
          'applies to newly launched app windows',
        ),
        trailing: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: '720', label: Text('720p')),
            ButtonSegment(value: '1080', label: Text('1080p')),
          ],
          selected: {
            (core.settings.displaySize['height']?.toInt() ?? 720) > 900
                ? '1080'
                : '720',
          },
          onSelectionChanged: (selection) => core.settings.setDisplaySize(
            width: selection.first == '1080' ? 1920 : 1280,
            height: selection.first == '1080' ? 1080 : 720,
            dpi: selection.first == '1080' ? 320 : 240,
          ),
        ),
      ),
      const SizedBox(height: 12),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.games),
        title: const Text('Gaming mode'),
        subtitle: Text(
          gameMode
              ? 'Active (Ctrl+G to toggle)'
              : 'Inactive (Ctrl+G to toggle)',
        ),
        trailing: Switch(
          value: gameMode,
          onChanged: (v) => setState(() => gameMode = v),
        ),
      ),
      const Text(
        'Android apps open inside this desktop. Drag their title bars to move '
        'them, drag the bottom edge to resize, and use Ctrl+Shift with the '
        'arrow keys to snap them.',
      ),
      const Divider(),
      const Text('Device controls', style: TextStyle(fontSize: 14)),
      const SizedBox(height: 8),
      DeviceControlPanel(core: core),
    ],
  );

  Widget _shortcutsPanel() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      for (final entry in const <(String, String)>[
        ('Ctrl + F / F11', 'Toggle fullscreen'),
        ('Esc', 'Exit fullscreen or close a panel'),
        ('Ctrl + W', 'Close the focused app window'),
        ('Ctrl + M', 'Minimize the focused app window'),
        ('Ctrl + Tab', 'Cycle the window z-order'),
        ('Drag to top edge', 'Maximize a window by its title bar'),
        ('Ctrl + Shift + Left / Right', 'Snap the focused window'),
        ('Ctrl + Shift + Up / Down', 'Maximize / restore the focused window'),
        ('Ctrl + Alt + Up / Down', 'Show / hide the Android surfaces'),
        ('Ctrl + Alt + Left / Right', 'Open the device switcher'),
        ('Ctrl + /', 'Show this shortcut list'),
      ])
        ListTile(
          dense: true,
          leading: const Icon(Icons.keyboard, size: 18),
          title: Text(entry.$1),
          subtitle: Text(entry.$2),
        ),
      const Divider(),
      const ListTile(
        dense: true,
        leading: Icon(Icons.games, size: 18),
        title: Text('Gaming Mode (Ctrl + G)'),
        subtitle: Text(
          'Toggles an on-screen D-pad, joystick, action buttons, '
          'and tap-spot overlay for the focused app.',
        ),
      ),
    ],
  );
}

/// Gamepad tokens the JAR `input` sub-command understands.
///
/// The overlay builds these names from `game_profiles.json`, a user-editable
/// file on disk. Matching against a closed set means a malformed or stale
/// profile produces a dropped gesture and a log line, rather than an
/// arbitrary string being spliced into the device command.
const _gameInputTokens = <String>{
  'dpad_up',
  'dpad_down',
  'dpad_left',
  'dpad_right',
  'joystick',
  'joystick_release',
  'tapspot_toggle',
  'tapspot_turbo',
};

/// Action buttons are named per game (`A`, `B`, `X`, `Y`, …), so they are
/// matched as `button_<name>` where `<name>` is a short alphanumeric token.
final _gameButtonPattern = RegExp(r'^button_[A-Za-z0-9]{1,12}$');

/// Builds the JAR `input` command for a validated game-mode gesture.
///
/// Returns `null` when [action] is not a known token, which is the signal to
/// drop the gesture rather than forward it.
String? gameInputCommand(String action, {double? x, double? y}) {
  final known =
      _gameInputTokens.contains(action) || _gameButtonPattern.hasMatch(action);
  if (!known) return null;
  // Axis values are device floats; format them so the token stays a plain
  // pair of numbers regardless of locale or exponent formatting.
  String axis(double value) => value.clamp(-1.0, 1.0).toStringAsFixed(4);
  final suffix = x != null && y != null ? ' ${axis(x)} ${axis(y)}' : '';
  return 'input $action$suffix';
}

/// A blurred, translucent panel used for every desktop surface.
///
/// [sigma] is tunable because a `BackdropFilter` is re-rasterised whenever the
/// backdrop changes, and the desktop puts many of these on screen at once.
/// Panels that sit over the (essentially static) wallpaper can use a lighter
/// blur than a full-screen one.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.sigma = 18});

  final Widget child;

  /// Blur radius in logical pixels.
  final double sigma;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x99303e4b),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: .18)),
        ),
        child: RepaintBoundary(
          // Keeps blur re-rasterisation from cascading into siblings when one
          // glass panel animates or rebuilds.
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    ),
  );
}
