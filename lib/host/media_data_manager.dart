import 'package:flutter/foundation.dart';

import '../core/json_read.dart';

/// A now-playing entry mirrored from the device's `MediaSessionManager`.
class MediaSession {
  const MediaSession({
    required this.packageName,
    required this.appName,
    required this.title,
    required this.artist,
    required this.album,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.artworkBase64,
  });

  final String packageName;
  final String appName;
  final String title;
  final String artist;
  final String album;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final String artworkBase64;

  bool get hasArtwork => artworkBase64.isNotEmpty;
  bool get hasProgress => durationMs > 0;

  double get progress =>
      hasProgress ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  String get subtitle {
    final parts = [artist, album].where((value) => value.isNotEmpty);
    return parts.join(' · ');
  }

  static MediaSession? fromJson(Map<String, dynamic> json) {
    // The media channel may wrap the session in a `media`/`session` object.
    final source =
        readObject(json, const ['media', 'session', 'metadata', 'data']) ??
        json;
    final package = readString(source, const [
      'package',
      'package_name',
      'packageName',
    ]);
    final title = readString(source, const ['title', 'track', 'name']);
    if (package.isEmpty && title.isEmpty) return null;
    return MediaSession(
      packageName: package,
      appName: readString(source, const ['app_name', 'appName', 'label']),
      title: title,
      artist: readString(source, const ['artist', 'subtitle', 'artist_name']),
      album: readString(source, const ['album', 'album_name']),
      playing:
          readBool(source, const ['playing', 'is_playing', 'playback_state']) ??
          true,
      positionMs:
          readInt(source, const ['position', 'position_ms', 'positionMs']) ?? 0,
      durationMs:
          readInt(source, const ['duration', 'duration_ms', 'durationMs']) ?? 0,
      artworkBase64: readString(source, const [
        'artwork',
        'artwork_base64',
        'album_art',
        'icon_base64',
      ]),
    );
  }
}

/// Host-side mirror of the device media session, fed by the media callback
/// channel on port 3701.
class MediaDataManager extends ChangeNotifier {
  MediaSession? _current;
  bool _connected = false;

  MediaSession? get current => _current;
  bool get connected => _connected;
  bool get hasSession => _current != null;

  /// Connection state as a listenable for completer-based waiters.
  ValueListenable<bool> get connectedListenable => _connectedListenable;
  final ValueNotifier<bool> _connectedListenable = ValueNotifier<bool>(false);

  void markConnected() {
    if (_connected) return;
    _connected = true;
    _connectedListenable.value = true;
    notifyListeners();
  }

  void markDisconnected() {
    if (!_connected && _current == null) return;
    _connected = false;
    _connectedListenable.value = false;
    _current = null;
    notifyListeners();
  }

  /// Applies one decoded message from the media channel.
  void apply(Map<String, dynamic> json) {
    if (isHandshake(json, 'media.hello')) {
      markConnected();
      return;
    }
    final session = MediaSession.fromJson(json);
    if (session == null) {
      // A bare state change (pause/stop) carries no metadata; keep the last
      // known session and flip only the playback flag.
      final playing = readBool(json, const [
        'playing',
        'is_playing',
        'playback_state',
      ]);
      if (playing == null || _current == null) return;
      _current = MediaSession(
        packageName: _current!.packageName,
        appName: _current!.appName,
        title: _current!.title,
        artist: _current!.artist,
        album: _current!.album,
        playing: playing,
        positionMs: _current!.positionMs,
        durationMs: _current!.durationMs,
        artworkBase64: _current!.artworkBase64,
      );
      notifyListeners();
      return;
    }
    if (session.title.isEmpty) {
      // A bare state change (pause/stop) carries no metadata.
      _current = MediaSession(
        packageName: session.packageName.isEmpty
            ? _current?.packageName ?? ''
            : session.packageName,
        appName: _current?.appName ?? '',
        title: _current?.title ?? '',
        artist: _current?.artist ?? '',
        album: _current?.album ?? '',
        playing: session.playing,
        positionMs: session.positionMs,
        durationMs: session.durationMs == 0
            ? _current?.durationMs ?? 0
            : session.durationMs,
        artworkBase64: _current?.artworkBase64 ?? '',
      );
    } else {
      _current = session;
    }
    notifyListeners();
  }

  void clear() {
    _current = null;
    notifyListeners();
  }
}
