import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../home/device_manager_dialog.dart';

/// First-run guide; boot continues in the background so connection errors
/// remain visible as soon as the user finishes the guide.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.core, required this.onDone});

  final AndroidCore core;
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _finishing = false;

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await widget.core.settings.completeOnboarding();
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const titles = ['Welcome to Android DEX', 'Connect your Android device', 'Make it your workspace'];
    const descriptions = [
      'Open Android apps in resizable windows on your PC. Your phone runs the apps; this desktop displays and controls them.',
      'Enable Developer options and USB debugging on your phone. Plug it in and approve the debugging prompt. You can also select a paired Wi-Fi ADB device.',
      'Open Apps to launch, use the taskbar to switch windows, and choose a workspace to organize them. Settings controls display quality and device behavior.',
    ];
    const icons = [Icons.desktop_windows_outlined, Icons.usb, Icons.view_quilt_outlined];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('GET STARTED  •  ${_step + 1} / 3', style: TextStyle(color: scheme.primary)),
                      const SizedBox(height: 28),
                      Icon(icons[_step], size: 64, color: scheme.primary),
                      const SizedBox(height: 20),
                      Text(titles[_step], style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 12),
                      Text(descriptions[_step]),
                      if (_step == 1) ...[
                        const SizedBox(height: 20),
                        OutlinedButton.icon(
                          onPressed: () => DeviceManagerDialog.show(context, core: widget.core),
                          icon: const Icon(Icons.tablet_android),
                          label: const Text('Choose device'),
                        ),
                      ],
                      if (_step == 2) ...[
                        const SizedBox(height: 20),
                        const Text('Tip: Press Ctrl+/ on the desktop to see available shortcuts.'),
                      ],
                      const SizedBox(height: 32),
                      Row(
                        children: [
                          TextButton(onPressed: _finishing ? null : _finish, child: const Text('Skip guide')),
                          const Spacer(),
                          if (_step > 0)
                            TextButton(onPressed: () => setState(() => _step--), child: const Text('Back')),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _finishing
                                ? null
                                : _step == 2
                                    ? _finish
                                    : () => setState(() => _step++),
                            child: Text(_step == 2 ? 'Open desktop' : 'Next'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
