import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io'
    show
        CompressionOptions,
        HttpRequest,
        HttpServer,
        HttpStatus,
        InternetAddress,
        WebSocket,
        WebSocketTransformer;

class ApkServer {
  ApkServer._();

  static Future<ApkServer> start({
    required void Function(String message) onMessage,
    required void Function() onClientConnected,
    required void Function() onClientDisconnected,
    int port = 3699,
  }) async {
    final server = ApkServer._();
    server._onMessage = onMessage;
    server._onClientConnected = onClientConnected;
    server._onClientDisconnected = onClientDisconnected;
    server._httpServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    server._httpServer!.listen(
      (request) => unawaited(server._handleRequest(request)),
    );
    return server;
  }

  HttpServer? _httpServer;
  void Function(String message)? _onMessage;
  void Function()? _onClientConnected;
  void Function()? _onClientDisconnected;
  final Set<WebSocket> _clients = <WebSocket>{};
  WebSocket? _activeClient;

  int get port => _httpServer?.port ?? 0;

  Future<void> _handleRequest(HttpRequest request) async {
    // AndroidDex.apk v1.2 connects to ws://127.0.0.1:3699 (the root path).
    // Keep /apk as an alias for compatibility with early host prototypes.
    if (request.uri.path != '/' && request.uri.path != '/apk') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      await request.response.close();
      return;
    }

    WebSocket? socket;
    var handshakeComplete = false;
    var disconnectReported = false;

    void reportDisconnect() {
      if (!handshakeComplete || disconnectReported) return;
      disconnectReported = true;
      _onClientDisconnected?.call();
    }

    try {
      socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
      );
      _clients.add(socket);
      socket.listen(
        (data) {
          final text = switch (data) {
            String value => value,
            List<int> value => utf8.decode(value),
            _ => '',
          };
          final trimmed = text.trim();
          if (trimmed.isEmpty) return;
          _onMessage?.call(trimmed);
          if (!handshakeComplete && _messageType(trimmed) == 'apk.hello') {
            handshakeComplete = true;
            _activeClient = socket;
            _onClientConnected?.call();
          }
        },
        onDone: () {
          _clients.remove(socket);
          if (identical(_activeClient, socket)) _activeClient = null;
          reportDisconnect();
        },
        onError: (_) {
          _clients.remove(socket);
          if (identical(_activeClient, socket)) _activeClient = null;
          reportDisconnect();
        },
        cancelOnError: true,
      );
    } catch (_) {
      if (socket != null) {
        _clients.remove(socket);
        if (identical(_activeClient, socket)) _activeClient = null;
        reportDisconnect();
        await socket.close();
      }
    }
  }

  bool sendJson(Map<String, dynamic> message) {
    final client = _activeClient;
    if (client == null || client.readyState != WebSocket.open) return false;
    client.add(jsonEncode(message));
    return true;
  }

  void dispose() {
    for (final client in _clients.toList()) {
      unawaited(client.close());
    }
    _clients.clear();
    _activeClient = null;
    _httpServer?.close();
  }
}

String? _messageType(String raw) {
  try {
    return (jsonDecode(raw) as Map<String, dynamic>)['type'] as String?;
  } catch (_) {
    return null;
  }
}
