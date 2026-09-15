// GENERATED CODE - DO NOT MODIFY BY HAND
//
// This file is maintained as a hand-written part of
// `android_core_messages.dart`. It intentionally does not rely on
// `json_serializable` generation because the build_runner task is failing
// in this environment. The types below mirror the signatures the rest of
// the app expects from the generated code.
//
// If you later fix the `json_serializable` pipeline, regenerate and replace
// this file.

part of 'android_core_messages.dart';

const _$AndroidCoreMessageTypeEnumMap = {
  AndroidCoreMessageType.jarHello: 'jar.hello',
  AndroidCoreMessageType.apkHello: 'apk.hello',
  AndroidCoreMessageType.stateUpdate: 'state_update',
  AndroidCoreMessageType.batterySmall: 'battery_small',
  AndroidCoreMessageType.batteryUpdate: 'battery_update',
  AndroidCoreMessageType.volumeUpdate: 'volume_update',
  AndroidCoreMessageType.apkPermissions: 'apk.permissions',
  AndroidCoreMessageType.unknown: 'unknown',
};

T? $enumDecodeNullable<T extends Enum>(
  Map<T, String> enumValuesByString,
  Object? source,
) {
  if (source == null) return null;
  for (final entry in enumValuesByString.entries) {
    if (entry.value == source) return entry.key;
  }
  return null;
}
