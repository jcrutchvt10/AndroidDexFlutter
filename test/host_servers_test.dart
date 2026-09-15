import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/host/apk_server.dart';
import 'package:androiddex_host/host/jar_server.dart';

void main() {
  test(
    'APK server accepts the v1.2 root WebSocket and waits for hello',
    () async {
      final connected = Completer<void>();
      final disconnected = Completer<void>();
      final messages = <String>[];
      final server = await ApkServer.start(
        port: 0,
        onMessage: messages.add,
        onClientConnected: connected.complete,
        onClientDisconnected: disconnected.complete,
      );
      addTearDown(server.dispose);

      final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}');
      expect(connected.isCompleted, isFalse);
      socket.add('{"type":"apk.hello","status":"ready"}');

      await connected.future.timeout(const Duration(seconds: 2));
      expect(messages.single, contains('apk.hello'));
      expect(server.sendJson({'id': 'one', 'command': 'get_all_apps'}), isTrue);
      expect(await socket.first, contains('get_all_apps'));
      await socket.close();
      await disconnected.future.timeout(const Duration(seconds: 2));
    },
  );

  test('JAR server handles multiple lines and waits for jar.hello', () async {
    final connected = Completer<void>();
    final disconnected = Completer<void>();
    final messages = <String>[];
    final server = await JarServer.start(
      port: 0,
      onMessage: messages.add,
      onClientConnected: connected.complete,
      onClientDisconnected: disconnected.complete,
    );
    addTearDown(server.dispose);

    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.write(
      '{"type":"clipboard.text","content":"hello"}\n'
      '{"type":"jar.hello","status":"ready"}\n',
    );

    await connected.future.timeout(const Duration(seconds: 2));
    expect(messages, hasLength(2));
    expect(server.sendJson({'id': 'two', 'command': 'ping'}), isTrue);
    final response = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    expect(response, contains('"command":"ping"'));
    await socket.close();
    await disconnected.future.timeout(const Duration(seconds: 2));
  });
}
