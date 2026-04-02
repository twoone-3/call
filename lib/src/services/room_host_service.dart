import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';

import 'discovery.dart';

class RoomHostService {
  RoomHostService._();

  static final RoomHostService instance = RoomHostService._();

  io.HttpServer? _server;
  final List<io.WebSocket> _clients = [];
  final DiscoveryService _discovery = DiscoveryService();

  String? _roomId;
  String? _roomName;
  String? _hostName;
  int? _port;

  String? get activeRoomId => _roomId;
  String? get activeRoomName => _roomName;

  bool get isRunning => _server != null;

  Future<void> start({
    required String roomId,
    required String roomName,
    required String hostName,
    int port = 8080,
  }) async {
    if (kIsWeb) {
      throw StateError('browser-cannot-host');
    }

    if (_server != null) {
      if (_roomId == roomId && _roomName == roomName) {
        return;
      }
      await stop();
    }

    final server = await io.HttpServer.bind(io.InternetAddress.anyIPv4, port);
    await _discovery.startHostAdvertiser(
      roomId: roomId,
      roomName: roomName,
      wsPort: server.port,
      hostName: hostName,
    );

    server.listen((io.HttpRequest request) {
      if (io.WebSocketTransformer.isUpgradeRequest(request)) {
        io.WebSocketTransformer.upgrade(request).then((io.WebSocket ws) {
          _clients.add(ws);
          ws.listen(
            (data) {
              try {
                final obj = jsonDecode(data as String) as Map<String, dynamic>;
                for (final client in List<io.WebSocket>.from(_clients)) {
                  if (client != ws) {
                    try {
                      client.add(jsonEncode(obj));
                    } catch (_) {}
                  }
                }
              } catch (_) {}
            },
            onDone: () {
              _clients.remove(ws);
            },
            onError: (_) {
              _clients.remove(ws);
            },
          );
        });
      } else {
        request.response
          ..statusCode = io.HttpStatus.forbidden
          ..write('WebSocket only')
          ..close();
      }
    });

    _server = server;
    _roomId = roomId;
    _roomName = roomName;
    _hostName = hostName;
    _port = server.port;
  }

  Future<void> stop() async {
    await _discovery.stopHostAdvertiser();

    for (final client in List<io.WebSocket>.from(_clients)) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();

    try {
      await _server?.close(force: true);
    } catch (_) {}

    _server = null;
    _roomId = null;
    _roomName = null;
    _hostName = null;
    _port = null;
  }
}
