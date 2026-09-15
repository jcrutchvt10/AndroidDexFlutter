import 'dart:convert';
import 'dart:io';

class MediaServer {
  MediaServer._();

  static Future<MediaServer> start({
    void Function(String message)? onMessage,
  }) async {
    final instance = MediaServer._();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 3701);
    instance._server = server;
    server.listen((socket) => instance._handleSocket(socket, onMessage));
    return instance;
  }

  ServerSocket? _server;
  final Set<Socket> _clients = <Socket>{};

  void _handleSocket(Socket socket, void Function(String)? onMessage) {
    _clients.add(socket);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => onMessage?.call(line),
          onDone: () => _clients.remove(socket),
          onError: (_) => _clients.remove(socket),
          cancelOnError: true,
        );
  }

  void dispose() {
    for (final client in _clients) {
      client.destroy();
    }
    _clients.clear();
    _server?.close();
  }
}
