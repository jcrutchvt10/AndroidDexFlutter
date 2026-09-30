import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'dev_log.dart';

/// A gaming-mode control profile for a single Android package.
///
/// Stores the on-screen layout for D-pad position, joystick position and
/// radius, action buttons, the tap-spot setting, and which buttons send
/// which `adb shell input` taps.
///
/// **Coordinate space:** `deviceX`/`deviceY` and the overlay anchors are
/// Android virtual-display coordinates for the app's landscape window
/// (default 1280x720 — see `settings.display_size`). Portrait phone
/// coordinates will land off-target; keep profiles per orientation.
@immutable
class GameProfile {
  const GameProfile({
    required this.packageName,
    required this.name,
    this.isEnabled = true,
    // Defaults target the 1280x720 landscape virtual display: left side
    // D-pad + joystick, right side action buttons.
    this.dpadCenter = const Offset(140, 400),
    this.dpadButtonRadius = 48.0,
    this.dpadKeys = const [
      KeyBinding(key: 'Up', deviceX: 140, deviceY: 320),
      KeyBinding(key: 'Down', deviceX: 140, deviceY: 480),
      KeyBinding(key: 'Left', deviceX: 60, deviceY: 400),
      KeyBinding(key: 'Right', deviceX: 220, deviceY: 400),
    ],
    this.joystickCenter = const Offset(140, 590),
    this.joystickRadius = 60.0,
    this.actionButtons = const [
      ActionButton(label: 'A', deviceX: 1080, deviceY: 560),
      ActionButton(label: 'B', deviceX: 1160, deviceY: 480),
      ActionButton(label: 'X', deviceX: 1000, deviceY: 480),
      ActionButton(label: 'Y', deviceX: 1080, deviceY: 400),
    ],
    this.tapSpotEnabled = true,
    this.tapSpotTurbo = false,
    this.mouseLockEnabled = false,
    this.meta = const {'created_at': '', 'updated_at': ''},
  });

  final String packageName;
  final String name;
  final bool isEnabled;
  final Offset dpadCenter;
  final double dpadButtonRadius;
  final List<KeyBinding> dpadKeys;
  final Offset joystickCenter;
  final double joystickRadius;
  final List<ActionButton> actionButtons;
  final bool tapSpotEnabled;
  final bool tapSpotTurbo;
  final bool mouseLockEnabled;
  final Map<String, dynamic> meta;

  String get id => '$packageName|$name';

  GameProfile copyWith({
    String? packageName,
    String? name,
    bool? isEnabled,
    Offset? dpadCenter,
    double? dpadButtonRadius,
    List<KeyBinding>? dpadKeys,
    Offset? joystickCenter,
    double? joystickRadius,
    List<ActionButton>? actionButtons,
    bool? tapSpotEnabled,
    bool? tapSpotTurbo,
    bool? mouseLockEnabled,
    Map<String, dynamic>? meta,
  }) {
    return GameProfile(
      packageName: packageName ?? this.packageName,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      dpadCenter: dpadCenter ?? this.dpadCenter,
      dpadButtonRadius: dpadButtonRadius ?? this.dpadButtonRadius,
      dpadKeys: dpadKeys ?? this.dpadKeys,
      joystickCenter: joystickCenter ?? this.joystickCenter,
      joystickRadius: joystickRadius ?? this.joystickRadius,
      actionButtons: actionButtons ?? this.actionButtons,
      tapSpotEnabled: tapSpotEnabled ?? this.tapSpotEnabled,
      tapSpotTurbo: tapSpotTurbo ?? this.tapSpotTurbo,
      mouseLockEnabled: mouseLockEnabled ?? this.mouseLockEnabled,
      meta: meta ?? this.meta,
    );
  }

  Map<String, dynamic> toJson() => {
    'package_name': packageName,
    'name': name,
    'is_enabled': isEnabled,
    'dpad_center_x': dpadCenter.dx,
    'dpad_center_y': dpadCenter.dy,
    'dpad_button_radius': dpadButtonRadius,
    'dpad_keys': dpadKeys.map((k) => k.toJson()).toList(),
    'joystick_center_x': joystickCenter.dx,
    'joystick_center_y': joystickCenter.dy,
    'joystick_radius': joystickRadius,
    'action_buttons': actionButtons.map((b) => b.toJson()).toList(),
    'tap_spot_enabled': tapSpotEnabled,
    'tap_spot_turbo': tapSpotTurbo,
    'mouse_lock_enabled': mouseLockEnabled,
    'meta': meta,
  };

