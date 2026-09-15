import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/android_core.dart';
import '../services/native_desktop_windows.dart';
import 'embedded_app_window.dart';

const _assets = 'host_bundle/data/flutter_assets/assets';

class DesktopScreen extends StatefulWidget {
  const DesktopScreen({super.key, required this.core});
  final AndroidCore core;
  @override
  State<DesktopScreen> createState() => _DesktopScreenState();
}

class _DesktopScreenState extends State<DesktopScreen> {
  Timer? _timer;
  String? panel;
  String query = '';
  int wallpaper = 1;
  AndroidCore get core => widget.core;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && core.apkConnectedValue) core.refreshApps();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void toggle(String value) =>
      setState(() => panel = panel == value ? null : value);
  void launch(AndroidAppInfo app) {
    setState(() => panel = null);
    core.launchApp(app);
  }

  Widget button(IconData icon, String label, VoidCallback action) => IconButton(
    tooltip: label,
    onPressed: action,
    icon: Icon(icon, color: Colors.white, size: 21),
  );
  Widget appIcon(AndroidAppInfo app) {
    try {
      if (app.iconBase64.isNotEmpty) {
        return Image.memory(
          base64Decode(app.iconBase64),
          width: 46,
          height: 46,
          errorBuilder: (_, _, _) => const Icon(Icons.android, size: 46),
        );
      }
    } catch (_) {
      /* Device icon fallback. */
    }
    return const Icon(Icons.android, size: 46);
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: core,
    builder: (context, _) => Theme(
      data: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: 'SamsungSharpSans',
        ),
      ),
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, bounds) {
            final compact = bounds.maxWidth < 800;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && core.desktopWindows.isNotEmpty) {
                NativeDesktopWindows.setVisible(panel == null);
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
                Positioned(
                  left: 28,
                  top: 28,
                  width: compact ? 270 : 460,
                  child: Column(
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
                      const SizedBox(height: 32),
                      Glass(
                        child: ListTile(
                          leading: Icon(
                            core.allConnectedValue ? Icons.usb : Icons.link_off,
                          ),
                          title: Text(
                            core.allConnectedValue
                                ? 'Your Android, connected'
                                : 'Device disconnected',
                            style: const TextStyle(fontSize: 13),
                          ),
                          onTap: () => toggle('Device'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!compact)
                  Positioned(
                    top: 40,
                    right: 80,
                    child: Glass(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            Text(
                              DateFormat('h:mm').format(DateTime.now()),
                              style: const TextStyle(
                                fontSize: 48,
                                fontWeight: FontWeight.w300,
                              ),
                            ),
                            Text(
                              DateFormat('EEEE, MMMM d').format(DateTime.now()),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 20,
                  top: 205,
                  bottom: 80,
                  width: compact ? 280 : 420,
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
                          'Settings',
                          Image.asset(
                            '$_assets/dex_apps/settings.png',
                            width: 46,
                          ),
                          () => toggle('Settings'),
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
                        for (final app in core.apps.take(9))
                          tile(app.name, appIcon(app), () => launch(app)),
                      ],
                    ),
                  ),
                ),
                for (final window in core.desktopWindows)
                  EmbeddedAppWindow(
                    key: ValueKey(window.processId),
                    window: window,
                    bounds: Size(bounds.maxWidth, bounds.maxHeight),
                    onClose: () => core.closeAppWindow(window),
                  ),
                if (core.launchError.isNotEmpty)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 78,
                    child: Glass(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(core.launchError),
                      ),
                    ),
                  ),
                Positioned(
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
                      const Spacer(),
                      Glass(
                        child: button(Icons.apps, 'Apps', () => toggle('Apps')),
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
                ),
                if (panel != null)
                  Positioned(
                    left: compact ? 16 : bounds.maxWidth * .17,
                    right: compact ? 16 : bounds.maxWidth * .17,
                    top: 90,
                    bottom: 76,
                    child: Glass(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 12, 8, 4),
                            child: Row(
                              children: [
                                Text(
                                  panel!,
                                  style: const TextStyle(fontSize: 18),
                                ),
                                const Spacer(),
                                if (panel == 'Apps')
                                  button(
                                    Icons.refresh,
                                    'Refresh apps',
                                    core.refreshApps,
                                  ),
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
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget content() {
    if (panel == 'Apps') {
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
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
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
    if (panel == 'Recents') {
      return core.desktopWindows.isEmpty
          ? const Center(
              child: Text('Open an app from the launcher to get started.'),
            )
          : ListView(
              children: [
                for (final window in core.desktopWindows)
                  ListTile(
                    leading: appIcon(window.app),
                    title: Text(window.app.name),
                    subtitle: const Text('Android desktop window'),
                    trailing: button(
                      Icons.close,
                      'Close app window',
                      () => core.closeAppWindow(window),
                    ),
                  ),
              ],
            );
    }
    if (panel == 'Settings') {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Desktop wallpaper'),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var n = 1; n <= 5; n++)
                InkWell(
                  onTap: () => setState(() => wallpaper = n),
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
          const Text(
            'Android apps open inside this desktop. Drag their title bars to move them and their bottom edges to resize.',
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ListTile(
          leading: const Icon(Icons.usb),
          title: Text(
            core.allConnectedValue
                ? 'Connected to Android'
                : 'Device disconnected',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.battery_full),
          title: Text(
            core.batteryPercentage < 0
                ? 'Battery unknown'
                : 'Battery ${core.batteryPercentage}%',
          ),
          subtitle: Text(core.batteryCharging ? 'Charging' : 'On battery'),
        ),
        ListTile(
          leading: const Icon(Icons.wifi),
          title: Text(core.wifi ? 'Wi-Fi on' : 'Wi-Fi off'),
          subtitle: Text(core.wifiName),
        ),
        ListTile(
          leading: const Icon(Icons.bluetooth),
          title: Text(core.bluetooth ? 'Bluetooth on' : 'Bluetooth off'),
        ),
      ],
    );
  }
}

class Glass extends StatelessWidget {
  const Glass({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x99303e4b),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: .18)),
        ),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    ),
  );
}
