import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/dev_log.dart';
import '../core/json_read.dart';
import '../core/protocol.dart';

/// A receive-only device callback channel framed as newline-delimited JSON.
///
/// The media (3701) and notification (3700) channels are both plain TCP
/// sockets that the companion APK dials back to; there is no `ws://` literal
/// for either port in the shipped APK, which is why this is not a WebSocket.
/// Each channel announces itself with a handshake (`media.hello`,
/// `notification.hello`) before it is treated as connected.
///
/// Control commands are *not* sent here — these services are activated and
/// driven through the APK WebSocket channel instead.
class CallbackChannel {
  CallbackChannel._({required this.name, required this.handshakeType});

  final String name;
  final String handshakeType;

  late final void Function(Map<String, dynamic> message) _onMessage;
  void Function()? _onClientConnected;
  void Function()? _onClientDisconnected;

  ServerSocket? _listener;
  final Set<Socket> _clients = <Socket>{};
  bool _connected = false;

  int get port => _listener?.port ?? 0;
  bool get connected => _connected;

  static Future<CallbackChannel> startMedia({
    required void Function(Map<String, dynamic> message) onMessage,
    void Function()? onClientConnected,
    void Function()? onClientDisconnected,
    int port = DexProtocol.mediaPort,
  }) => _start(
    name: 'media',
    handshakeType: DexProtocol.mediaHello,
    port: port,
    onMessage: onMessage,
    onClientConnected: onClientConnected,
    onClientDisconnected: onClientDisconnected,
  );

  static Future<CallbackChannel> startNotification({
    required void Function(Map<String, dynamic> message) onMessage,
    void Function()? onClientConnected,
    void Function()? onClientDisconnected,
    int port = DexProtocol.notificationPort,
  }) => _start(
    name: 'notification',
    handshakeType: DexProtocol.notificationHello,
    port: port,
    onMessage: onMessage,
    onClientConnected: onClientConnected,
    onClientDisconnected: onClientDisconnected,
  );

  static Future<CallbackChannel> _start({
    required String name,
    required String handshakeType,
    required int port,
    required void Function(Map<String, dynamic> message) onMessage,
    void Function()? onClientConnected,
    void Function()? onClientDisconnected,
  }) async {
    final channel = CallbackChannel._(name: name, handshakeType: handshakeType);
    channel._onMessage = onMessage;
    channel._onClientConnected = onClientConnected;
    channel._onClientDisconnected = onClientDisconnected;
    channel._listener = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    channel._listener!.listen(channel._adopt);
    return channel;
  }

  void _adopt(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _clients.add(socket);
    var handshakeSeen = false;
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) return;
            final decoded = _decode(trimmed);
            if (decoded == null) return;
            _onMessage(decoded);
            if (!handshakeSeen && isHandshake(decoded, handshakeType)) {
              handshakeSeen = true;
              _connected = true;
              _onClientConnected?.call();
            }
          },
          onDone: () => _release(socket, handshakeSeen),
          onError: (Object error) {
            DevLog.logError(error, scope: name);
            _release(socket, handshakeSeen);
          },
          cancelOnError: true,
        );
  }

  void _release(Socket socket, bool handshakeSeen) {
    _clients.remove(socket);
    socket.destroy();
    if (!handshakeSeen) return;
    // Only report a disconnect once no client remains for this channel.
    if (_clients.isEmpty && _connected) {
      _connected = false;
      _onClientDisconnected?.call();
    }
  }

  static Map<String, dynamic>? _decode(String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map) return parsed.cast<String, dynamic>();
    } catch (_) {
      // Non-JSON noise on a callback socket is ignored, not fatal.
    }
    return null;
  }

  void dispose() {
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    _connected = false;
    _listener?.close();
    _listener = null;
  }
}
