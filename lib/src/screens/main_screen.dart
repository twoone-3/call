import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'chat_room.dart';
import '../services/discovery.dart';

const _defaultServerUrl = 'ws://0.0.0.0:8080';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _nameCtrl = TextEditingController(text: 'user');
  final _discovery = DiscoveryService();
  bool _discovering = false;
  List<DiscoveredRoom> _rooms = const [];

  @override
  void initState() {
    super.initState();
    _refreshRooms();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _createRoom() async {
    if (kIsWeb) {
      await showDialog(
        context: context,
        builder: (_) =>
            const AlertDialog(content: Text('浏览器环境无法监听本地端口，不能创建房间。请使用桌面端开房。')),
      );
      return;
    }

    final roomId = const Uuid().v4().substring(0, 8);

    // show room id to user, then navigate to chat
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('房间已创建'),
        content: SelectableText('房间ID：$roomId\n请把此房间ID发给想加入的人。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          serverUrl: _defaultServerUrl,
          name: _nameCtrl.text.trim(),
          roomId: roomId,
          isHost: true,
        ),
      ),
    );
    if (mounted) _refreshRooms();
  }

  Future<void> _joinDiscoveredRoom(DiscoveredRoom room) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          serverUrl: room.serverUrl,
          name: _nameCtrl.text.trim(),
          roomId: room.roomId,
          isHost: false,
        ),
      ),
    );
    if (mounted) _refreshRooms();
  }

  Future<void> _refreshRooms() async {
    if (_discovering) return;

    setState(() => _discovering = true);
    List<DiscoveredRoom> rooms;
    try {
      rooms = await _discovery.discoverRooms();
    } finally {
      if (!mounted) return;
      setState(() => _discovering = false);
    }

    if (!mounted) return;
    setState(() => _rooms = rooms);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('局域网 聊天室')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 12),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _createRoom,
              child: const Text('创建房间（作为主机）'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _discovering ? '正在搜索局域网房间...' : '局域网房间 (${_rooms.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: _discovering ? null : _refreshRooms,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _rooms.isEmpty
                  ? const Center(child: Text('未发现房间，点击“刷新”重试'))
                  : ListView.separated(
                      itemCount: _rooms.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final room = _rooms[i];
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.lan),
                            title: Text('房间 ${room.roomId}'),
                            subtitle: Text(
                              '${room.hostName} · ${room.hostIp}:${room.wsPort}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _joinDiscoveredRoom(room),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
