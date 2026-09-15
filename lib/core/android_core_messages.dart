import 'package:json_annotation/json_annotation.dart';

part 'android_core_messages.g.dart';

class AndroidCoreMessage {
  final AndroidCoreMessageType? type;
  final String? deviceId;
  final List<AndroidCoreState>? states;
  final BatterySmall? batterySmall;
  final BatteryUpdate? batteryUpdate;
  final VolumeUpdate? volumeUpdate;
  final ApkPermissions? apkPermissions;

  AndroidCoreMessage({
    this.type,
    this.deviceId,
    this.states,
    this.batterySmall,
    this.batteryUpdate,
    this.volumeUpdate,
    this.apkPermissions,
  });

  factory AndroidCoreMessage.fromJson(
    Map<String, dynamic> json,
  ) => AndroidCoreMessage(
    type: _messageType(json['type']),
    deviceId: json['device_id'] as String?,
    states: _statesFromJson(json['states']),
    batterySmall: _payloadFor(json, 'battery_small') == null
        ? null
        : BatterySmall.fromJson(_payloadFor(json, 'battery_small')!),
    batteryUpdate: _payloadFor(json, 'battery_update') == null
        ? null
        : BatteryUpdate.fromJson(_payloadFor(json, 'battery_update')!),
    volumeUpdate: json['volume_update'] == null
        ? (json['type'] == 'volume_update' ? VolumeUpdate.fromJson(json) : null)
        : VolumeUpdate.fromJson(json['volume_update'] as Map<String, dynamic>),
    apkPermissions: _payloadFor(json, 'apk.permissions') == null
        ? null
        : ApkPermissions.fromJson(_payloadFor(json, 'apk.permissions')!),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      if (type != null) 'type': _$AndroidCoreMessageTypeEnumMap[type],
      if (deviceId != null) 'device_id': deviceId,
      if (states != null && states!.isNotEmpty)
        'states': states!.length == 1
            ? states!.single.toJson()
            : states!.map((e) => e.toJson()).toList(),
    };
    if (batterySmall != null) json.addAll(batterySmall!.toJson());
    if (batteryUpdate != null) json.addAll(batteryUpdate!.toJson());
    if (volumeUpdate != null) json.addAll(volumeUpdate!.toJson());
    if (apkPermissions != null) json.addAll(apkPermissions!.toJson());
    return json;
  }
}

AndroidCoreMessageType? _messageType(Object? source) {
  if (source == null) return null;
  return $enumDecodeNullable(_$AndroidCoreMessageTypeEnumMap, source) ??
      AndroidCoreMessageType.unknown;
}

List<AndroidCoreState>? _statesFromJson(Object? source) {
  if (source is Map<String, dynamic>) {
    return <AndroidCoreState>[AndroidCoreState.fromJson(source)];
  }
  if (source is List) {
    return source
        .whereType<Map>()
        .map(
          (value) => AndroidCoreState.fromJson(value.cast<String, dynamic>()),
        )
        .toList();
  }
  return null;
}

Map<String, dynamic>? _payloadFor(
  Map<String, dynamic> json,
  String messageType,
) {
  final nestedKey = switch (messageType) {
    'apk.permissions' => 'apk_permissions',
    _ => messageType,
  };
  final nested = json[nestedKey];
  if (nested is Map<String, dynamic>) return nested;
  if (json['type'] == messageType) return json;
  return null;
}

class AndroidCoreState {
  final bool? wifi;
  final String? wifiName;
  final bool? bluetooth;
  final String? bluetoothName;
  final bool? mobileData;
  final bool? airplaneMode;
  final bool? mute;
  final bool? rotationLock;
  final bool? location;
  final bool? torch;

  AndroidCoreState({
    this.wifi,
    this.wifiName,
    this.bluetooth,
    this.bluetoothName,
    this.mobileData,
    this.airplaneMode,
    this.mute,
    this.rotationLock,
    this.location,
    this.torch,
  });

  factory AndroidCoreState.fromJson(Map<String, dynamic> json) =>
      AndroidCoreState(
        wifi: json['wifi'] as bool?,
        wifiName: json['wifi_name'] as String?,
        bluetooth: json['bluetooth'] as bool?,
        bluetoothName: json['bluetooth_name'] as String?,
        mobileData: json['mobile_data'] as bool?,
        airplaneMode: json['airplane_mode'] as bool?,
        mute: json['mute'] as bool?,
        rotationLock: json['rotation_lock'] as bool?,
        location: json['location'] as bool?,
        torch: json['torch'] as bool?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'wifi': wifi,
    'wifi_name': wifiName,
    'bluetooth': bluetooth,
    'bluetooth_name': bluetoothName,
    'mobile_data': mobileData,
    'airplane_mode': airplaneMode,
    'mute': mute,
    'rotation_lock': rotationLock,
    'location': location,
    'torch': torch,
  };
}

