import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../host/media_data_manager.dart';

/// Media Center: the device's active media session.
///
/// Fed by the 3701 callback channel, which carries the artwork, title, artist
/// and playback position reported by `MediaSessionManager`.
class MediaPanel extends StatelessWidget {
  const MediaPanel({super.key, required this.core, this.onOpened});

  final AndroidCore core;

  /// Invoked after a launch so the host can close the panel.
  ///
  /// The panel is a plain widget inside the desktop Stack, not a route, so it
  /// must not try to `Navigator.pop()` itself.
  final VoidCallback? onOpened;

  void _open(BuildContext context, AndroidAppInfo app) {
    core.launchApp(app);
    onOpened?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: core.media,
      builder: (context, _) {
        final session = core.media.current;
        if (session == null) {
          return _EmptyState(connected: core.media.connected);
        }
        // Tapping the session header opens the source app on the desktop.
        // Playback control itself still has no command in the shipped JAR, so
        // only the launch is wired up rather than faking transport buttons.
        final source = _sourceApp(core, session);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MouseRegion(
                  cursor: source != null
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    onTap: source == null ? null : () => _open(context, source),
                    child: _Artwork(
                      session: session,
                      highlighted: source != null,
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.title.isEmpty ? 'Unknown track' : session.title,
                        style: Theme.of(context).textTheme.titleLarge,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      if (session.subtitle.isNotEmpty)
                        Text(
                          session.subtitle,
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(
                            session.playing
                                ? Icons.play_circle_outline
                                : Icons.pause_circle_outline,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            session.playing ? 'Playing' : 'Paused',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                      if (session.appName.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          session.appName,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (source != null) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => _open(context, source),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: Text('Open ${source.name}'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (session.hasProgress) ...[
              const SizedBox(height: 24),
              LinearProgressIndicator(value: session.progress),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatDuration(session.positionMs),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    formatDuration(session.durationMs),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            Text(
              source != null
                  ? 'Transport controls are handled on the device — the '
                        'shipped service exposes no play/pause command. '
                        'Use the handset, or open the app and control it here.'
                  : 'Playback controls are handled on the device. Use the '
                        'transport controls on the handset.',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}

/// Resolves the media session's package back to a known app entry.
///
/// Returns `null` when the package is unknown to the launcher (an app that
/// was uninstalled while playing, or a session reported before the catalog
/// loaded), so the caller can hide the launch affordance instead of showing
/// a button that would fail.
AndroidAppInfo? _sourceApp(AndroidCore core, MediaSession session) {
  if (session.packageName.isEmpty) return null;
  for (final app in core.apps) {
    if (app.packageName == session.packageName) return app;
  }
  return null;
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.session, this.highlighted = false});

  final MediaSession session;

  /// Draws an accent ring when the artwork is also a launch target.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    Widget fallback() => Container(
      width: 128,
      height: 128,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: highlighted
            ? Border.all(color: Colors.lightBlueAccent, width: 2)
            : null,
      ),
      child: const Icon(Icons.music_note, size: 40),
    );

    if (!session.hasArtwork) return fallback();
    try {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: highlighted
                ? Border.all(color: Colors.lightBlueAccent, width: 2)
                : null,
          ),
          child: Image.memory(
            base64Decode(session.artworkBase64),
            width: 128,
            height: 128,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback(),
          ),
        ),
      );
    } catch (_) {
      return fallback();
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(connected ? Icons.music_off : Icons.link_off, size: 40),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            connected
                ? 'Nothing is playing on the device.'
                : 'Waiting for the device media session…',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    ),
  );
}

/// `3:07` / `1:02:11`
String formatDuration(int milliseconds) {
  if (milliseconds <= 0) return '0:00';
  final total = Duration(milliseconds: milliseconds);
  final hours = total.inHours;
  final minutes = total.inMinutes.remainder(60);
  final seconds = total.inSeconds.remainder(60);
  final paddedSeconds = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$paddedSeconds';
  }
  return '$minutes:$paddedSeconds';
}
