import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/signaling.dart';

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
  final List<String> _messages = [];
  final _textCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
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
    _textCtrl.dispose();
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
