import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/models.dart';

/// Keeps icons supplied by the installed-app response available across launches.
class IconService {
  IconService._();

  static final instance = IconService._();

  /// In-memory icon cache keyed by the same base64url key used on disk.
  /// Avoids redundant base64Decode + disk writes on every launcher rebuild.
  final Map<String, Uint8List> _cache = {};

  Future<Uint8List?> iconFor(AndroidAppInfo app, String deviceId) async {
    final key = base64Url.encode(utf8.encode('$deviceId:${app.packageName}'));

    // Fast path: icon already decoded this session.
    final cached = _cache[key];
    if (cached != null) return cached;

    final file = File(p.join(AppPaths.userDataDir.path, 'icons', '$key.png'));
    if (app.hasIcon) {
      try {
        final bytes = base64Decode(app.iconBase64);
        if (bytes.isEmpty) return null;
        _cache[key] = bytes;
        try {
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes);
        } on FileSystemException {
          // The icon is still usable for this session if storage is unavailable.
        }
        return bytes;
      } on FormatException {
        return null;
      }
    }
    try {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        _cache[key] = bytes;
        return bytes;
      }
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Clears the in-memory cache (call when device changes).
  void clearCache() => _cache.clear();
}
