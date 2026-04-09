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
  VideoService? _videoService;
  bool _showVideo = false;
  bool _videoInitialized = false;
  String? _remotePeerId;
  final Set<String> _announcedMembers = <String>{};
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

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
    if (widget.isHost) {
      _rtcLog('init role=host');
      _videoService = VideoService(
        peerId: widget.name,
        logger: _rtcLog,
        onRemoteStreamAdded: (stream) {
          _rtcLog('remote stream added (host)');
          _remoteRenderer.srcObject = stream;
          if (mounted) setState(() {});
        },
        onIceCandidate: (candidate, sdpMLineIndex, sdpMid) {
          if (_signaling != null) {
            _rtcLog('send ice -> ${_remotePeerId ?? '(room)'}');
            _signaling!.send({
              'type': 'ice-candidate',
              'from': widget.name,
              'room': widget.roomId,
              'to': _remotePeerId,
              'candidate': candidate,
              'sdpMLineIndex': sdpMLineIndex,
              'sdpMid': sdpMid,
            });
          }
        },
        onOfferCreated: (sdp) {
          if (_signaling != null) {
            _rtcLog('send offer -> ${_remotePeerId ?? '(room)'} (len=${sdp.length})');
            _signaling!.send({
              'type': 'video-offer',
              'from': widget.name,
              'room': widget.roomId,
              'to': _remotePeerId,
              'sdp': sdp,
            });
          }
        },
        onAnswerCreated: (sdp) {
          if (_signaling != null) {
            _rtcLog('send answer -> ${_remotePeerId ?? '(room)'} (len=${sdp.length})');
            _signaling!.send({
              'type': 'video-answer',
              'from': widget.name,
              'room': widget.roomId,
              'to': _remotePeerId,
              'sdp': sdp,
            });
          }
        },
      );
      try {
        await _videoService!.initialize();
        await _localRenderer.initialize();
        await _remoteRenderer.initialize();
        _localRenderer.srcObject = _videoService!.localStream;
        if (mounted) {
          setState(() {
            _videoInitialized = true;
            _showVideo = true;
          });
        }
        _rtcLog('host local video initialized');
      } catch (e) {
        _rtcLog('host initialize error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('视频初始化失败：$e')),
          );
        }
      }
    } else {
      _rtcLog('init role=guest');
      _videoService = VideoService(
        peerId: widget.name,
        logger: _rtcLog,
        onRemoteStreamAdded: (stream) {
          _rtcLog('remote stream added (guest)');
          _remoteRenderer.srcObject = stream;
          if (mounted) setState(() {});
        },
        onIceCandidate: (candidate, sdpMLineIndex, sdpMid) {
          if (_signaling != null) {
            _rtcLog('send ice -> ${_remotePeerId ?? '(room)'}');
            _signaling!.send({
              'type': 'ice-candidate',
              'from': widget.name,
              'room': widget.roomId,
              'to': _remotePeerId,
              'candidate': candidate,
              'sdpMLineIndex': sdpMLineIndex,
              'sdpMid': sdpMid,
            });
          }
        },
        onOfferCreated: (sdp) {
          if (_signaling != null) {
            _rtcLog('send offer -> ${_remotePeerId ?? '(room)'} (len=${sdp.length})');
            _signaling!.send({
              'type': 'video-offer',
              'from': widget.name,
              'room': widget.roomId,
              'to': _remotePeerId,
              'sdp': sdp,
            });
          }
        },
        onAnswerCreated: (sdp) {
          if (_signaling != null) {
            _rtcLog('send answer -> ${_remotePeerId ?? '(room)'} (len=${sdp.length})');
            _signaling!.send({
              'type': 'video-answer',
              'from': widget.name,
              'room': widget.roomId,
              'to': _remotePeerId,
              'sdp': sdp,
            });
          }
        },
      );
      try {
        await _videoService!.initialize();
        await _localRenderer.initialize();
        await _remoteRenderer.initialize();
        _localRenderer.srcObject = _videoService!.localStream;
        if (mounted) {
          setState(() => _videoInitialized = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _showVideo = true);
          });
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (mounted && _videoService != null) {
              _rtcLog('guest createOffer (post frame)');
              await _videoService!.createOffer();
            }
          });
        }
      } catch (e) {
        _rtcLog('guest initialize error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('视频初始化失败：$e')),
          );
        }
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

    _signaling!.joinRoom(widget.roomId, widget.isHost);
    _rtcLog('joinRoom sent: role=${widget.isHost ? 'host' : 'guest'}');
    _announcedMembers.add(widget.name);
    // announce presence so peers can learn our name
    _signaling!.send({'type': 'announce', 'name': widget.name, 'isHost': widget.isHost});
    _rtcLog('announce sent');
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
      } else if (type == 'peer-joined') {
        // Host re-announces when a new peer joins so late joiners can learn host id.
        if (widget.isHost) {
          _rtcLog('peer-joined received, host re-announce');
          _signaling?.send({
            'type': 'announce',
            'name': widget.name,
            'isHost': widget.isHost,
          });
        }
      } else if (type == 'announce') {
        final name = (m['name'] as String?)?.trim() ?? '';
        if (name.isEmpty) return;
        _rtcLog('announce from=$name');
        if (name != widget.name && _announcedMembers.add(name)) {
          _appendSystemMessage('$name 进入了房间');
        }
        if (_remotePeerId == null && name != widget.name) {
          _remotePeerId = name;
          _rtcLog('set remotePeerId=$_remotePeerId');
          // Reply with own identity so both ends have peer id even with out-of-order joins.
          _signaling?.send({
            'type': 'announce',
            'name': widget.name,
            'isHost': widget.isHost,
          });
          _rtcLog('announce reply sent');
          // if we're a guest and video is initialized, initiate offer
          if (!widget.isHost && _videoInitialized && _videoService != null) {
            _rtcLog('guest createOffer after announce');
            await _videoService!.createOffer();
          }
        }
      } else if (type == 'video-offer') {
        final from = (m['from'] as String? ?? '').trim();
        final sdp = m['sdp'] as String? ?? '';
        if (from.isEmpty || sdp.isEmpty) return;
        _rtcLog('video-offer from=$from len=${sdp.length}');
        if (_remotePeerId == null) _remotePeerId = from;
        if (_videoService == null) {
          _videoService = VideoService(
            peerId: widget.name,
            logger: _rtcLog,
            onRemoteStreamAdded: (stream) {
              _rtcLog('remote stream added (offer path)');
              _remoteRenderer.srcObject = stream;
              if (mounted) setState(() {});
            },
            onIceCandidate: (candidate, sdpMLineIndex, sdpMid) {
              if (_signaling != null) {
                _rtcLog('send ice (offer path) -> $from');
                _signaling!.send({
                  'type': 'ice-candidate',
                  'from': widget.name,
                  'room': widget.roomId,
                  'to': from,
                  'candidate': candidate,
                  'sdpMLineIndex': sdpMLineIndex,
                  'sdpMid': sdpMid,
                });
              }
            },
            onOfferCreated: (sdp) {
              _rtcLog('send offer (offer path) -> $from len=${sdp.length}');
              if (_signaling != null) {
                _signaling!.send({
                  'type': 'video-offer',
                  'from': widget.name,
                  'room': widget.roomId,
                  'to': from,
                  'sdp': sdp,
                });
              }
            },
            onAnswerCreated: (sdp) {
              _rtcLog('send answer (offer path) -> $from len=${sdp.length}');
              if (_signaling != null) {
                _signaling!.send({
                  'type': 'video-answer',
                  'from': widget.name,
                  'room': widget.roomId,
                  'to': from,
                  'sdp': sdp,
                });
              }
            },
          );
          try {
            await _videoService!.initialize();
            await _localRenderer.initialize();
            await _remoteRenderer.initialize();
            _localRenderer.srcObject = _videoService!.localStream;
            if (mounted) setState(() => _videoInitialized = true);
          } catch (_) {}
        }
        _rtcLog('setRemoteOffer begin');
        try {
          await _videoService!.setRemoteOffer(sdp);
          _rtcLog('setRemoteOffer done');
        } catch (e) {
          _rtcLog('setRemoteOffer failed: $e');
          return;
        }
        if (mounted) setState(() => _showVideo = true);
      } else if (type == 'video-answer') {
        final sdp = m['sdp'] as String? ?? '';
        if (sdp.isEmpty) return;
        _rtcLog('video-answer len=${sdp.length}');
        try {
          await _videoService?.setRemoteAnswer(sdp);
        } catch (e) {
          _rtcLog('setRemoteAnswer failed: $e');
        }
      } else if (type == 'ice-candidate') {
        final candidate = (m['candidate'] as String? ?? '').trim();
        final sdpMLineIndex = (m['sdpMLineIndex'] as num?)?.toInt() ?? 0;
        final sdpMid = (m['sdpMid'] as String? ?? '').trim();
        if (candidate.isEmpty) return;
        _rtcLog('ice-candidate recv mLine=$sdpMLineIndex mid=$sdpMid');
        await _videoService?.addIceCandidate(candidate, sdpMLineIndex, sdpMid);
      } else if (type == 'error') {
        final msg = m['message'] as String? ?? '';
        _rtcLog('error msg=$msg detail=${m['detail']}');
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
    await _initializeVideo();
  }

  @override
  void dispose() {
    _rtcLog('dispose');
    _signalingSub?.cancel();
    _videoService?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
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

  String _formatTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
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
        title: Text(widget.roomName),
        actions: [
          if (_videoInitialized)
            Tooltip(
              message: _videoService?.audioEnabled == true ? '关闭音频' : '开启音频',
              child: IconButton(
                onPressed: () async {
                  if (_videoService != null) {
                    final enabled = !(_videoService!.audioEnabled == true);
                    await _videoService!.setAudioEnabled(enabled);
                    if (mounted) setState(() {});
                  }
                },
                icon: Icon(_videoService?.audioEnabled == true
                    ? Icons.mic
                    : Icons.mic_off),
              ),
            ),
          if (_videoInitialized)
            Tooltip(
              message: _videoService?.videoEnabled == true ? '关闭视频' : '开启视频',
              child: IconButton(
                onPressed: () async {
                  if (_videoService != null) {
                    final enabled = !(_videoService!.videoEnabled == true);
                    await _videoService!.setVideoEnabled(enabled);
                    if (mounted) setState(() {});
                  }
                },
                icon: Icon(_videoService?.videoEnabled == true
                    ? Icons.videocam
                    : Icons.videocam_off),
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
              child: Row(
                children: [
                  Expanded(
                    child: _localRenderer.srcObject != null
                        ? RTCVideoView(
                            _localRenderer,
                            mirror: true,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          )
                        : const Center(
                            child: CircularProgressIndicator(),
                          ),
                  ),
                  const SizedBox(width: 1),
                  Expanded(
                    child: _remoteRenderer.srcObject != null
                        ? RTCVideoView(
                            _remoteRenderer,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          )
                        : Container(
                            color: Colors.black54,
                            child: const Center(
                              child: Text(
                                '等待远程视频...',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
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
