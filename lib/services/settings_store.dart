import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/dev_log.dart';
import 'shortcut_bindings.dart';

/// Persistent host preferences.
///
/// The reference host keeps its state in a JSON file under `%LOCALAPPDATA%`;
/// the Flutter replica follows the same pattern so the wallpaper choice (and
/// any future knob) survives a restart instead of resetting to defaults.
///
/// Writes are **atomic** (temp file + rename) so a crash mid-write cannot
/// corrupt the JSON, and coalesced: rapid changes during one interaction are
/// flushed at most once per [saveDebounce] instead of rewriting the file on
/// every drag tick.
class SettingsStore extends ChangeNotifier {
  SettingsStore._();

  static final SettingsStore instance = SettingsStore._();

  static const _fileName = 'settings.json';
  static const _defaultWallpaper = 1;
  static const saveDebounce = Duration(milliseconds: 400);

  /// Accepted ranges for the numeric transport knobs.
  ///
  /// Declared once and enforced by both the setters *and* [load], so a
  /// hand-edited or partially-written `settings.json` cannot push a value
  /// outside what the scrcpy command line accepts.
  static const minBitrateMbps = 1.0;
  static const maxBitrateMbps = 32.0;
  static const minVideoFps = 15;
  static const maxVideoFps = 120;
  static const supportedCodecs = {'h264', 'h265', 'av1'};
  static const defaultCodec = 'h264';

  int _wallpaper = _defaultWallpaper;
  String _lastDevice = '';
  bool _shortcutsEnabled = true;
  Map<String, String> _shortcutChords = Map.of(ShortcutBindings.defaults);
  bool _onboardingComplete = false;
  bool _loaded = false;
  double _videoBitrateMbps = 8.0;
  int _videoFps = 60;
  String _videoCodec = 'h264';
  bool _stayAwake = false;
  bool _turnScreenOff = false;
  Map<String, num> _displaySize = const {
    'width': 1280,
    'height': 720,
    'dpi': 240,
  };

  Map<String, Map<String, num>> _windowStates = {};
  int _selectedWorkspace = 0;

  int get wallpaper => _wallpaper;
  String get lastDevice => _lastDevice;
  int get selectedWorkspace => _selectedWorkspace;
  bool get shortcutsEnabled => _shortcutsEnabled;
  Map<String, String> get shortcutChords => Map.unmodifiable(_shortcutChords);
  String shortcutFor(String action) => _shortcutChords[action]!;
  bool get onboardingComplete => _onboardingComplete;
  bool get loaded => _loaded;
  double get videoBitrateMbps => _videoBitrateMbps;
  int get videoFps => _videoFps;
  String get videoCodec => _videoCodec;
  bool get stayAwake => _stayAwake;
  bool get turnScreenOff => _turnScreenOff;

  /// The virtual display geometry used for newly launched app windows.
  Map<String, num> get displaySize => Map.unmodifiable(_displaySize);

  Map<String, Map<String, num>> get windowStates =>
      Map.unmodifiable(_windowStates);

  Map<String, num>? windowStateFor(String packageName) =>
      _windowStates[packageName];

  void setWindowState(String packageName, Map<String, num> state) {
    _windowStates[packageName] = state;
    notifyListeners();
    _scheduleSave();
  }

  void clearWindowState(String packageName) {
    if (_windowStates.remove(packageName) == null) return;
    notifyListeners();
    _scheduleSave();
  }

  void setSelectedWorkspace(int index) {
    if (index < 0 || index > 3 || index == _selectedWorkspace) return;
    _selectedWorkspace = index;
    notifyListeners();
    _scheduleSave();
  }

  File get _file => File(p.join(AppPaths.userDataDir.path, _fileName));

