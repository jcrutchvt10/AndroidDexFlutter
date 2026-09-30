import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../services/reconnection_manager.dart';

/// Full-screen recovery overlay.
///
/// Blocks interaction with the desktop while the watchdog auto-heals, and shows
/// a per-component status pill for the Logic Engine and the companion app.
class ReconnectingOverlay extends StatelessWidget {
  const ReconnectingOverlay({super.key, required this.core});

  final AndroidCore core;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReconnectionStatus>(
      valueListenable: core.reconnection.status,
      builder: (context, status, _) {
        if (!status.active) return const SizedBox.shrink();
        return Positioned.fill(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.72),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  margin: const EdgeInsets.all(24),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          status.failed
                              ? Icons.error_outline
                              : Icons.sync_problem,
                          size: 40,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _phaseTitle(status.phase),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _ComponentPill(
                              label: 'Background service',
                              reconnecting: status.jarReconnecting,
                              failed: status.failed,
                            ),
                            const SizedBox(width: 12),
                            _ComponentPill(
                              label: 'Companion app',
                              reconnecting: status.apkReconnecting,
                              failed: status.failed,
                            ),
                          ],
                        ),
                        if (status.phase == ReconnectionPhase.fullRestart) ...[
                          const SizedBox(height: 16),
                          Text(
                            'Attempt ${status.attempt} of '
                            '${ReconnectionManager.maxFullRestartAttempts}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          status.message,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (!status.failed) ...[
                          const SizedBox(height: 20),
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        ] else ...[
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: () => core.reconnection.retryNow(),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Try again'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _phaseTitle(ReconnectionPhase phase) => switch (phase) {
    ReconnectionPhase.idle => '',
    ReconnectionPhase.quickReconnect => 'Reconnecting to your device',
    ReconnectionPhase.fullRestart => 'Restarting Android services',
    ReconnectionPhase.failed => 'Connection lost',
  };
}

class _ComponentPill extends StatelessWidget {
  const _ComponentPill({
    required this.label,
    required this.reconnecting,
    required this.failed,
  });

  final String label;
  final bool reconnecting;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = failed
        ? (Icons.circle, Colors.redAccent, 'Failed')
        : reconnecting
        ? (Icons.circle, Colors.amber, 'Reconnecting…')
        : (Icons.circle, Colors.greenAccent, 'Connected');
    return Column(
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(text, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }
}
