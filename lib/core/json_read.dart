/// Tolerant readers for the Android-Dex callback channels.
///
/// The device side is a closed-source companion, so payload shapes are read
/// defensively: several plausible key spellings are accepted and unknown
/// fields are ignored rather than throwing. This replaces the unused
/// `host_json.dart` helper with readers that are actually exercised.
library;

String readString(
  Map<String, dynamic> json,
  List<String> keys, {
  String fallback = '',
}) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is String && value.isNotEmpty) return value;
    if (value is num || value is bool) return value.toString();
  }
  return fallback;
}

int? readInt(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

double? readDouble(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

bool? readBool(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
    }
  }
  return null;
}

/// Returns the first nested object found under any of [keys].
Map<String, dynamic>? readObject(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is Map) return value.cast<String, dynamic>();
  }
  return null;
}

/// Returns the first list found under any of [keys], coercing entries to maps.
List<Map<String, dynamic>> readObjects(
  Map<String, dynamic> json,
  List<String> keys,
) {
  for (final key in keys) {
    final value = json[key];
    if (value is List) {
      return value
          .whereType<Map>()
          .map((entry) => entry.cast<String, dynamic>())
          .toList();
    }
  }
  return const [];
}

/// The `type` discriminator, or an empty string when absent.
String messageType(Map<String, dynamic> json) =>
    readString(json, const ['type', 'event', 'message_type']);

/// True when the payload announces itself with [type].
///
/// Android-Dex handshakes are bare (`{"type":"jar.hello"}`) but some builds
/// nest them under a `data` object, so both layouts are accepted.
bool isHandshake(Map<String, dynamic> json, String type) {
  if (messageType(json) == type) return true;
  final nested = readObject(json, const ['data', 'payload']);
  return nested != null && messageType(nested) == type;
}
