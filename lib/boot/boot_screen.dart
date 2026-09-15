import 'package:flutter/material.dart';

import 'package:androiddex_host/core/android_core.dart';

class BootScreen extends StatelessWidget {
  final AndroidCore core;

  const BootScreen({super.key, required this.core});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return MaterialApp(
      title: 'Android DEX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorScheme: colorScheme),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _BrandLogo(colorScheme: colorScheme),
                    const SizedBox(height: 24),
                    _ProgressBlock(
                      label: 'Jar',
                      progress: core.jarProgress,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    _ProgressBlock(
                      label: 'App',
                      progress: core.appProgress,
                      color: colorScheme.secondary,
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ValueListenableBuilder<String>(
                        valueListenable: core.status,
                        builder: (context, status, _) {
                          return Text(
                            status,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          );
                        },
                      ),
                    ),
                    if (core.bootError.value) ...[
                      const SizedBox(height: 16),
                      Card(
                        color: colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              ValueListenableBuilder<String>(
                                valueListenable: core.bootErrorMessage,
                                builder: (context, message, _) {
                                  return Text(
                                    message,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: colorScheme.onErrorContainer,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 12),
                              FilledButton(
                                onPressed: () {
                                  core.start();
                                },
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      'Connecting to the Android device…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandLogo extends StatelessWidget {
  final ColorScheme colorScheme;

  const _BrandLogo({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.tablet_android, size: 48, color: Colors.white),
    );
  }
}

class _ProgressBlock extends StatelessWidget {
  final String label;
  final ValueNotifier<double> progress;
  final Color color;

  const _ProgressBlock({
    required this.label,
    required this.progress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      builder: (context, value, _) {
        final clamped = value.clamp(0.0, 1.0);
        final percent = (clamped * 100).clamp(0.0, 100.0);
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  '${percent.toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 12,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Container(color: colorScheme.surfaceContainerHighest),
                    FractionallySizedBox(
                      widthFactor: clamped,
                      child: Container(color: color),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
