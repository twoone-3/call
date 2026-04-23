import 'dart:io';
import 'dart:convert';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);

  final clients = <WebSocket>[];
  final rooms = <String, List<WebSocket>>{};
  final names = <WebSocket, String>{};
  final peerIds = <WebSocket, String>{};
  var peerSeq = 1;

  String allocatePeerId() => 'p${peerSeq++}';

  List<Map<String, String>> listPeerEntries(String room, WebSocket self) {
    final members = rooms[room] ?? const <WebSocket>[];
    final peers = <Map<String, String>>[];
    for (final ws in members) {
      if (ws == self) continue;
      final name = (names[ws] ?? '').trim();
      final peerId = (peerIds[ws] ?? '').trim();
      if (peerId.isEmpty) continue;
      peers.add({'peerId': peerId, 'name': name});
    }
    return peers;
  }

  WebSocket? findSocketByPeerIdInRoom(String room, String peerId) {
    final members = rooms[room] ?? const <WebSocket>[];
    for (final ws in members) {
      if ((peerIds[ws] ?? '') == peerId) {
        return ws;
      }
    }
    return null;
  }

  void broadcastRoomState(
    String room, [
    String? joinedName,
    String? joinedPeerId,
    bool isJoin = false,
  ]) {
    final count = rooms[room]?.length ?? 0;
    final members = rooms[room] ?? const <WebSocket>[];
    for (var c in members) {
      try {
        final payload = <String, dynamic>{
          'type': isJoin ? 'peer-joined' : 'room-state',
          'room': room,
          'onlineCount': count,
          'peers': listPeerEntries(room, c),
        };
        if (joinedName != null) {
          payload['name'] = joinedName;
          payload['peerId'] = joinedPeerId ?? '';
        }
        c.add(
          jsonEncode(payload),
        );
      } catch (_) {}
    }
  }

  WebSocket? findSocketByNameInRoom(String room, String name) {
    final members = rooms[room] ?? const <WebSocket>[];
    for (final ws in members) {
      if ((names[ws] ?? '') == name) {
        return ws;
      }
    }
    return null;
  }

  void removeClientFromRoom(WebSocket ws, String room) {
    final members = rooms[room];
    if (members == null || !members.contains(ws)) {
      names.remove(ws);
      return;
    }

    final leavingName = names[ws];
    final leavingPeerId = peerIds[ws];
    members.remove(ws);
    names.remove(ws);
    peerIds.remove(ws);

    final remaining = rooms[room] ?? const <WebSocket>[];
    if (leavingName != null && leavingName.isNotEmpty) {
      for (var c in remaining) {
        c.add(
          jsonEncode({
            'type': 'peer-left',
            'room': room,
            'name': leavingName,
            'peerId': leavingPeerId ?? '',
            'onlineCount': remaining.length,
            'peers': listPeerEntries(room, c),
          }),
        );
      }
    }

    if (remaining.isEmpty) {
      rooms.remove(room);
    } else {
      broadcastRoomState(room);
    }
  }

  void evictDuplicateNameInRoom(String room, String name, WebSocket incoming) {
    if (name.isEmpty) return;
    final members = List<WebSocket>.from(rooms[room] ?? const <WebSocket>[]);
    for (final member in members) {
      if (member == incoming) continue;
      if ((names[member] ?? '').trim() == name) {
        removeClientFromRoom(member, room);
        member.close(WebSocketStatus.normalClosure, 'duplicate-name-replaced');
        clients.remove(member);
      }
    }
  }

  await for (var request in server) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then((WebSocket ws) {
        print('Client connected: ${ws.hashCode}');
        ws.pingInterval = const Duration(seconds: 20);
        clients.add(ws);
        String? currentRoom;

        ws.listen((data) {
          try {
            final obj = jsonDecode(data as String) as Map<String, dynamic>;
            final type = obj['type'] as String? ?? '';
            if (type == 'create') {
              final room = obj['room'] as String? ?? '';
              final name = (obj['name'] as String? ?? '').trim();
              rooms.putIfAbsent(room, () => []);
              evictDuplicateNameInRoom(room, name, ws);
              rooms[room]!.add(ws);
              currentRoom = room;
              names[ws] = name;
              peerIds.putIfAbsent(ws, allocatePeerId);
              ws.add(jsonEncode({'type': 'created', 'room': room}));
              ws.add(
                jsonEncode({
                  'type': 'self-peer-id',
                  'peerId': peerIds[ws],
                  'name': name,
                }),
              );
              ws.add(
                jsonEncode({
                  'type': 'room-peers',
                  'room': room,
                  'peers': listPeerEntries(room, ws),
                }),
              );
              print('Room created: $room by ${ws.hashCode}');
              broadcastRoomState(room);
            } else if (type == 'join') {
              final room = obj['room'] as String? ?? '';
              if (rooms.containsKey(room)) {
                final name = (obj['name'] as String? ?? '').trim();
                evictDuplicateNameInRoom(room, name, ws);
                rooms[room]!.add(ws);
                currentRoom = room;
                names[ws] = name;
                peerIds.putIfAbsent(ws, allocatePeerId);
                ws.add(jsonEncode({'type': 'joined', 'room': room}));
                ws.add(
                  jsonEncode({
                    'type': 'self-peer-id',
                    'peerId': peerIds[ws],
                    'name': name,
                  }),
                );
                ws.add(
                  jsonEncode({
                    'type': 'room-peers',
                    'room': room,
                    'peers': listPeerEntries(room, ws),
                  }),
                );
                broadcastRoomState(room, names[ws], peerIds[ws], true);
                print('Client ${ws.hashCode} joined room $room');
              } else {
                ws.add(jsonEncode({'type': 'error', 'message': 'room-not-found'}));
              }
            } else if (type == 'leave') {
              final room = obj['room'] as String? ?? '';
              removeClientFromRoom(ws, room);
              currentRoom = null;
            } else {
              // relay to specific peer in the same room when `to` is set
              if (currentRoom != null && rooms.containsKey(currentRoom)) {
                final targetPeerId = (obj['toPeerId'] as String? ?? '').trim();
                final targetName = (obj['to'] as String? ?? '').trim();
                if (targetPeerId.isNotEmpty) {
                  final targetWs = findSocketByPeerIdInRoom(currentRoom!, targetPeerId);
                  if (targetWs != null && targetWs != ws) {
                    targetWs.add(jsonEncode(obj));
                  }
                } else if (targetName.isNotEmpty) {
                  final targetWs = findSocketByNameInRoom(currentRoom!, targetName);
                  if (targetWs != null && targetWs != ws) {
                    targetWs.add(jsonEncode(obj));
                  }
                } else {
                  for (var c in rooms[currentRoom]!) {
                    if (c != ws) c.add(jsonEncode(obj));
                  }
                }
              } else {
                for (var c in clients) {
                  if (c != ws) c.add(jsonEncode(obj));
                }
              }
            }
          } catch (e) {
            print('Invalid message: $e');
          }
        }, onDone: () {
          clients.remove(ws);
          final leftRoom = currentRoom;
          if (leftRoom != null) {
            removeClientFromRoom(ws, leftRoom);
          } else {
            names.remove(ws);
            peerIds.remove(ws);
          }
          print('Client disconnected: ${ws.hashCode}');
        }, onError: (err) {
          clients.remove(ws);
          final leftRoom = currentRoom;
          if (leftRoom != null) {
            removeClientFromRoom(ws, leftRoom);
          } else {
            names.remove(ws);
            peerIds.remove(ws);
          }
          print('WebSocket error: $err');
        });
      });
    } else {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('This endpoint is for WebSocket connections')
        ..close();
    }
  }
}
