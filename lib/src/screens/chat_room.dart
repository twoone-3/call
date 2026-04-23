import 'dart:async';
import 'package:flutter/material.dart';
import '../services/signaling.dart';
import '../services/chat_history_cache.dart';
import '../services/room_host_service.dart';
import '../services/video_service.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';

abstract class _ChatTimelineEntry {
  const _ChatTimelineEntry();
}

class _ChatDateEntry extends _ChatTimelineEntry {
  final DateTime date;

  const _ChatDateEntry(this.date);
}

class _ChatMessageEntry extends _ChatTimelineEntry {
  final ChatMessageRecord message;

  const _ChatMessageEntry(this.message);
}

class _ChatSystemEntry extends _ChatTimelineEntry {
  final String text;

  const _ChatSystemEntry(this.text);
}

class ChatRoomScreen extends StatefulWidget {
  final String serverUrl;
  final String name;
  final String roomName;
  final String roomId;
  final bool isHost;

  const ChatRoomScreen({
    super.key,
    required this.serverUrl,
    required this.name,
    required this.roomName,
    required this.roomId,
    required this.isHost,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen>
    with WidgetsBindingObserver {
  SignalingService? _signaling;
  StreamSubscription<Map<String, dynamic>>? _signalingSub;
  final ChatHistoryCache _cache = ChatHistoryCache.instance;
  final List<ChatMessageRecord> _messages = [];
  final _textCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _userAtBottom = true;
  int _unreadCount = 0;
  final Map<String, VideoService> _peerServices = {};
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Set<String> _creatingPeers = {};
  final Set<String> _knownPeers = {};
  final Set<String> _pendingPeers = {};
  final Map<String, String> _peerNames = {};
  final Map<String, String> _pendingOffers = {};
  final Map<String, String> _pendingAnswers = {};
  final Map<String, List<Map<String, dynamic>>> _pendingCandidates = {};
  final Map<String, int> _offerRetryCounts = {};
  final Map<String, Timer> _offerRetryTimers = {};
  MediaStream? _localStream;
  String? _selfPeerId;
  bool _audioEnabled = true;
  bool _videoEnabled = true;
  bool _showVideo = false;
  bool _videoInitialized = false;
  int _onlineCount = 1;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  String get _rtcTag =>
      '${widget.isHost ? 'host' : 'guest'}:${widget.name}/${widget.roomId}';

  void _rtcLog(String message) {
    debugPrint('[RTC][$_rtcTag] $message');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _messages.addAll(_cache.getRoomMessages(widget.roomId));
    _setup();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToBottom(immediate: true);
      }
    });
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_isAtBottom()) {
      _scrollToBottom();
    }
  }

  bool _isAtBottom() {
    if (!_scrollController.hasClients) return true;
    return _scrollController.position.extentAfter < 96;
  }

  void _handleScroll() {
    final atBottom = _isAtBottom();
    if (atBottom != _userAtBottom) {
      _userAtBottom = atBottom;
    }
    if (atBottom && _unreadCount != 0 && mounted) {
      setState(() => _unreadCount = 0);
    }
  }

  void _scrollToBottom({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (immediate) {
        _scrollController.jumpTo(target);
      } else {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  int _stableHash(String input) {
    var hash = 0x811c9dc5;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  Color _avatarColor(String name) {
    final colors = <Color>[
      Colors.blue,
      Colors.teal,
      Colors.green,
      Colors.orange,
      Colors.red,
      Colors.pink,
      Colors.indigo,
      Colors.cyan,
      Colors.amber,
      Colors.deepPurple,
    ];
    return colors[_stableHash(name) % colors.length];
  }

  String _avatarLabel(ChatMessageRecord message) {
    final text = message.from.trim();
    if (text.isEmpty) return '?';
    return text.substring(0, 1).toUpperCase();
  }

  void _appendSystemMessage(String text) {
    final now = DateTime.now();
    final shouldStickToBottom = _isAtBottom();
    final message = ChatMessageRecord(
      from: '系统',
      text: text,
      time: now,
      isMine: false,
    );
    setState(() {
      _messages.add(message);
      if (!shouldStickToBottom) {
        _unreadCount++;
      }
    });
    _cache.appendMessage(widget.roomId, message);
    if (shouldStickToBottom) {
      _scrollToBottom();
    }
  }

  void _updateOnlineCount(int count) {
    final normalized = count < 1 ? 1 : count;
    if (_onlineCount == normalized) return;
    if (!mounted) {
      _onlineCount = normalized;
      return;
    }
    setState(() => _onlineCount = normalized);
  }

  bool _shouldInitiateOfferForPeer(String peerId) {
    final self = _selfPeerId;
    if (self == null || self.isEmpty) return false;
    return self.compareTo(peerId) > 0;
  }

  Future<void> _kickstartMeshHandshake() async {
    if (_selfPeerId == null || _selfPeerId!.isEmpty) return;
    final peers = {..._knownPeers, ..._peerServices.keys, ..._pendingPeers};
    for (final peerId in peers) {
      if (!_shouldInitiateOfferForPeer(peerId)) continue;
      await _ensurePeerConnection(peerId, initiateOffer: false);
      final service = _peerServices[peerId];
      final renderer = _remoteRenderers[peerId];
      if (service == null) continue;
      if (renderer?.srcObject != null) continue;
      try {
        await service.createOffer();
        _scheduleOfferRetry(peerId);
      } catch (e) {
        _rtcLog('kickstart offer failed peer=$peerId error=$e');
      }
    }
  }

  String _peerLabel(String peerId) {
    final name = (_peerNames[peerId] ?? '').trim();
    if (name.isNotEmpty) return name;
    return peerId;
  }

  String _messagePeerId(Map<String, dynamic> m, {required String keyPrefix}) {
    final fromPeerId = (m['${keyPrefix}PeerId'] as String? ?? '').trim();
    if (fromPeerId.isNotEmpty) return fromPeerId;
    return (m[keyPrefix] as String? ?? '').trim();
  }

  void _scheduleOfferRetry(String peerId) {
    _offerRetryTimers.remove(peerId)?.cancel();
    final retries = _offerRetryCounts[peerId] ?? 0;
    if (retries >= 2) return;
    _offerRetryTimers[peerId] = Timer(const Duration(seconds: 5), () async {
      final service = _peerServices[peerId];
      final renderer = _remoteRenderers[peerId];
      if (service == null || renderer == null) return;
      if (renderer.srcObject != null) return;
      _offerRetryCounts[peerId] = retries + 1;
      _rtcLog('retry offer to $peerId attempt=${retries + 1}');
      try {
        await service.createOffer();
      } catch (_) {}
      _scheduleOfferRetry(peerId);
    });
  }

  Future<void> _setLocalAudioEnabled(bool enabled) async {
    _audioEnabled = enabled;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = enabled;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _setLocalVideoEnabled(bool enabled) async {
    _videoEnabled = enabled;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getVideoTracks()) {
        track.enabled = enabled;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _ensurePeerConnection(
    String peerId, {
    required bool initiateOffer,
  }) async {
    if (peerId.isEmpty || peerId == _selfPeerId) return;
    if (_peerServices.containsKey(peerId) || _creatingPeers.contains(peerId)) {
      return;
    }
    if (_localStream == null) {
      _knownPeers.add(peerId);
      _pendingPeers.add(peerId);
      _rtcLog('skip ensurePeerConnection $peerId: local stream not ready');
      return;
    }
    _pendingPeers.remove(peerId);
    _creatingPeers.add(peerId);
    _knownPeers.add(peerId);
    _rtcLog('create peer connection: $peerId initiate=$initiateOffer');
    final renderer = RTCVideoRenderer();
    await renderer.initialize();

    final service = VideoService(
      peerId: '${widget.name}->$peerId',
      sharedLocalStream: _localStream,
      logger: _rtcLog,
      onRemoteStreamAdded: (stream) {
        _rtcLog('remote stream added from=$peerId');
        renderer.srcObject = stream;
        _offerRetryTimers.remove(peerId)?.cancel();
        _offerRetryCounts.remove(peerId);
        if (mounted) setState(() {});
      },
      onIceCandidate: (candidate, sdpMLineIndex, sdpMid) {
        _signaling?.send({
          'type': 'ice-candidate',
          'from': widget.name,
          'fromPeerId': _selfPeerId,
          'room': widget.roomId,
          'to': peerId,
          'toPeerId': peerId,
          'candidate': candidate,
          'sdpMLineIndex': sdpMLineIndex,
          'sdpMid': sdpMid,
        });
      },
      onOfferCreated: (sdp) {
        _signaling?.send({
          'type': 'video-offer',
          'from': widget.name,
          'fromPeerId': _selfPeerId,
          'room': widget.roomId,
          'to': peerId,
          'toPeerId': peerId,
          'sdp': sdp,
        });
      },
      onAnswerCreated: (sdp) {
        _signaling?.send({
          'type': 'video-answer',
          'from': widget.name,
          'fromPeerId': _selfPeerId,
          'room': widget.roomId,
          'to': peerId,
          'toPeerId': peerId,
          'sdp': sdp,
        });
      },
    );

    try {
      await service.initialize();
      await service.setAudioEnabled(_audioEnabled);
      await service.setVideoEnabled(_videoEnabled);
      _peerServices[peerId] = service;
      _remoteRenderers[peerId] = renderer;
      if (mounted) {
        setState(() {
          _videoInitialized = true;
          _showVideo = true;
        });
      }
      await _applyPendingForPeer(peerId);
      if (initiateOffer) {
        await _kickstartMeshHandshake();
      }
    } catch (e) {
      _rtcLog('create peer failed: $peerId error=$e');
      await service.dispose();
      await renderer.dispose();
    } finally {
      _creatingPeers.remove(peerId);
    }
  }

  Future<void> _applyPendingForPeer(String peerId) async {
    final service = _peerServices[peerId];
    if (service == null) return;

    final offer = _pendingOffers.remove(peerId);
    if (offer != null && offer.isNotEmpty) {
      try {
        await service.setRemoteOffer(offer);
      } catch (e) {
        _rtcLog('apply pending offer failed peer=$peerId error=$e');
      }
    }

    final answer = _pendingAnswers.remove(peerId);
    if (answer != null && answer.isNotEmpty) {
      try {
        await service.setRemoteAnswer(answer);
      } catch (e) {
        _rtcLog('apply pending answer failed peer=$peerId error=$e');
      }
    }

    final candidates = _pendingCandidates.remove(peerId) ?? const [];
    for (final c in candidates) {
      final candidate = (c['candidate'] as String? ?? '').trim();
      final sdpMLineIndex = (c['sdpMLineIndex'] as num?)?.toInt() ?? 0;
      final sdpMid = (c['sdpMid'] as String? ?? '').trim();
      if (candidate.isEmpty) continue;
      try {
        await service.addIceCandidate(candidate, sdpMLineIndex, sdpMid);
      } catch (_) {}
    }
  }

  Future<void> _removePeerConnection(String peerId) async {
    _offerRetryTimers.remove(peerId)?.cancel();
    _offerRetryCounts.remove(peerId);
    final service = _peerServices.remove(peerId);
    final renderer = _remoteRenderers.remove(peerId);
    _knownPeers.remove(peerId);
    _pendingPeers.remove(peerId);
    _peerNames.remove(peerId);
    _pendingOffers.remove(peerId);
    _pendingAnswers.remove(peerId);
    _pendingCandidates.remove(peerId);
    if (service != null) {
      await service.dispose();
    }
    if (renderer != null) {
      await renderer.dispose();
    }
    if (mounted) setState(() {});
  }

  Set<String> _extractPeers(Map<String, dynamic> m) {
    final peers = <String>{};
    final raw = m['peers'] as List?;
    if (raw == null) return peers;
    for (final item in raw) {
      if (item is String) {
        final id = item.trim();
        if (id.isNotEmpty && id != widget.name) {
          peers.add(id);
          _peerNames.putIfAbsent(id, () => id);
        }
        continue;
      }
      if (item is Map) {
        final peerId = (item['peerId'] as String? ?? '').trim();
        final name = (item['name'] as String? ?? '').trim();
        if (peerId.isEmpty) continue;
        if (name.isNotEmpty) {
          _peerNames[peerId] = name;
        }
        if (peerId != _selfPeerId) {
          peers.add(peerId);
        }
      }
    }
    return peers;
  }

  Future<void> _reconcilePeers(Set<String> peers) async {
    final toRemove = _remoteRenderers.keys
        .where((peerId) => !peers.contains(peerId))
        .toList();
    for (final peerId in toRemove) {
      await _removePeerConnection(peerId);
    }
    _knownPeers
      ..clear()
      ..addAll(peers);
    _pendingPeers.removeWhere((peerId) => !peers.contains(peerId));
    for (final peerId in peers) {
      await _ensurePeerConnection(
        peerId,
        initiateOffer: _shouldInitiateOfferForPeer(peerId),
      );
    }
  }

  Future<void> _drainPendingPeers() async {
    if (_localStream == null) return;
    final peers = {..._knownPeers, ..._pendingPeers};
    if (peers.isEmpty) return;
    for (final peerId in peers) {
      await _ensurePeerConnection(
        peerId,
        initiateOffer: _shouldInitiateOfferForPeer(peerId),
      );
    }
  }

  Future<void> _initializeVideo() async {
    if (_videoInitialized) return;
    _rtcLog('initializeVideo start');
    // Request runtime permissions on mobile
    if (Platform.isAndroid || Platform.isIOS) {
      final statuses = await [Permission.camera, Permission.microphone].request();
      final cam = statuses[Permission.camera];
      final mic = statuses[Permission.microphone];
      _rtcLog(
        'permission status: camera=${cam?.isGranted}, mic=${mic?.isGranted}',
      );
      if (cam?.isGranted != true || mic?.isGranted != true) {
        if (mounted) {
          await showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('需要权限'),
              content: const Text('请授予相机和麦克风权限以使用视频通话功能。'),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('知道了')),
              ],
            ),
          );
        }
        return;
      }
    }
    try {
      await _localRenderer.initialize();
      _localStream = await VideoService.createLocalMediaStream();
      _localRenderer.srcObject = _localStream;
      await _setLocalAudioEnabled(_audioEnabled);
      await _setLocalVideoEnabled(_videoEnabled);
      if (mounted) {
        setState(() {
          _videoInitialized = true;
          _showVideo = true;
        });
      }
      _rtcLog('local media initialized');
      await _drainPendingPeers();
    } catch (e) {
      _rtcLog('initializeVideo error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('视频初始化失败：$e')),
        );
      }
    }
  }

  Future<void> _setup() async {
    _rtcLog('setup signaling: ${widget.serverUrl}');
    _signaling = SignalingService(widget.serverUrl, widget.name);
    try {
      await _signaling!.connect();
      _rtcLog('signaling connected');
    } catch (e) {
      _rtcLog('signaling connect failed: $e');
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) =>
            AlertDialog(content: const Text('无法连接到房主，房间不存在或主机不可达。')),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }

    _signaling!.joinRoom(widget.roomId, widget.isHost);
    _rtcLog('joinRoom sent: role=${widget.isHost ? 'host' : 'guest'}');
    _signalingSub = _signaling!.messages.listen((m) async {
      final type = m['type'] as String? ?? '';
      _rtcLog('recv type=$type');
      if (type == 'chat') {
        final from = (m['from'] as String? ?? '').trim();
        final text = (m['text'] as String? ?? '').trim();
        if (text.isEmpty) return;

        final rawTs = m['ts'];
        DateTime time;
        if (rawTs is num) {
          time = DateTime.fromMillisecondsSinceEpoch(rawTs.toInt());
        } else if (rawTs is String) {
          time = DateTime.tryParse(rawTs) ?? DateTime.now();
        } else {
          time = DateTime.now();
        }

        final message = ChatMessageRecord(
          from: from.isEmpty ? 'unknown' : from,
          text: text,
          time: time,
          isMine: from == widget.name,
        );
        final shouldStickToBottom = _isAtBottom();
        setState(() {
          _messages.add(message);
          if (!shouldStickToBottom) {
            _unreadCount++;
          }
        });
        _cache.appendMessage(widget.roomId, message);
        if (shouldStickToBottom) {
          _scrollToBottom();
        }
      } else if (type == 'room-state') {
        final count = (m['onlineCount'] as num?)?.toInt() ?? 1;
        _updateOnlineCount(count);
        final peers = _extractPeers(m);
        if (peers.isNotEmpty || _knownPeers.isNotEmpty || _remoteRenderers.isNotEmpty) {
          await _reconcilePeers(peers);
        }
      } else if (type == 'self-peer-id') {
        final id = (m['peerId'] as String? ?? '').trim();
        if (id.isNotEmpty) {
          _selfPeerId = id;
          _peerNames[id] = widget.name;
          _rtcLog('self peer id assigned: $id');
          await _drainPendingPeers();
          await _kickstartMeshHandshake();
        }
      } else if (type == 'room-peers') {
        final peers = _extractPeers(m);
        await _reconcilePeers(peers);
      } else if (type == 'peer-joined') {
        final name = (m['name'] as String?)?.trim() ?? '';
        final peerId = (m['peerId'] as String?)?.trim() ?? '';
        final count = (m['onlineCount'] as num?)?.toInt() ?? _onlineCount;
        _updateOnlineCount(count);
        final peers = _extractPeers(m);
        if (peers.isNotEmpty) {
          await _reconcilePeers(peers);
        }
        if (name.isNotEmpty && name != widget.name) {
          _appendSystemMessage('$name 进入了房间');
        }
        if (peerId.isNotEmpty && peerId != _selfPeerId) {
          if (name.isNotEmpty) _peerNames[peerId] = name;
          _knownPeers.add(peerId);
          await _ensurePeerConnection(
            peerId,
            initiateOffer: _shouldInitiateOfferForPeer(peerId),
          );
        }
      } else if (type == 'peer-left') {
        final name = (m['name'] as String?)?.trim() ?? '';
        final count = (m['onlineCount'] as num?)?.toInt() ?? (_onlineCount - 1);
        _updateOnlineCount(count);
        final peers = _extractPeers(m);
        if (peers.isNotEmpty) {
          await _reconcilePeers(peers);
        }
        final peerId = (m['peerId'] as String?)?.trim() ?? '';
        if (peerId.isNotEmpty) {
          await _removePeerConnection(peerId);
        }
        if (name.isNotEmpty && name != widget.name) {
          _appendSystemMessage('$name 离开了房间');
        }
      } else if (type == 'video-offer') {
        final from = _messagePeerId(m, keyPrefix: 'from');
        final to = _messagePeerId(m, keyPrefix: 'to');
        final fromName = (m['from'] as String? ?? '').trim();
        final sdp = m['sdp'] as String? ?? '';
        if (to.isNotEmpty && to != _selfPeerId) return;
        if (from.isEmpty || sdp.isEmpty) return;
        if (fromName.isNotEmpty) _peerNames[from] = fromName;
        _rtcLog('video-offer from=$from len=${sdp.length}');
        _knownPeers.add(from);
        await _ensurePeerConnection(from, initiateOffer: false);
        final service = _peerServices[from];
        if (service == null) {
          _pendingOffers[from] = sdp;
          return;
        }
        try {
          await service.setRemoteOffer(sdp);
        } catch (e) {
          _rtcLog('setRemoteOffer failed: $e');
          _pendingOffers[from] = sdp;
          return;
        }
      } else if (type == 'video-answer') {
        final from = _messagePeerId(m, keyPrefix: 'from');
        final to = _messagePeerId(m, keyPrefix: 'to');
        final fromName = (m['from'] as String? ?? '').trim();
        final sdp = m['sdp'] as String? ?? '';
        if (to.isNotEmpty && to != _selfPeerId) return;
        if (sdp.isEmpty) return;
        if (from.isEmpty) return;
        if (fromName.isNotEmpty) _peerNames[from] = fromName;
        _knownPeers.add(from);
        await _ensurePeerConnection(from, initiateOffer: false);
        final service = _peerServices[from];
        if (service == null) {
          _pendingAnswers[from] = sdp;
          return;
        }
        _rtcLog('video-answer from=$from len=${sdp.length}');
        try {
          await service.setRemoteAnswer(sdp);
        } catch (e) {
          _rtcLog('setRemoteAnswer failed: $e');
          _pendingAnswers[from] = sdp;
        }
      } else if (type == 'ice-candidate') {
        final from = _messagePeerId(m, keyPrefix: 'from');
        final to = _messagePeerId(m, keyPrefix: 'to');
        final fromName = (m['from'] as String? ?? '').trim();
        final candidate = (m['candidate'] as String? ?? '').trim();
        final sdpMLineIndex = (m['sdpMLineIndex'] as num?)?.toInt() ?? 0;
        final sdpMid = (m['sdpMid'] as String? ?? '').trim();
        if (to.isNotEmpty && to != _selfPeerId) return;
        if (from.isEmpty) return;
        if (candidate.isEmpty) return;
        if (fromName.isNotEmpty) _peerNames[from] = fromName;
        _knownPeers.add(from);
        await _ensurePeerConnection(from, initiateOffer: false);
        final service = _peerServices[from];
        if (service == null) {
          _pendingCandidates.putIfAbsent(from, () => []).add({
            'candidate': candidate,
            'sdpMLineIndex': sdpMLineIndex,
            'sdpMid': sdpMid,
          });
          return;
        }
        _rtcLog('ice-candidate recv mLine=$sdpMLineIndex mid=$sdpMid');
        try {
          await service.addIceCandidate(candidate, sdpMLineIndex, sdpMid);
        } catch (_) {
          _pendingCandidates.putIfAbsent(from, () => []).add({
            'candidate': candidate,
            'sdpMLineIndex': sdpMLineIndex,
            'sdpMid': sdpMid,
          });
        }
      } else if (type == 'error') {
        final msg = m['message'] as String? ?? '';
        _rtcLog('error msg=$msg detail=${m['detail']}');
        if (msg == 'room-not-found' && !widget.isHost) {
          if (!mounted) return;
          await showDialog(
            context: context,
            builder: (_) => AlertDialog(content: const Text('房间不存在。')),
          );
          if (!mounted) return;
          Navigator.of(context).pop();
        }
      }
    });
    await _initializeVideo();
  }

  @override
  void dispose() {
    _rtcLog('dispose');
    _signaling?.leaveRoom(widget.roomId);
    _signalingSub?.cancel();
    for (final timer in _offerRetryTimers.values) {
      timer.cancel();
    }
    for (final service in _peerServices.values) {
      service.dispose();
    }
    for (final renderer in _remoteRenderers.values) {
      renderer.dispose();
    }
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
    }
    _localRenderer.dispose();
    _cache.saveRoomMessages(widget.roomId, _messages);
    _signaling?.dispose();
    _textCtrl.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _sendChat() {
    final t = _textCtrl.text.trim();
    if (t.isEmpty) return;
    final now = DateTime.now();
    final message = ChatMessageRecord(
      from: widget.name,
      text: t,
      time: now,
      isMine: true,
    );

    _signaling?.send({
      'type': 'chat',
      'room': widget.roomId,
      'text': t,
      'from': widget.name,
      'ts': now.millisecondsSinceEpoch,
    });
    setState(() {
      _messages.add(message);
      _textCtrl.clear();
      _unreadCount = 0;
    });
    _cache.appendMessage(widget.roomId, message);
    _scrollToBottom();
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatDateDivider(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final target = DateTime(date.year, date.month, date.day);

    if (_isSameDay(target, today)) return '今天';
    if (_isSameDay(target, yesterday)) return '昨天';

    const weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];
    return '${date.month}月${date.day}日 周${weekdayNames[date.weekday - 1]}';
  }

  List<_ChatTimelineEntry> _buildTimelineEntries() {
    final entries = <_ChatTimelineEntry>[];
    DateTime? lastDate;

    for (final message in _messages) {
      final messageDate = DateTime(
        message.time.year,
        message.time.month,
        message.time.day,
      );
      if (lastDate == null || !_isSameDay(lastDate, messageDate)) {
        entries.add(_ChatDateEntry(messageDate));
        lastDate = messageDate;
      }
      if (message.from == '系统') {
        entries.add(_ChatSystemEntry(message.text));
        continue;
      }
      entries.add(_ChatMessageEntry(message));
    }

    return entries;
  }

  Widget _buildMessageBubble(ChatMessageRecord message) {
    final isMine = message.isMine;
    final bubbleColor = isMine
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final avatarColor = _avatarColor(message.from);

    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: avatarColor,
      foregroundColor: Colors.white,
      child: Text(
        _avatarLabel(message),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );

    final bubble = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Card(
        color: bubbleColor,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: isMine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(message.text),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: isMine
            ? [bubble, const SizedBox(width: 8), avatar]
            : [avatar, const SizedBox(width: 8), bubble],
      ),
    );
  }

  Widget _buildSystemNotice(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDateDivider(DateTime date) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _formatDateDivider(date),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnreadBanner() {
    if (_unreadCount <= 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Align(
        alignment: Alignment.center,
        child: FilledButton.tonalIcon(
          onPressed: () {
            setState(() => _unreadCount = 0);
            _scrollToBottom(immediate: true);
          },
          icon: const Icon(Icons.mark_chat_unread_outlined),
          label: Text('未读消息 $_unreadCount 条'),
        ),
      ),
    );
  }

  Widget _buildVideoGrid() {
    final tiles = <Widget>[];
    tiles.add(
      _buildVideoTile(
        title: '${widget.name} (我)',
        child: _localRenderer.srcObject != null
            ? RTCVideoView(
                _localRenderer,
                mirror: true,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            : const Center(child: CircularProgressIndicator()),
      ),
    );
    final peers = _remoteRenderers.keys.toList()..sort();
    for (final peerId in peers) {
      final renderer = _remoteRenderers[peerId]!;
      tiles.add(
        _buildVideoTile(
          title: _peerLabel(peerId),
          child: renderer.srcObject != null
              ? RTCVideoView(
                  renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : const Center(
                  child: Text(
                    '等待视频...',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
        ),
      );
    }

    int crossAxisCount;
    if (tiles.length <= 2) {
      crossAxisCount = 2;
    } else if (tiles.length <= 4) {
      crossAxisCount = 2;
    } else {
      crossAxisCount = 3;
    }

    return GridView.count(
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: 1,
      mainAxisSpacing: 1,
      children: tiles,
    );
  }

  Widget _buildVideoTile({required String title, required Widget child}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black54, child: child),
        Positioned(
          left: 8,
          top: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmEndMeeting() async {
    if (!widget.isHost) return;

    final shouldEnd = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('结束会议'),
        content: const Text('结束后，局域网内成员将无法继续加入该会议。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('结束会议'),
          ),
        ],
      ),
    );

    if (shouldEnd != true) return;

    if (RoomHostService.instance.activeRoomId == widget.roomId) {
      await RoomHostService.instance.stop();
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final timelineEntries = _buildTimelineEntries();

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.roomName}（$_onlineCount）'),
        actions: [
          if (_videoInitialized)
            Tooltip(
              message: _audioEnabled ? '关闭音频' : '开启音频',
              child: IconButton(
                onPressed: () async {
                  await _setLocalAudioEnabled(!_audioEnabled);
                },
                icon: Icon(_audioEnabled ? Icons.mic : Icons.mic_off),
              ),
            ),
          if (_videoInitialized)
            Tooltip(
              message: _videoEnabled ? '关闭视频' : '开启视频',
              child: IconButton(
                onPressed: () async {
                  await _setLocalVideoEnabled(!_videoEnabled);
                },
                icon: Icon(_videoEnabled ? Icons.videocam : Icons.videocam_off),
              ),
            ),
          if (_videoInitialized)
            Tooltip(
              message: _showVideo ? '隐藏视频' : '显示视频',
              child: IconButton(
                onPressed: () {
                  setState(() => _showVideo = !_showVideo);
                },
                icon: Icon(_showVideo
                    ? Icons.close
                    : Icons.videocam_outlined),
              ),
            ),
          if (widget.isHost)
            TextButton.icon(
              onPressed: _confirmEndMeeting,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('结束会议'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_showVideo && _videoInitialized)
            Container(
              height: 240,
              color: Colors.black87,
              child: _buildVideoGrid(),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: timelineEntries.length,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemBuilder: (_, i) {
                final entry = timelineEntries[i];
                if (entry is _ChatDateEntry) {
                  return _buildDateDivider(entry.date);
                }
                if (entry is _ChatSystemEntry) {
                  return _buildSystemNotice(entry.text);
                }
                return _buildMessageBubble(
                  (entry as _ChatMessageEntry).message,
                );
              },
            ),
          ),
          _buildUnreadBanner(),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    minLines: 1,
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendChat(),
                    style: Theme.of(context).textTheme.bodyLarge,
                    decoration: InputDecoration(
                      hintText: '输入消息，回车发送',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _sendChat,
                  icon: const Icon(Icons.send_rounded),
                  label: const Text('发送'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