  /// Reads preferences from disk. Missing or corrupt files fall back to
  /// defaults rather than failing the boot.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = _file;
      if (!file.existsSync()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return;
      _wallpaper = _readInt(json['wallpaper']) ?? _defaultWallpaper;
      _lastDevice = json['last_device']?.toString() ?? '';
      _selectedWorkspace = (_readInt(json['selected_workspace']) ?? 0).clamp(0, 3);
      _shortcutsEnabled = json['shortcuts_enabled'] as bool? ?? true;
      final storedChords = json['shortcut_chords'];
      if (storedChords is Map) {
        final candidate = Map<String, String>.of(ShortcutBindings.defaults);
        for (final action in candidate.keys) {
          final chord = storedChords[action];
          if (chord is String && ShortcutBindings.keys.containsKey(chord)) {
            candidate[action] = chord;
          }
        }
        if (candidate.values.toSet().length == candidate.length) {
          _shortcutChords = candidate;
        }
      }
      _onboardingComplete = json['onboarding_complete'] == true;
      _videoBitrateMbps =
          ((json['video_bitrate_mbps'] as num?)?.toDouble() ?? 8.0).clamp(
            minBitrateMbps,
            maxBitrateMbps,
          );
      _videoFps = (_readInt(json['video_fps']) ?? 60).clamp(
        minVideoFps,
        maxVideoFps,
      );
      _videoCodec = _sanitiseCodec(json['video_codec']);
      _stayAwake = json['stay_awake'] as bool? ?? false;
      _turnScreenOff = json['turn_screen_off'] as bool? ?? false;
      final display = json['display_size'];
      if (display is Map) {
        _displaySize = {
          'width': _readInt(display['width']) ?? 1280,
          'height': _readInt(display['height']) ?? 720,
          'dpi': _readInt(display['dpi']) ?? 240,
        };
      }
      final ws = json['window_states'] as Map<String, dynamic>?;
      if (ws != null) {
        _windowStates = {
          for (final e in ws.entries)
            e.key: Map<String, num>.from(e.value as Map<String, dynamic>),
        };
      }
      notifyListeners();
    } catch (error) {
      DevLog.logError(error, scope: 'settings');
    }
  }

  Future<void> setWallpaper(int value) async {
    if (value == _wallpaper) return;
    _wallpaper = value;
    notifyListeners();
    await _save();
  }

  Future<void> setLastDevice(String deviceId) async {
    if (deviceId == _lastDevice || deviceId.isEmpty) return;
    _lastDevice = deviceId;
    await _save();
  }

  Future<void> setShortcutsEnabled(bool value) async {
    if (value == _shortcutsEnabled) return;
    _shortcutsEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> completeOnboarding() async {
    if (_onboardingComplete) return;
    _onboardingComplete = true;
    notifyListeners();
    await _save();
  }

  Future<void> setShortcut(String action, String chord) async {
    if (!_shortcutChords.containsKey(action) ||
        !ShortcutBindings.keys.containsKey(chord) ||
        _shortcutChords.entries.any((entry) => entry.key != action && entry.value == chord) ||
        _shortcutChords[action] == chord) return;
    _shortcutChords[action] = chord;
    notifyListeners();
    await _save();
  }

  Future<void> resetShortcuts() async {
    _shortcutChords = Map.of(ShortcutBindings.defaults);
    notifyListeners();
    await _save();
  }

  Future<void> setVideoBitrateMbps(double value) async {
    final clamped = value.clamp(minBitrateMbps, maxBitrateMbps);
    if (clamped == _videoBitrateMbps) return;
    _videoBitrateMbps = clamped;
    notifyListeners();
    await _save();
  }

  Future<void> setVideoFps(int value) async {
    final clamped = value.clamp(minVideoFps, maxVideoFps);
    if (clamped == _videoFps) return;
    _videoFps = clamped;
    notifyListeners();
    await _save();
  }

  Future<void> setVideoCodec(String value) async {
    final normalized = value.toLowerCase().trim();
    if (!supportedCodecs.contains(normalized) || normalized == _videoCodec) {
      return;
    }
    _videoCodec = normalized;
    notifyListeners();
    await _save();
  }

  Future<void> setStayAwake(bool value) async {
    if (value == _stayAwake) return;
    _stayAwake = value;
    notifyListeners();
    await _save();
  }

  Future<void> setTurnScreenOff(bool value) async {
    if (value == _turnScreenOff) return;
    _turnScreenOff = value;
    notifyListeners();
    await _save();
  }

  Future<void> setDisplaySize({int? width, int? height, int? dpi}) async {
    final next = Map<String, num>.of(_displaySize);
    if (width != null) next['width'] = width.clamp(640, 2560);
    if (height != null) next['height'] = height.clamp(360, 1600);
    if (dpi != null) next['dpi'] = dpi.clamp(120, 560);
    if (next['width'] == _displaySize['width'] &&
        next['height'] == _displaySize['height'] &&
        next['dpi'] == _displaySize['dpi']) {
      return;
    }
    _displaySize = next;
    notifyListeners();
    await _save();
  }

  /// Coalesces bursty changes (window drags) into one delayed write.
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDebounce, () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Timer? _saveTimer;

  /// Flushes any debounced write immediately (used by tests and shutdown).
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    return _save();
  }

  Future<void> _save() async {
    try {
      final file = _file;
      await file.parent.create(recursive: true);
      final payload = const JsonEncoder.withIndent('  ').convert({
        'wallpaper': _wallpaper,
        'last_device': _lastDevice,
        'selected_workspace': _selectedWorkspace,
        'shortcuts_enabled': _shortcutsEnabled,
        'shortcut_chords': _shortcutChords,
        'onboarding_complete': _onboardingComplete,
        'video_bitrate_mbps': _videoBitrateMbps,
        'video_fps': _videoFps,
        'video_codec': _videoCodec,
        'stay_awake': _stayAwake,
        'turn_screen_off': _turnScreenOff,
        'display_size': _displaySize,
        'window_states': _windowStates,
      });
      // Write-then-rename: a crash mid-write leaves the previous file intact.
      final temp = File(p.join(file.parent.path, '$_fileName.tmp'));
      await temp.writeAsString(payload, flush: true);
      await temp.rename(file.path);
    } catch (error) {
      DevLog.logError(error, scope: 'settings');
    }
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  /// Falls back to [defaultCodec] for anything the scrcpy codec selector
  /// would not accept, so a bad file cannot put an unknown value on the
  /// command line.
  static String _sanitiseCodec(Object? value) {
    final normalized = value?.toString().toLowerCase().trim() ?? '';
    return supportedCodecs.contains(normalized) ? normalized : defaultCodec;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveTimer = null;
    super.dispose();
  }
}
