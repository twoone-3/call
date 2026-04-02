import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../services/discovery.dart';
import '../services/room_host_service.dart';
import 'chat_room.dart';
import 'settings_screen.dart';

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

class _RoomListItem {
  final String id;
  final String roomName;
  final String roomId;
  final String serverUrl;
  final String hostName;
  final bool isMine;
  final bool isRunning;
  final DateTime? createdAt;
  final bool isDiscovered;

  const _RoomListItem({
    required this.id,
    required this.roomName,
    required this.roomId,
    required this.serverUrl,
    required this.hostName,
    required this.isMine,
    required this.isRunning,
    required this.createdAt,
    required this.isDiscovered,
  });
}

class _CreateRoomDialog extends StatefulWidget {
  final String initialRoomName;

  const _CreateRoomDialog({required this.initialRoomName});

  @override
  State<_CreateRoomDialog> createState() => _CreateRoomDialogState();
}

class _CreateRoomDialogState extends State<_CreateRoomDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialRoomName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!mounted) return;
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('创建房间'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: '房间名称',
            hintText: '例如：下午茶房间',
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.add),
          label: const Text('创建并开房'),
        ),
      ],
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _discovery = DiscoveryService();
  final _hostService = RoomHostService.instance;
  String _username = 'user';
  bool _discovering = false;
  bool _loadingPrefs = true;
  List<DiscoveredRoom> _rooms = const [];
  List<SavedRoomEntry> _savedRooms = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadState());
  }

  Future<SharedPreferences> get _prefs async => SharedPreferences.getInstance();

  Future<void> _loadState() async {
    final prefs = await _prefs;
    final username = prefs.getString(_prefsUsernameKey);
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
      _username = username?.trim().isNotEmpty == true ? username! : 'user';
      _savedRooms = loadedRooms;
      _loadingPrefs = false;
    });

    await _refreshRooms();
  }

  Future<void> _saveUsername(String value) async {
    final prefs = await _prefs;
    await prefs.setString(_prefsUsernameKey, value);
  }

  Future<void> _saveSavedRooms(List<SavedRoomEntry> rooms) async {
    final prefs = await _prefs;
    await prefs.setStringList(
      _prefsRoomsKey,
      rooms.map((room) => jsonEncode(room.toJson())).toList(),
    );
  }

  List<_RoomListItem> _buildMergedRooms() {
    final discoveredByRoomId = <String, DiscoveredRoom>{
      for (final room in _rooms) room.roomId: room,
    };
    final merged = <_RoomListItem>[];

    for (final room in _savedRooms) {
      final discovered = discoveredByRoomId.remove(room.roomId);
      merged.add(
        _RoomListItem(
          id: room.id,
          roomName: room.roomName,
          roomId: room.roomId,
          serverUrl: room.serverUrl,
          hostName: _username,
          isMine: true,
          isRunning: _hostService.activeRoomId == room.roomId,
          createdAt: room.createdAt,
          isDiscovered: discovered != null,
        ),
      );
    }

    for (final room in discoveredByRoomId.values) {
      merged.add(
        _RoomListItem(
          id: room.dedupeKey,
          roomName: room.roomName,
          roomId: room.roomId,
          serverUrl: room.serverUrl,
          hostName: room.hostName,
          isMine: false,
          isRunning: false,
          createdAt: null,
          isDiscovered: true,
        ),
      );
    }

    merged.sort((a, b) {
      if (a.isMine != b.isMine) return a.isMine ? -1 : 1;
      if (a.isRunning != b.isRunning) return a.isRunning ? -1 : 1;
      return a.roomName.compareTo(b.roomName);
    });

    return merged;
  }

  Future<bool> _startHostRoom(SavedRoomEntry room) async {
    try {
      await _hostService.start(
        roomId: room.roomId,
        roomName: room.roomName,
        hostName: _username,
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

  Future<void> _createRoom(String roomNameInput) async {
    if (kIsWeb) {
      await showDialog(
        context: context,
        builder: (_) =>
            const AlertDialog(content: Text('浏览器环境无法监听本地端口，不能创建房间。请使用桌面端开房。')),
      );
      return;
    }

    final roomName = roomNameInput.trim().isEmpty
        ? '新房间'
        : roomNameInput.trim();
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

    final prefs = await _prefs;
    await prefs.setString(_prefsRoomNameKey, roomName);

    final updatedRooms = [room, ..._savedRooms.where((r) => r.id != room.id)];
    setState(() => _savedRooms = updatedRooms);
    await _saveSavedRooms(updatedRooms);

    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已创建房间：$roomName')));

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          serverUrl: room.serverUrl,
          name: _username,
          roomName: room.roomName,
          roomId: room.roomId,
          isHost: true,
        ),
      ),
    );
    if (mounted) _refreshRooms();
  }

  Future<void> _openCreateRoomPopup() async {
    final prefs = await _prefs;
    final initialRoomName =
        prefs.getString(_prefsRoomNameKey)?.trim().isNotEmpty == true
        ? prefs.getString(_prefsRoomNameKey)!.trim()
        : '新房间';

    if (!mounted) return;

    final result = await showDialog<String>(
      context: context,
      builder: (_) => _CreateRoomDialog(initialRoomName: initialRoomName),
    );

    if (result == null) return;

    await _createRoom(result);
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(initialUsername: _username),
      ),
    );

    if (result == null) return;

    final normalized = result.trim().isEmpty ? 'user' : result.trim();
    setState(() => _username = normalized);
    await _saveUsername(normalized);
  }

  Future<void> _openHostRoom(SavedRoomEntry room) async {
    if (!mounted) return;
    if (_hostService.activeRoomId != room.roomId) {
      final started = await _startHostRoom(room);
      if (!started) return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          serverUrl: room.serverUrl,
          name: _username,
          roomName: room.roomName,
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
          name: _username,
          roomName: room.roomName,
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
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除房间'),
        content: Text('确定删除“${room.roomName}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
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

  Widget _buildRoomCard(_RoomListItem room) {
    final isRunning = room.isMine ? room.isRunning : room.isDiscovered;
    final roomTag = room.isMine ? '我的房间' : (room.isDiscovered ? '局域网' : null);

    final subtitle = room.isMine
        ? '创建于: ${room.createdAt?.toLocal().toString().split('.').first ?? '-'}'
        : '来自 ${room.hostName} 的局域网房间';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Stack(
          children: [
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              leading: const Icon(Icons.home_work_outlined),
              title: Text(room.roomName),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: isRunning ? Colors.green : Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(isRunning ? '运行中' : '未运行'),
                    const SizedBox(width: 8),
                    Flexible(child: Text(subtitle, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
              isThreeLine: false,
              trailing: Wrap(
                spacing: 8,
                children: [
                  IconButton(
                    tooltip: '进入',
                    onPressed: room.isMine
                        ? () => _openHostRoom(
                            SavedRoomEntry(
                              id: room.id,
                              roomName: room.roomName,
                              roomId: room.roomId,
                              serverUrl: room.serverUrl,
                              createdAt: room.createdAt ?? DateTime.now(),
                            ),
                          )
                        : () => _openDiscoveredRoom(
                            DiscoveredRoom(
                              roomId: room.roomId,
                              roomName: room.roomName,
                              hostIp: room.serverUrl
                                  .replaceFirst('ws://', '')
                                  .split(':')
                                  .first,
                              wsPort:
                                  int.tryParse(
                                    room.serverUrl
                                        .replaceFirst('ws://', '')
                                        .split(':')
                                        .last,
                                  ) ??
                                  8080,
                              hostName: room.hostName,
                            ),
                          ),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  if (room.isMine)
                    IconButton(
                      tooltip: '删除',
                      onPressed: () => _confirmDeleteRoom(
                        SavedRoomEntry(
                          id: room.id,
                          roomName: room.roomName,
                          roomId: room.roomId,
                          serverUrl: room.serverUrl,
                          createdAt: room.createdAt ?? DateTime.now(),
                        ),
                      ),
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ),
            ),
            if (roomTag != null)
              Positioned(
                top: 8,
                right: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    child: Text(
                      roomTag,
                      style: Theme.of(context).textTheme.labelSmall,
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
    final mergedRooms = _buildMergedRooms();

    return Scaffold(
      appBar: AppBar(
        title: const Text('LAN Chat'),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: _loadingPrefs
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshRooms,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  _sectionHeader(
                    title: _discovering
                        ? '正在搜索局域网房间...'
                        : '所有房间 (${mergedRooms.length})',
                  ),
                  const SizedBox(height: 12),
                  if (mergedRooms.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(child: Text('还没有房间，点击右下角加号创建')),
                    )
                  else
                    ...mergedRooms.map(_buildRoomCard),
                  const SizedBox(height: 88),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCreateRoomPopup,
        tooltip: '创建房间',
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}
