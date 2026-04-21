import 'dart:io';
import 'dart:convert';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);

  final clients = <WebSocket>[];
  final rooms = <String, List<WebSocket>>{};
  final names = <WebSocket, String>{};

  void broadcastRoomState(String room, [String? joinedName, bool isJoin = false]) {
    final count = rooms[room]?.length ?? 0;
    final members = rooms[room] ?? const <WebSocket>[];
    for (var c in members) {
      try {
        c.add(
          jsonEncode({
            'type': isJoin ? 'peer-joined' : 'room-state',
            'room': room,
            if (joinedName != null) 'name': joinedName,
            'onlineCount': count,
          }),
        );
      } catch (_) {}
    }
  }

  await for (var request in server) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then((WebSocket ws) {
        print('Client connected: ${ws.hashCode}');
        clients.add(ws);
        String? currentRoom;

        ws.listen((data) {
          try {
            final obj = jsonDecode(data as String) as Map<String, dynamic>;
            final type = obj['type'] as String? ?? '';
            if (type == 'create') {
              final room = obj['room'] as String? ?? '';
              rooms.putIfAbsent(room, () => []).add(ws);
              currentRoom = room;
              names[ws] = (obj['name'] as String? ?? '').trim();
              ws.add(jsonEncode({'type': 'created', 'room': room}));
              print('Room created: $room by ${ws.hashCode}');
              broadcastRoomState(room);
            } else if (type == 'join') {
              final room = obj['room'] as String? ?? '';
              if (rooms.containsKey(room)) {
                rooms[room]!.add(ws);
                currentRoom = room;
                names[ws] = (obj['name'] as String? ?? '').trim();
                ws.add(jsonEncode({'type': 'joined', 'room': room}));
                broadcastRoomState(room, names[ws], true);
                print('Client ${ws.hashCode} joined room $room');
              } else {
                ws.add(jsonEncode({'type': 'error', 'message': 'room-not-found'}));
              }
            } else if (type == 'leave') {
              final room = obj['room'] as String? ?? '';
              rooms[room]?.remove(ws);
              names.remove(ws);
              currentRoom = null;
              broadcastRoomState(room);
            } else {
              // relay to members of the same room if present, otherwise broadcast to all
              if (currentRoom != null && rooms.containsKey(currentRoom)) {
                for (var c in rooms[currentRoom]!) {
                  if (c != ws) c.add(jsonEncode(obj));
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
            rooms[leftRoom]?.remove(ws);
            names.remove(ws);
            broadcastRoomState(leftRoom);
          }
          print('Client disconnected: ${ws.hashCode}');
        }, onError: (err) {
          clients.remove(ws);
          final leftRoom = currentRoom;
          if (leftRoom != null) {
            rooms[leftRoom]?.remove(ws);
            names.remove(ws);
            broadcastRoomState(leftRoom);
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
