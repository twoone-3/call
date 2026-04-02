import 'dart:io';
import 'dart:convert';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('Signaling server running on ws://0.0.0.0:8080');

  final clients = <WebSocket>[];
  final rooms = <String, List<WebSocket>>{};

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
              ws.add(jsonEncode({'type': 'created', 'room': room}));
              print('Room created: $room by ${ws.hashCode}');
            } else if (type == 'join') {
              final room = obj['room'] as String? ?? '';
              if (rooms.containsKey(room)) {
                rooms[room]!.add(ws);
                currentRoom = room;
                ws.add(jsonEncode({'type': 'joined', 'room': room}));
                // notify others in room
                for (var c in rooms[room]!) {
                  if (c != ws) c.add(jsonEncode({'type': 'peer-joined', 'room': room}));
                }
                print('Client ${ws.hashCode} joined room $room');
              } else {
                ws.add(jsonEncode({'type': 'error', 'message': 'room-not-found'}));
              }
            } else if (type == 'leave') {
              final room = obj['room'] as String? ?? '';
              rooms[room]?.remove(ws);
              currentRoom = null;
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
          if (currentRoom != null) rooms[currentRoom!]?.remove(ws);
          print('Client disconnected: ${ws.hashCode}');
        }, onError: (err) {
          clients.remove(ws);
          if (currentRoom != null) rooms[currentRoom!]?.remove(ws);
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
