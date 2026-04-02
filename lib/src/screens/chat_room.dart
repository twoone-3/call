import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/signaling.dart';
import '../services/discovery.dart';

class ChatRoomScreen extends StatefulWidget {
  final String serverUrl;
  final String name;
  final String roomId;
  final bool isHost;

  const ChatRoomScreen({
    super.key,
    required this.serverUrl,
    required this.name,
    required this.roomId,
    required this.isHost,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  late SignalingService _signaling;
  final DiscoveryService _discovery = DiscoveryService();
  io.HttpServer? _server;
  final List<io.WebSocket> _clients = [];
  final List<String> _messages = [];
  final _textCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    // If this client is host, start an embedded WebSocket signaling server
    if (widget.isHost && !kIsWeb) {
      try {
        final uri = Uri.parse(widget.serverUrl);
        final port = uri.port == 0 ? 8080 : uri.port;
        _server = await io.HttpServer.bind(io.InternetAddress.anyIPv4, port);
        await _discovery.startHostAdvertiser(
          roomId: widget.roomId,
          wsPort: port,
          hostName: widget.name,
        );
        _server!.listen((io.HttpRequest request) {
          if (io.WebSocketTransformer.isUpgradeRequest(request)) {
            io.WebSocketTransformer.upgrade(request).then((io.WebSocket ws) {
              _clients.add(ws);
              ws.listen(
                (data) {
                  try {
                    final obj =
                        jsonDecode(data as String) as Map<String, dynamic>;
                    // broadcast to all clients in this room
                    for (var c in List<io.WebSocket>.from(_clients)) {
                      if (c != ws) {
                        try {
                          c.add(jsonEncode(obj));
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
      } catch (_) {
        await _discovery.stopHostAdvertiser();
        try {
          await _server?.close(force: true);
        } catch (_) {}
        _server = null;
        if (mounted) {
          await showDialog(
            context: context,
            builder: (_) =>
                const AlertDialog(content: Text('创建房间失败：端口不可用，请关闭占用端口的程序后重试。')),
          );
          Navigator.of(context).pop();
        }
        return;
      }
    }

    _signaling = SignalingService(widget.serverUrl, widget.name);
    try {
      await _signaling.connect();
    } catch (e) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (_) =>
              AlertDialog(content: const Text('无法连接到房主，房间不存在或主机不可达。')),
        );
        Navigator.of(context).pop();
      }
      return;
    }

    _signaling.joinRoom(widget.roomId, widget.isHost);
    _signaling.messages.listen((m) async {
      final type = m['type'] as String? ?? '';
      if (type == 'chat') {
        setState(() => _messages.add('${m['from']}: ${m['text']}'));
      } else if (type == 'error') {
        final msg = m['message'] as String? ?? '';
        if (msg == 'room-not-found' && !widget.isHost) {
          if (mounted) {
            await showDialog(
              context: context,
              builder: (_) => AlertDialog(content: const Text('房间不存在。')),
            );
            Navigator.of(context).pop();
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _signaling.dispose();
    _discovery.stopHostAdvertiser();
    _textCtrl.dispose();
    try {
      for (var c in _clients) {
        c.close();
      }
      _server?.close(force: true);
    } catch (_) {}
    super.dispose();
  }

  void _sendChat() {
    final t = _textCtrl.text.trim();
    if (t.isEmpty) return;
    _signaling.send({
      'type': 'chat',
      'room': widget.roomId,
      'text': t,
      'from': widget.name,
    });
    setState(() {
      _messages.add('${widget.name} (me): $t');
      _textCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('房间: ${widget.roomId}')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (_, i) => ListTile(title: Text(_messages[i])),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    decoration: const InputDecoration(hintText: '输入消息'),
                  ),
                ),
                IconButton(onPressed: _sendChat, icon: const Icon(Icons.send)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
