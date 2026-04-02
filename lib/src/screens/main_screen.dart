import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../services/discovery.dart';
import '../services/room_host_service.dart';
import 'chat_room.dart';

const _defaultServerUrl = 'ws://0.0.0.0:8080';
const _prefsUsernameKey = 'main.username';
const _prefsRoomNameKey = 'main.room_name';
const _prefsRoomsKey = 'main.created_rooms';

class SavedRoomEntry {
  final String id;
  final String roomName;
  final String roomId;
  final String serverUrl;
  final DateTime createdAt;

  const SavedRoomEntry({
    required this.id,
    required this.roomName,
    required this.roomId,
    required this.serverUrl,
    required this.createdAt,
  });

  factory SavedRoomEntry.fromJson(Map<String, dynamic> json) {
    return SavedRoomEntry(
      id: json['id'] as String? ?? const Uuid().v4(),
      roomName: json['roomName'] as String? ?? '未命名房间',
      roomId: json['roomId'] as String? ?? '',
      serverUrl: json['serverUrl'] as String? ?? _defaultServerUrl,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'roomName': roomName,
    'roomId': roomId,
    'serverUrl': serverUrl,
    'createdAt': createdAt.toIso8601String(),
  };
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _nameCtrl = TextEditingController(text: 'user');
  final _roomNameCtrl = TextEditingController(text: '新房间');
  final _discovery = DiscoveryService();
  final _hostService = RoomHostService.instance;
  bool _discovering = false;
  bool _loadingPrefs = true;
  List<DiscoveredRoom> _rooms = const [];
  List<SavedRoomEntry> _savedRooms = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadState());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _roomNameCtrl.dispose();
    super.dispose();
  }

  Future<SharedPreferences> get _prefs async => SharedPreferences.getInstance();

  Future<void> _loadState() async {
    final prefs = await _prefs;
    final username = prefs.getString(_prefsUsernameKey);
    final draftRoomName = prefs.getString(_prefsRoomNameKey);
    final rawRooms = prefs.getStringList(_prefsRoomsKey) ?? const [];

    final loadedRooms = <SavedRoomEntry>[];
    for (final raw in rawRooms) {
      try {
        loadedRooms.add(
          SavedRoomEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
      } catch (_) {
        // Ignore malformed saved rooms.
      }
    }

    if (!mounted) return;
    setState(() {
      _nameCtrl.text = username?.trim().isNotEmpty == true ? username! : 'user';
      _roomNameCtrl.text = draftRoomName?.trim().isNotEmpty == true
          ? draftRoomName!
          : '新房间';
      _savedRooms = loadedRooms;
      _loadingPrefs = false;
    });

    await _refreshRooms();
  }

  Future<void> _saveUsername(String value) async {
    final prefs = await _prefs;
    await prefs.setString(_prefsUsernameKey, value);
  }

  Future<void> _saveRoomNameDraft(String value) async {
    final prefs = await _prefs;
    await prefs.setString(_prefsRoomNameKey, value);
  }

  Future<void> _saveSavedRooms(List<SavedRoomEntry> rooms) async {
    final prefs = await _prefs;
    await prefs.setStringList(
      _prefsRoomsKey,
      rooms.map((room) => jsonEncode(room.toJson())).toList(),
    );
  }

  Future<bool> _startHostRoom(SavedRoomEntry room) async {
    try {
      await _hostService.start(
        roomId: room.roomId,
        hostName: _nameCtrl.text.trim(),
      );
      if (mounted) {
        setState(() {});
      }
      return true;
    } catch (_) {
      if (!mounted) return false;
      await showDialog(
        context: context,
        builder: (_) =>
            const AlertDialog(content: Text('创建房间失败：端口不可用，请关闭占用端口的程序后重试。')),
      );
      return false;
    }
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

    final roomName = _roomNameCtrl.text.trim().isEmpty
        ? '新房间'
        : _roomNameCtrl.text.trim();
    final roomId = const Uuid().v4().substring(0, 8);
    final room = SavedRoomEntry(
      id: const Uuid().v4(),
      roomName: roomName,
      roomId: roomId,
      serverUrl: _defaultServerUrl,
      createdAt: DateTime.now(),
    );

    final started = await _startHostRoom(room);
    if (!started) return;

    final updatedRooms = [room, ..._savedRooms.where((r) => r.id != room.id)];
    setState(() => _savedRooms = updatedRooms);
    await _saveSavedRooms(updatedRooms);

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('房间已创建'),
        content: SelectableText('房间名称：$roomName\n房间ID：$roomId\n已保存到“我的房间”列表。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    await _openHostRoom(room);
    if (mounted) _refreshRooms();
  }

  Future<void> _openHostRoom(SavedRoomEntry room) async {
    if (!mounted) return;
    final started = await _startHostRoom(room);
    if (!started) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          serverUrl: room.serverUrl,
          name: _nameCtrl.text.trim(),
          roomId: room.roomId,
          isHost: true,
        ),
      ),
    );
  }

  Future<void> _openDiscoveredRoom(DiscoveredRoom room) async {
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

  Future<void> _confirmDeleteRoom(SavedRoomEntry room) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除房间'),
        content: Text('确定删除“${room.roomName}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (shouldDelete != true) return;

    if (_hostService.activeRoomId == room.roomId) {
      await _hostService.stop();
      if (mounted) {
        setState(() {});
      }
    }

    final updatedRooms = _savedRooms
        .where((item) => item.id != room.id)
        .toList();
    setState(() => _savedRooms = updatedRooms);
    await _saveSavedRooms(updatedRooms);
  }

  Widget _sectionHeader({required String title, Widget? action}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (action != null) action,
      ],
    );
  }

  Widget _buildMyRoomsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionHeader(title: '我的房间'),
            const SizedBox(height: 12),
            if (_savedRooms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('还没有创建过房间')),
              )
            else
              ..._savedRooms.map(
                (room) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: ListTile(
                      leading: const Icon(Icons.home_work_outlined),
                      title: Text(room.roomName),
                      subtitle: Text(
                        '房间ID: ${room.roomId}${_hostService.activeRoomId == room.roomId ? ' · 运行中' : ''}\n创建于: ${room.createdAt.toLocal().toString().split('.').first}',
                      ),
                      isThreeLine: true,
                      trailing: Wrap(
                        spacing: 8,
                        children: [
                          IconButton(
                            tooltip: '重新开房',
                            onPressed: () => _openHostRoom(room),
                            icon: const Icon(Icons.play_arrow),
                          ),
                          IconButton(
                            tooltip: '删除',
                            onPressed: () => _confirmDeleteRoom(room),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLanRoomsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _discovering ? '正在搜索局域网房间...' : '局域网房间 (${_rooms.length})',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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
            if (_rooms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('未发现房间，点击“刷新”重试')),
              )
            else
              ..._rooms.map(
                (room) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.lan),
                      title: Text('房间 ${room.roomId}'),
                      subtitle: Text(
                        '${room.hostName} · ${room.hostIp}:${room.wsPort}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openDiscoveredRoom(room),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VibeChat')),
      body: _loadingPrefs
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshRooms,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _sectionHeader(title: '个人设置'),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _nameCtrl,
                            onChanged: _saveUsername,
                            decoration: const InputDecoration(
                              labelText: '用户名',
                              hintText: '输入你的昵称',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _roomNameCtrl,
                            onChanged: _saveRoomNameDraft,
                            decoration: const InputDecoration(
                              labelText: '房间名称',
                              hintText: '例如：下午茶房间',
                            ),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _createRoom,
                            icon: const Icon(Icons.add_home_outlined),
                            label: const Text('创建房间（作为主机）'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildMyRoomsSection(),
                  const SizedBox(height: 12),
                  _buildLanRoomsSection(),
                ],
              ),
            ),
    );
  }
}
