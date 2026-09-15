import 'dart:async' show StreamController, unawaited;
import 'dart:convert' show Utf8Decoder, jsonDecode, jsonEncode;
import 'dart:io' show InternetAddress, ServerSocket, Socket, SocketOption;

class JarServer {
  JarServer._();

  static Future<JarServer> start({
    required void Function(String message) onMessage,
    required void Function() onClientConnected,
    required void Function() onClientDisconnected,
    int port = 3698,
  }) async {
    final server = JarServer._();
    server._onMessage = onMessage;
    server._onClientConnected = onClientConnected;
    server._onClientDisconnected = onClientDisconnected;
    server._listener = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    server._listener!.listen(
      (socket) => unawaited(server._handleSocket(socket)),
    );
    return server;
  }

  ServerSocket? _listener;
  void Function(String message)? _onMessage;
  void Function()? _onClientConnected;
  void Function()? _onClientDisconnected;
  Socket? _activeClient;

  int get port => _listener?.port ?? 0;

  Future<void> _handleSocket(Socket socket) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    var handshakeComplete = false;
    try {
      await for (final line in _lineReader(socket)) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        _onMessage?.call(trimmed);
        if (!handshakeComplete && _messageType(trimmed) == 'jar.hello') {
          handshakeComplete = true;
          _activeClient = socket;
          _onClientConnected?.call();
        }
      }
    } catch (_) {
      // The Android-side JAR reconnects automatically after a disconnect.
    } finally {
      if (identical(_activeClient, socket)) _activeClient = null;
      socket.destroy();
      if (handshakeComplete) _onClientDisconnected?.call();
    }
  }

  bool sendJson(Map<String, dynamic> message) {
    final client = _activeClient;
    if (client == null) return false;
    client.writeln(jsonEncode(message));
    return true;
  }

  Stream<String> _lineReader(Socket socket) {
    final controller = StreamController<String>();
    final buffer = StringBuffer();
    socket.listen(
      (data) {
        buffer.write(const Utf8Decoder().convert(data));
        var text = buffer.toString();
        var newline = text.indexOf('\n');
        while (newline >= 0) {
          controller.add(text.substring(0, newline));
          text = text.substring(newline + 1);
          newline = text.indexOf('\n');
        }
        buffer
          ..clear()
          ..write(text);
      },
      onDone: () {
        if (buffer.isNotEmpty) controller.add(buffer.toString());
        controller.close();
      },
      onError: (Object error, StackTrace stackTrace) {
        controller.addError(error, stackTrace);
        controller.close();
      },
      cancelOnError: true,
    );
    return controller.stream;
  }

  void dispose() {
    _activeClient?.destroy();
    _activeClient = null;
    _listener?.close();
  }
}

String? _messageType(String raw) {
  try {
    return (jsonDecode(raw) as Map<String, dynamic>)['type'] as String?;
  } catch (_) {
    return null;
  }
}
