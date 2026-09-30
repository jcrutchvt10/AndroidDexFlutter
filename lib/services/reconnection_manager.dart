import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/android_core.dart';
import '../core/dev_log.dart';
import '../core/error_messages.dart';

enum ReconnectionPhase {
  /// Connected — no action needed.
  idle,

  /// Phase 1 in progress: restore the ADB link and the port bridge.
  quickReconnect,

  /// Phase 2 in progress: redeploy the JAR and relaunch the companion.
  fullRestart,

  /// Every recovery attempt was exhausted.
  failed,
}

@immutable
class ReconnectionStatus {
  const ReconnectionStatus({
    required this.phase,
    required this.jarReconnecting,
    required this.apkReconnecting,
    required this.message,
    required this.attempt,
  });

  final ReconnectionPhase phase;
  final bool jarReconnecting;
  final bool apkReconnecting;
  final String message;
  final int attempt;

  bool get active => phase != ReconnectionPhase.idle;
  bool get failed => phase == ReconnectionPhase.failed;

  static const idleStatus = ReconnectionStatus(
    phase: ReconnectionPhase.idle,
    jarReconnecting: false,
    apkReconnecting: false,
    message: '',
    attempt: 0,
  );

  ReconnectionStatus copyWith({
    ReconnectionPhase? phase,
    bool? jarReconnecting,
    bool? apkReconnecting,
    String? message,
    int? attempt,
  }) => ReconnectionStatus(
    phase: phase ?? this.phase,
    jarReconnecting: jarReconnecting ?? this.jarReconnecting,
    apkReconnecting: apkReconnecting ?? this.apkReconnecting,
    message: message ?? this.message,
    attempt: attempt ?? this.attempt,
  );
}

/// Post-boot connection watchdog.
///
/// Observes the two protocol handshake notifiers and runs a two-phase
/// auto-heal, mirroring the reference reconnection contract:
///
/// 1. **Quick reconnect** — re-apply the port bridge and wait for the dropped
///    components to dial back.
/// 2. **Full restart** — up to [maxFullRestartAttempts] redeploys of the
///    service module and companion service.
///
/// Partial disconnections are handled: only the components that actually
/// dropped are waited on.
class ReconnectionManager {
  ReconnectionManager(this.core);

  static const maxFullRestartAttempts = 2;

  static const _quickTimeout = Duration(seconds: 10);
  static const _restartTimeout = Duration(seconds: 15);

  final AndroidCore core;

  final ValueNotifier<ReconnectionStatus> status =
      ValueNotifier<ReconnectionStatus>(ReconnectionStatus.idleStatus);

  bool _monitoring = false;
  bool _busy = false;

  bool get monitoring => _monitoring;
  bool get busy => _busy;

  /// Idempotent: calling this while already monitoring is a no-op.
  void startMonitoring() {
    if (_monitoring) return;
    _monitoring = true;
    core.jarConnected.addListener(_onConnectionChanged);
    core.apkConnected.addListener(_onConnectionChanged);
    DevLog.log('connection watchdog started', scope: 'reconnect');
  }

  void stopMonitoring() {
    if (!_monitoring) return;
    _monitoring = false;
    core.jarConnected.removeListener(_onConnectionChanged);
    core.apkConnected.removeListener(_onConnectionChanged);
  }

  /// Retries recovery immediately (used by the overlay's Retry button).
  Future<void> retryNow() => _recover();

  void _onConnectionChanged() {
    if (_busy) return;
    if (core.allConnectedValue) {
      if (status.value.phase != ReconnectionPhase.idle) {
        status.value = ReconnectionStatus.idleStatus;
      }
      return;
    }
    // Only react to a drop once boot has actually unlocked the desktop.
    if (!core.bootFinished) return;
    unawaited(_recover());
  }

  Future<void> _recover() async {
    if (_busy) return;
    _busy = true;
    try {
      final jarDown = !core.jarConnectedValue;
      final apkDown = !core.apkConnectedValue;
      if (!jarDown && !apkDown) {
        status.value = ReconnectionStatus.idleStatus;
        return;
      }

      status.value = ReconnectionStatus(
        phase: ReconnectionPhase.quickReconnect,
        jarReconnecting: jarDown,
        apkReconnecting: apkDown,
        message: 'Attempting to reconnect to device…',
        attempt: 0,
      );
      if (await _quickReconnect(jarDown, apkDown)) {
        _markRecovered();
        return;
      }

      for (var attempt = 1; attempt <= maxFullRestartAttempts; attempt++) {
        status.value = status.value.copyWith(
          phase: ReconnectionPhase.fullRestart,
          message:
              'Performing full restart '
              '(attempt $attempt of $maxFullRestartAttempts)…',
          attempt: attempt,
        );
        if (await _fullRestart(jarDown, apkDown)) {
          _markRecovered();
          return;
        }
      }

      status.value = status.value.copyWith(
        phase: ReconnectionPhase.failed,
        message: kDeviceDisconnected,
      );
      DevLog.log('recovery exhausted', scope: 'reconnect');
    } catch (error) {
      DevLog.logError(error, scope: 'reconnect');
      status.value = status.value.copyWith(
        phase: ReconnectionPhase.failed,
        message: kReconnectFailedUnexpectedly,
      );
    } finally {
      _busy = false;
    }
  }

  /// Phase 1.
  Future<bool> _quickReconnect(bool jarDown, bool apkDown) async {
    try {
      core.markJarDisconnected();
      core.markApkDisconnected();
      await core.boot.reapplyPortBridge();
    } catch (error) {
      DevLog.logError(error, scope: 'reconnect');
      return false;
    }
    var recovered = true;
    if (jarDown) {
      recovered &= await core.boot.waitForJar(timeout: _quickTimeout);
    }
    if (apkDown) {
      recovered &= await core.boot.waitForApk(timeout: _quickTimeout);
    }
    return recovered;
  }

  /// Phase 2.
  Future<bool> _fullRestart(bool jarDown, bool apkDown) async {
    try {
      core.markJarDisconnected();
      core.markApkDisconnected();
      await core.boot.redeployService();
    } catch (error) {
      DevLog.logError(error, scope: 'reconnect');
      return false;
    }
    var recovered = true;
    if (jarDown) {
      recovered &= await core.boot.waitForJar(timeout: _restartTimeout);
    }
    if (apkDown) {
      recovered &= await core.boot.waitForApk(timeout: _restartTimeout);
    }
    return recovered;
  }

  void _markRecovered() {
    status.value = ReconnectionStatus.idleStatus;
    DevLog.log('connection recovered', scope: 'reconnect');
  }

  void dispose() {
    stopMonitoring();
    status.dispose();
  }
}
