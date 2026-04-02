class ChatMessageRecord {
  final String from;
  final String text;
  final DateTime time;
  final bool isMine;

  const ChatMessageRecord({
    required this.from,
    required this.text,
    required this.time,
    required this.isMine,
  });
}

class ChatHistoryCache {
  ChatHistoryCache._();

  static final ChatHistoryCache instance = ChatHistoryCache._();

  final Map<String, List<ChatMessageRecord>> _roomMessages = {};

  List<ChatMessageRecord> getRoomMessages(String roomId) {
    final data = _roomMessages[roomId] ?? const <ChatMessageRecord>[];
    return List<ChatMessageRecord>.from(data);
  }

  void saveRoomMessages(String roomId, List<ChatMessageRecord> messages) {
    _roomMessages[roomId] = List<ChatMessageRecord>.from(messages);
  }

  void appendMessage(String roomId, ChatMessageRecord message) {
    final list = _roomMessages.putIfAbsent(roomId, () => <ChatMessageRecord>[]);
    list.add(message);
  }

  void clearRoomMessages(String roomId) {
    _roomMessages.remove(roomId);
  }
}