  factory GameProfile.fromJson(Map<String, dynamic> json) => GameProfile(
    packageName: json['package_name'] as String? ?? '',
    name: json['name'] as String? ?? 'Profile',
    isEnabled: json['is_enabled'] as bool? ?? true,
    dpadCenter: Offset(
      _num(json['dpad_center_x'], 140),
      _num(json['dpad_center_y'], 400),
    ),
    dpadButtonRadius: _num(json['dpad_button_radius'], 48.0),
    dpadKeys: (json['dpad_keys'] as List? ?? [])
        .map((e) => KeyBinding.fromJson(e as Map<String, dynamic>? ?? {}))
        .toList(),
    joystickCenter: Offset(
      _num(json['joystick_center_x'], 140),
      _num(json['joystick_center_y'], 590),
    ),
    joystickRadius: _num(json['joystick_radius'], 60.0),
    actionButtons: (json['action_buttons'] as List? ?? [])
        .map((e) => ActionButton.fromJson(e as Map<String, dynamic>? ?? {}))
        .toList(),
    tapSpotEnabled: json['tap_spot_enabled'] as bool? ?? true,
    tapSpotTurbo: json['tap_spot_turbo'] as bool? ?? false,
    mouseLockEnabled: json['mouse_lock_enabled'] as bool? ?? false,
    meta: json['meta'] as Map<String, dynamic>? ?? {},
  );

  static double _num(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }
}

@immutable
class KeyBinding {
  const KeyBinding({
    required this.key,
    required this.deviceX,
    required this.deviceY,
  });

  final String key;
  final double deviceX;
  final double deviceY;

  Map<String, dynamic> toJson() => {
    'key': key,
    'device_x': deviceX,
    'device_y': deviceY,
  };

  factory KeyBinding.fromJson(Map<String, dynamic> json) => KeyBinding(
    key: json['key'] as String? ?? '',
    deviceX: (json['device_x'] as num?)?.toDouble() ?? 0.0,
    deviceY: (json['device_y'] as num?)?.toDouble() ?? 0.0,
  );
}

@immutable
class ActionButton {
  const ActionButton({
    required this.label,
    required this.deviceX,
    required this.deviceY,
  });

  final String label;
  final double deviceX;
  final double deviceY;

  Map<String, dynamic> toJson() => {
    'label': label,
    'device_x': deviceX,
    'device_y': deviceY,
  };

  factory ActionButton.fromJson(Map<String, dynamic> json) => ActionButton(
    label: json['label'] as String? ?? '?',
    deviceX: (json['device_x'] as num?)?.toDouble() ?? 0.0,
    deviceY: (json['device_y'] as num?)?.toDouble() ?? 0.0,
  );
}

/// The set of all game profiles, persisted as a JSON array in
/// [AppPaths.userDataDir]/game_profiles.json.
class GameProfileStore extends ChangeNotifier {
  GameProfileStore() {
    _file = File(p.join(AppPaths.userDataDir.path, 'game_profiles.json'));
  }

  late final File _file;
  final List<GameProfile> _profiles = [];
  bool _loaded = false;

  List<GameProfile> get profiles => List.unmodifiable(_profiles);

  List<GameProfile> get enabledProfiles =>
      _profiles.where((p) => p.isEnabled).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  GameProfile? profileForPackage(String packageName) {
    final candidates = _profiles.where(
      (p) => p.packageName == packageName && p.isEnabled,
    );
    if (candidates.isEmpty) return null;
    final sorted = candidates.toList()
      ..sort((a, b) {
        final aTime = a.meta['updated_at'] as String? ?? '';
        final bTime = b.meta['updated_at'] as String? ?? '';
        return bTime.compareTo(aTime);
      });
    return sorted.first;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!_file.existsSync()) {
        _profiles.addAll(_defaultProfiles);
        await save();
        return;
      }
      final raw = _file.readAsStringSync();
      final json = raw.isEmpty
          ? null
          : jsonDecode(raw) as Map<String, dynamic>?;
      if (json == null) {
        _profiles.addAll(_defaultProfiles);
        await save();
        return;
      }
      final list = json['profiles'] as List<dynamic>? ?? [];
      _profiles.clear();
      for (final item in list) {
        final map = item as Map<String, dynamic>?;
        if (map != null) {
          _profiles.add(GameProfile.fromJson(map));
        }
      }
      if (_profiles.isEmpty) {
        _profiles.addAll(_defaultProfiles);
        await save();
      }
    } catch (error) {
      DevLog.logError(error, scope: 'game_profiles');
      _profiles.addAll(_defaultProfiles);
      await save();
    }
    notifyListeners();
  }

  Future<void> save() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert({'profiles': _profiles.map((p) => p.toJson()).toList()}),
      );
    } catch (error) {
      DevLog.logError(error, scope: 'game_profiles');
    }
  }

  void add(GameProfile profile) {
    _profiles.removeWhere((p) => p.id == profile.id);
    final updated = profile.copyWith(
      meta: {...profile.meta, 'updated_at': DateTime.now().toIso8601String()},
    );
    _profiles.add(updated);
    notifyListeners();
    save();
  }

  void remove(String id) {
    _profiles.removeWhere((p) => p.id == id);
    notifyListeners();
    save();
  }

  void setEnabled(String id, bool enabled) {
    final index = _profiles.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final current = _profiles[index];
    _profiles[index] = current.copyWith(isEnabled: enabled);
    notifyListeners();
    save();
  }

  GameProfile createDefaultForPackage(String packageName, String name) {
    return GameProfile(
      packageName: packageName,
      name: name,
      meta: {'created_at': DateTime.now().toIso8601String()},
    );
  }

  static final _defaultProfiles = <GameProfile>[];
}
