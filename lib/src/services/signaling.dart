import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class SignalingService {
  final String url;
  final String name;
  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _messages = StreamController.broadcast();

  SignalingService(this.url, this.name);

  Future<void> connect() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      // connected, client will explicitly join/create room
      _channel!.stream.listen((data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          _messages.add(msg);
        } catch (e) {
          // ignore
        }
      }, onDone: () {
        _messages.add({'type': 'disconnected'});
      }, onError: (error) {
        _messages.add({
          'type': 'error',
          'message': 'socket-error',
          'detail': error.toString(),
        });
      });
    } catch (e) {
      _messages.add({'type': 'error', 'message': 'connect-failed', 'detail': e.toString()});
      rethrow;
    }
  }

  void joinRoom(String roomId, bool isHost) {
    send({'type': isHost ? 'create' : 'join', 'name': name, 'room': roomId});
  }

  // Video signaling methods
  void sendVideoOffer(String peerId, String sdp) {
    send({
      'type': 'video-offer',
      'from': name,
      'to': peerId,
      'sdp': sdp,
    });
  }

  void sendVideoAnswer(String peerId, String sdp) {
    send({
      'type': 'video-answer',
      'from': name,
      'to': peerId,
      'sdp': sdp,
    });
  }

  void sendIceCandidate(
    String peerId,
    String candidate,
    int sdpMLineIndex,
    String sdpMid,
  ) {
    send({
      'type': 'ice-candidate',
      'from': name,
      'to': peerId,
      'candidate': candidate,
      'sdpMLineIndex': sdpMLineIndex,
      'sdpMid': sdpMid,
    });
  }

  Stream<Map<String, dynamic>> get messages => _messages.stream;

  void send(Map<String, dynamic> m) {
    try {
      _channel?.sink.add(jsonEncode(m));
    } catch (e) {
      _messages.add({
        'type': 'error',
        'message': 'send-failed',
        'detail': e.toString(),
      });
    }
  }

  void dispose() {
    _channel?.sink.close();
    _messages.close();
  }
}
