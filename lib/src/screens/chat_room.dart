import 'package:flutter/material.dart';
import '../services/signaling.dart';
import '../services/chat_history_cache.dart';

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
  final ChatHistoryCache _cache = ChatHistoryCache.instance;
  final List<ChatMessageRecord> _messages = [];
  final _textCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _userAtBottom = true;
  int _unreadCount = 0;

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

  Future<void> _setup() async {
    _signaling = SignalingService(widget.serverUrl, widget.name);
    try {
      await _signaling!.connect();
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

    _signaling!.joinRoom(widget.roomId, widget.isHost);
    _signaling!.messages.listen((m) async {
      final type = m['type'] as String? ?? '';
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
      entries.add(_ChatMessageEntry(message));
    }

    return entries;
  }

  String _avatarLabel(ChatMessageRecord message) {
    if (message.isMine) return '我';
    final text = message.from.trim();
    if (text.isEmpty) return '?';
    return text[0].toUpperCase();
  }

  Widget _buildMessageBubble(ChatMessageRecord message) {
    final isMine = message.isMine;
    final bubbleColor = isMine
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: isMine
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.secondary,
      foregroundColor: isMine
          ? Theme.of(context).colorScheme.onPrimary
          : Theme.of(context).colorScheme.onSecondary,
      child: Text(
        _avatarLabel(message),
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isMine ? '我' : message.from,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatTime(message.time),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
              const SizedBox(height: 6),
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

  @override
  Widget build(BuildContext context) {
    final timelineEntries = _buildTimelineEntries();

    return Scaffold(
      appBar: AppBar(title: Text(widget.roomName)),
      body: Column(
        children: [
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
