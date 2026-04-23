import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';

import 'discovery.dart';

class RoomHostService {
  RoomHostService._();

  static final RoomHostService instance = RoomHostService._();

  io.HttpServer? _server;
  final List<io.WebSocket> _clients = [];
  final Map<io.WebSocket, String> _clientNames = {};
  final Map<io.WebSocket, String> _clientPeerIds = {};
  final DiscoveryService _discovery = DiscoveryService();
  int _peerSeq = 1;

  String? _roomId;
  String? _roomName;


  String? get activeRoomId => _roomId;
  String? get activeRoomName => _roomName;
  int get onlineCount => _clients.length;

  bool get isRunning => _server != null;

  String _allocatePeerId() => 'p${_peerSeq++}';

  List<Map<String, String>> _peerEntriesFor(io.WebSocket self) {
    final peers = <Map<String, String>>[];
    for (final ws in _clients) {
      if (ws == self) continue;
      final peerId = (_clientPeerIds[ws] ?? '').trim();
      if (peerId.isEmpty) continue;
      peers.add({
        'peerId': peerId,
        'name': (_clientNames[ws] ?? '').trim(),
      });
    }
    return peers;
  }

  io.WebSocket? _findByPeerId(String peerId) {
    for (final ws in _clients) {
      if ((_clientPeerIds[ws] ?? '') == peerId) {
        return ws;
      }
    }
    return null;
  }

  io.WebSocket? _findByName(String name) {
    for (final ws in _clients) {
      if ((_clientNames[ws] ?? '') == name) {
        return ws;
      }
    }
    return null;
  }

  void _broadcastRoomState({
    String? joinedName,
    String? joinedPeerId,
    bool isJoin = false,
  }) {
    final roomId = _roomId;
    if (roomId == null) return;
    for (final ws in List<io.WebSocket>.from(_clients)) {
      final payload = <String, dynamic>{
        'type': isJoin ? 'peer-joined' : 'room-state',
        'room': roomId,
        'onlineCount': onlineCount,
        'peers': _peerEntriesFor(ws),
      };
      if (joinedName != null) {
        payload['name'] = joinedName;
        payload['peerId'] = joinedPeerId ?? '';
      }
      try {
        ws.add(jsonEncode(payload));
      } catch (_) {}
    }
  }

  void _removeClient(io.WebSocket ws) {
    if (!_clients.contains(ws)) {
      _clientNames.remove(ws);
      _clientPeerIds.remove(ws);
      return;
    }

    final roomId = _roomId;
    final leftName = (_clientNames.remove(ws) ?? '').trim();
    final leftPeerId = (_clientPeerIds.remove(ws) ?? '').trim();
    _clients.remove(ws);

    if (roomId != null && leftPeerId.isNotEmpty) {
      for (final client in List<io.WebSocket>.from(_clients)) {
        try {
          client.add(jsonEncode({
            'type': 'peer-left',
            'room': roomId,
            'name': leftName,
            'peerId': leftPeerId,
            'onlineCount': onlineCount,
            'peers': _peerEntriesFor(client),
          }));
        } catch (_) {}
      }
      _broadcastRoomState();
    }
  }

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
      onlineCountProvider: () => onlineCount,
    );

    server.listen((io.HttpRequest request) {
      if (io.WebSocketTransformer.isUpgradeRequest(request)) {
        io.WebSocketTransformer.upgrade(request).then((io.WebSocket ws) {
          ws.pingInterval = const Duration(seconds: 20);
          _clients.add(ws);
          _clientPeerIds.putIfAbsent(ws, _allocatePeerId);
          ws.listen(
            (data) {
              try {
                final obj = jsonDecode(data as String) as Map<String, dynamic>;
                final type = obj['type'] as String? ?? '';
                final name = (obj['name'] as String? ?? '').trim();
                if (type == 'create' || type == 'join') {
                  if (name.isNotEmpty) {
                    _clientNames[ws] = name;
                  }
                  try {
                    ws.add(jsonEncode({
                      'type': type == 'create' ? 'created' : 'joined',
                      'room': roomId,
                    }));
                    ws.add(jsonEncode({
                      'type': 'self-peer-id',
                      'peerId': _clientPeerIds[ws],
                      'name': _clientNames[ws] ?? '',
                    }));
                    ws.add(jsonEncode({
                      'type': 'room-peers',
                      'room': roomId,
                      'peers': _peerEntriesFor(ws),
                    }));
                  } catch (_) {}
                  _broadcastRoomState(
                    joinedName: _clientNames[ws] ?? '',
                    joinedPeerId: _clientPeerIds[ws],
                    isJoin: true,
                  );
                  return;
                }

                if (type == 'leave') {
                  _removeClient(ws);
                  return;
                }

                final targetPeerId = (obj['toPeerId'] as String? ?? '').trim();
                final targetName = (obj['to'] as String? ?? '').trim();
                if (targetPeerId.isNotEmpty) {
                  final target = _findByPeerId(targetPeerId);
                  if (target != null && target != ws) {
                    target.add(jsonEncode(obj));
                  }
                  return;
                }
                if (targetName.isNotEmpty) {
                  final target = _findByName(targetName);
                  if (target != null && target != ws) {
                    target.add(jsonEncode(obj));
                  }
                  return;
                }

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
              _removeClient(ws);
            },
            onError: (_) {
              _removeClient(ws);
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
  }

  Future<void> stop() async {
    await _discovery.stopHostAdvertiser();

    for (final client in List<io.WebSocket>.from(_clients)) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();
    _clientNames.clear();
    _clientPeerIds.clear();
    _peerSeq = 1;

    try {
      await _server?.close(force: true);
    } catch (_) {}

    _server = null;
    _roomId = null;
    _roomName = null;
  }
}
