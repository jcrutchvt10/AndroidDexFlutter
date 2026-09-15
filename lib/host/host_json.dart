import 'dart:convert';

T? hostJsonDecode<T>(String source, T Function(Map<String, dynamic>) decode) {
  try {
    final parsed = jsonDecode(source) as Map<String, dynamic>;
    return decode(parsed);
  } catch (_) {
    return null;
  }
}

String hostJsonEncode(Object value) {
  return const JsonEncoder.withIndent('  ').convert(value);
}
