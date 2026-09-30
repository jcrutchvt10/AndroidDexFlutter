import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'error_messages.dart';

/// Developer-tier logging. Never rendered in the UI.
///
/// Mirrors the reference contract where `dev.log()` output and the
/// user-facing event streams are completely separate channels. Lines go to
/// `debugPrint` and, best effort, to a bounded file beside the settings so a
/// packaged build remains diagnosable.
class DevLog {
  DevLog._();

  static File? _file;
  static bool _initialised = false;

  static void initialize(String directory) {
    if (_initialised) return;
    _initialised = true;
    try {
      _file = File(p.join(directory, 'dev.log'));
      if (_file!.existsSync() && _file!.lengthSync() > 2 * 1024 * 1024) {
        _file!.writeAsStringSync('');
      }
    } catch (_) {
      _file = null;
    }
  }

  static void log(String message, {String scope = 'host'}) {
    final line = '${DateTime.now().toIso8601String()} [$scope] $message';
    if (kDebugMode) debugPrint(line);
    final file = _file;
    if (file == null) return;
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // Diagnostics must never break the desktop.
    }
  }

  /// Logs the technical detail of a user-facing failure.
  static void logError(Object error, {String scope = 'host'}) {
    if (error is AndroidDexError && error.devDetail != null) {
      log('${error.userMessage} :: ${error.devDetail}', scope: scope);
      return;
    }
    log(error.toString(), scope: scope);
  }
}
