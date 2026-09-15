import 'dart:convert';

import 'desktop_screen.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:androiddex_host/core/android_core.dart';

class HomeScreen extends StatelessWidget {
  final AndroidCore core;

  const HomeScreen({super.key, required this.core});

  @override
  Widget build(BuildContext context) {
    return DesktopScreen(core: core);
  }

  Widget buildLegacy(BuildContext context) {
    final appTheme = Theme.of(context);
    final colorScheme = appTheme.colorScheme;
    return ChangeNotifierProvider.value(
      value: core,
      child: MaterialApp(
        title: 'Android DEX',
        debugShowCheckedModeBanner: false,
        theme: appTheme,
        darkTheme: appTheme,
        themeMode: ThemeMode.system,
        home: _HomeScaffold(colorScheme: colorScheme),
      ),
    );
  }
}

class _HomeScaffold extends StatelessWidget {
  final ColorScheme colorScheme;

  const _HomeScaffold({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            color: colorScheme.surface,
            child: _DesktopShell(colorScheme: colorScheme),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _TaskBar(colorScheme: colorScheme),
          ),
        ],
      ),
      endDrawer: const _AppDrawer(),
      floatingActionButton: Builder(
        builder: (context) => FloatingActionButton(
          onPressed: () => Scaffold.of(context).openEndDrawer(),
          child: const Icon(Icons.tablet_android),
        ),
      ),
    );
  }
}

class _DesktopShell extends StatelessWidget {
  final ColorScheme colorScheme;

  const _DesktopShell({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _WelcomeCard(colorScheme: colorScheme),
          const SizedBox(height: 24),
          _QuickActions(colorScheme: colorScheme),
          const SizedBox(height: 24),
          _BackendStatus(colorScheme: colorScheme),
        ],
      ),
    );
  }
}

class _WelcomeCard extends StatelessWidget {
  final ColorScheme colorScheme;

  const _WelcomeCard({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Icon(Icons.tablet_android, size: 48),
            const SizedBox(height: 8),
            Text(
              'Android DEX',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Your Android device, on Windows',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  final ColorScheme colorScheme;

  const _QuickActions({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        ActionChip(
          avatar: const Icon(Icons.phone_android, size: 18),
          label: const Text('Device'),
          onPressed: () {},
        ),
        ActionChip(
          avatar: const Icon(Icons.apps, size: 18),
          label: const Text('Apps'),
          onPressed: () => _showAppsDialog(context),
        ),
        ActionChip(
          avatar: const Icon(Icons.notifications, size: 18),
          label: const Text('Notifications'),
          onPressed: () {},
        ),
        ActionChip(
          label: const Text('Media'),
          avatar: const Icon(Icons.volume_up, size: 18),
          onPressed: () {},
        ),
        ActionChip(
          label: const Text('Gaming'),
          avatar: const Icon(Icons.gamepad, size: 18),
          onPressed: () {},
        ),
        ActionChip(
          label: const Text('Settings'),
          avatar: const Icon(Icons.settings, size: 18),
          onPressed: () {},
        ),
      ],
    );
  }
}

void _showAppsDialog(BuildContext context) {
  final core = context.read<AndroidCore>();
  if (core.apps.isEmpty && !core.appsLoading) {
    core.refreshApps();
  }
  showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        child: Consumer<AndroidCore>(
          builder: (context, core, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
                child: Row(
                  children: [
                    Text(
                      core.apps.isEmpty
                          ? 'Android apps'
                          : 'Android apps (${core.apps.length})',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: core.appsLoading ? null : core.refreshApps,
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (core.appsLoading) const LinearProgressIndicator(),
              if (core.appsError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    core.appsError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: core.apps.isEmpty
                    ? Center(
                        child: Text(
                          core.appsLoading
                              ? 'Loading apps from your device…'
                              : 'No launchable apps found.',
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 150,
                              mainAxisExtent: 142,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                        itemCount: core.apps.length,
                        itemBuilder: (context, index) {
                          final app = core.apps[index];
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: Tooltip(
                              message: app.packageName,
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _appIcon(app),
                                    const SizedBox(height: 8),
                                    Text(
                                      app.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _appIcon(AndroidAppInfo app) {
  if (app.iconBase64.isEmpty) {
    return const Icon(Icons.android, size: 56);
  }
  try {
    return Image.memory(
      base64Decode(app.iconBase64),
      width: 56,
      height: 56,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const Icon(Icons.android, size: 56),
    );
  } catch (_) {
    return const Icon(Icons.android, size: 56);
  }
}

class _BackendStatus extends StatelessWidget {
  final ColorScheme colorScheme;

  const _BackendStatus({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Consumer<AndroidCore>(
      builder: (context, core, _) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  'Host backend',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                _StatusRow(
                  label: 'Jar',
                  ok: core.jarConnected.value,
                  color: colorScheme.primary,
                ),
                _StatusRow(
                  label: 'APK',
                  ok: core.apkConnected.value,
                  color: colorScheme.secondary,
                ),
                _StatusRow(
                  label: 'All connected',
                  ok: core.allConnected.value,
                  color: colorScheme.tertiary,
                ),
                const Divider(height: 24),
                if (core.batteryPercentageNotifier.value >= 0)
                  Text(
                    'Battery: ${core.batteryPercentageNotifier.value}%',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                if (core.wifi)
                  Text(
                    'Wi-Fi: on',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (core.bluetooth)
                  Text(
                    'Bluetooth: on',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final bool ok;
  final Color color;

  const _StatusRow({
    required this.label,
    required this.ok,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Icon(
            ok ? Icons.check_circle : Icons.cancel,
            size: 20,
            color: ok ? color : Theme.of(context).colorScheme.error,
          ),
        ],
      ),
    );
  }
}

class _TaskBar extends StatelessWidget {
  final ColorScheme colorScheme;

  const _TaskBar({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.view_quilt),
            tooltip: 'Recents',
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.home),
            tooltip: 'Home',
            onPressed: () {},
          ),
          const Spacer(),
          Text('Android DEX', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer();

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.tablet_android, size: 32),
                  const SizedBox(width: 12),
                  Text(
                    'Android DEX',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: const [
                  ListTile(title: Text('Home')),
                  ListTile(title: Text('App drawer')),
                  ListTile(title: Text('Recents')),
                  ListTile(title: Text('Notifications')),
                  ListTile(title: Text('Media center')),
                  ListTile(title: Text('Device manager')),
                  ListTile(title: Text('Gaming controls')),
                  ListTile(title: Text('Settings')),
                  ListTile(title: Text('About')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