class BatterySmall {
  final int? percentage;
  final bool? charging;
  final int? plugged;
  final bool? batterySaver;

  BatterySmall({
    this.percentage,
    this.charging,
    this.plugged,
    this.batterySaver,
  });

  factory BatterySmall.fromJson(Map<String, dynamic> json) => BatterySmall(
    percentage: (json['percentage'] as num?)?.toInt(),
    charging: json['charging'] as bool?,
    plugged: (json['plugged'] as num?)?.toInt(),
    batterySaver: json['battery_saver'] as bool?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'percentage': percentage,
    'charging': charging,
    'plugged': plugged,
    'battery_saver': batterySaver,
  };
}

class BatteryUpdate {
  final BatterySnapshot? battery;

  BatteryUpdate({this.battery});

  factory BatteryUpdate.fromJson(Map<String, dynamic> json) => BatteryUpdate(
    battery: json['battery'] == null
        ? null
        : BatterySnapshot.fromJson(json['battery'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'battery': battery?.toJson(),
  };
}

class BatterySnapshot {
  final int? percentage;
  final bool? charging;
  final int? plugged;
  final String? plugType;
  final double? temperature;
  final double? voltage;
  final int? currentMa;
  final String? health;
  final String? technology;
  final bool? batterySaver;

  BatterySnapshot({
    this.percentage,
    this.charging,
    this.plugged,
    this.plugType,
    this.temperature,
    this.voltage,
    this.currentMa,
    this.health,
    this.technology,
    this.batterySaver,
  });

  factory BatterySnapshot.fromJson(Map<String, dynamic> json) =>
      BatterySnapshot(
        percentage: (json['percentage'] as num?)?.toInt(),
        charging: json['charging'] as bool?,
        plugged: (json['plugged'] as num?)?.toInt(),
        plugType: json['plug_type'] as String?,
        temperature: (json['temperature'] as num?)?.toDouble(),
        voltage: (json['voltage'] as num?)?.toDouble(),
        currentMa: (json['current_ma'] as num?)?.toInt(),
        health: json['health'] as String?,
        technology: json['technology'] as String?,
        batterySaver: json['battery_saver'] as bool?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'percentage': percentage,
    'charging': charging,
    'plugged': plugged,
    'plug_type': plugType,
    'temperature': temperature,
    'voltage': voltage,
    'current_ma': currentMa,
    'health': health,
    'technology': technology,
    'battery_saver': batterySaver,
  };
}

class VolumeUpdate {
  final List<VolumeStream>? streams;

  VolumeUpdate({this.streams});

  factory VolumeUpdate.fromJson(Map<String, dynamic> json) => VolumeUpdate(
    streams: (json['streams'] as List<dynamic>?)
        ?.map((e) => VolumeStream.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'streams': streams?.map((e) => e.toJson()).toList(),
  };
}

class VolumeStream {
  final String? streamName;
  final int? current;
  final int? max;
  final bool? available;

  VolumeStream({this.streamName, this.current, this.max, this.available});

  factory VolumeStream.fromJson(Map<String, dynamic> json) => VolumeStream(
    streamName: json['stream_name'] as String?,
    current: (json['current'] as num?)?.toInt(),
    max: (json['max'] as num?)?.toInt(),
    available: json['available'] as bool?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'stream_name': streamName,
    'current': current,
    'max': max,
    'available': available,
  };
}

class ApkPermissions {
  final String? level;
  final String? message;
  final int? timestamp;
  final Map<String, bool>? data;

  ApkPermissions({this.level, this.message, this.timestamp, this.data});

  factory ApkPermissions.fromJson(Map<String, dynamic> json) => ApkPermissions(
    level: json['level'] as String?,
    message: json['message'] as String?,
    timestamp: (json['timestamp'] as num?)?.toInt(),
    data: (json['data'] as Map<String, dynamic>?)?.map(
      (k, e) => MapEntry(k, e as bool),
    ),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'level': level,
    'message': message,
    'timestamp': timestamp,
    'data': data,
  };
}

enum AndroidCoreMessageType {
  @JsonValue('jar.hello')
  jarHello,
  @JsonValue('apk.hello')
  apkHello,
  @JsonValue('state_update')
  stateUpdate,
  @JsonValue('battery_small')
  batterySmall,
  @JsonValue('battery_update')
  batteryUpdate,
  @JsonValue('volume_update')
  volumeUpdate,
  @JsonValue('apk.permissions')
  apkPermissions,
  unknown,
}
