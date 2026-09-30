import 'package:flutter/material.dart';

import 'package:androiddex_host/core/android_core.dart';
import 'package:androiddex_host/home/device_manager_dialog.dart';

class BootScreen extends StatelessWidget {
  const BootScreen({super.key, required this.core});

  final AndroidCore core;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: _BrandLogo(colorScheme: colorScheme)),
                    const SizedBox(height: 24),
                    _ProgressBlock(
                      label: 'Jar',
                      progress: core.jarProgress,
                      color: colorScheme.primary,
                    ),
                    _StepLabel(notifier: core.jarLabel),
                    const SizedBox(height: 16),
                    _ProgressBlock(
                      label: 'App',
                      progress: core.appProgress,
                      color: colorScheme.secondary,
                    ),
                    _StepLabel(notifier: core.appLabel),
                    const SizedBox(height: 24),
                    ValueListenableBuilder<String>(
                      valueListenable: core.status,
                      builder: (context, status, _) => Text(
                        status,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    // The error panel is gated on a notifier that
                    // `AndroidCore.setBootError` now notifies, so a failed boot
                    // always explains itself instead of freezing at 84%.
                    ValueListenableBuilder<bool>(
                      valueListenable: core.bootError,
                      builder: (context, hasError, _) => hasError
                          ? _ErrorBlock(core: core)
                          : const SizedBox.shrink(),
                    ),
                    // Degraded boot: optional media/notification callbacks did
                    // not answer. Not fatal, but it has to be stated, because
                    // those panels otherwise just look permanently empty.
                    ValueListenableBuilder<String>(
                      valueListenable: core.bootWarning,
                      builder: (context, warning, _) => warning.isEmpty
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: _WarningBlock(message: warning),
                            ),
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

class _StepLabel extends StatelessWidget {
  const _StepLabel({required this.notifier});

  final ValueNotifier<String> notifier;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: notifier,
    builder: (context, value, _) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        value,
        style: Theme.of(context).textTheme.bodySmall,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// Inline failure panel plus its recovery actions.
class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.core});

  final AndroidCore core;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: core.bootErrorMessage,
                    builder: (context, message, _) => Text(
                      message,
                      style: TextStyle(color: colorScheme.onErrorContainer),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Only offered for failures a different ADB target could fix.
          ValueListenableBuilder<bool>(
            valueListenable: core.canPickDevice,
            builder: (context, canPick, _) => canPick
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: OutlinedButton.icon(
                      onPressed: () => DeviceManagerDialog.show(
                        context,
                        core: core,
                        reason: core.bootErrorMessage.value,
                      ),
                      icon: const Icon(Icons.tablet_android),
                      label: const Text('Open ADB Manager — Select Device'),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: colorScheme.primary, width: 2),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          FilledButton.icon(
            onPressed: () => core.retryBoot(),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<bool>(
            valueListenable: core.bootInProgress,
            builder: (context, running, _) => running
                ? const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'A boot attempt is already running…',
                      textAlign: TextAlign.center,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// Non-fatal boot notice for an optional channel that never came up.
class _WarningBlock extends StatelessWidget {
  const _WarningBlock({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: colorScheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colorScheme.onSecondaryContainer),
            ),
          ),
        ],
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
