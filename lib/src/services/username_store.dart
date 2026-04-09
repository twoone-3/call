import 'dart:io';

class UsernameStore {
  UsernameStore._();

  static final UsernameStore instance = UsernameStore._();

  Future<String?> readUsername() async {
    final file = await _usernameFile();
    if (!await file.exists()) return null;

    final value = await file.readAsString();
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> writeUsername(String value) async {
    final file = await _usernameFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(value.trim());
  }

  Future<File> _usernameFile() async {
    final baseDir = _baseDirectory();
    final profileId = _stableHash(Platform.resolvedExecutable);
    return File('${baseDir.path}${Platform.pathSeparator}profiles${Platform.pathSeparator}$profileId${Platform.pathSeparator}username.txt');
  }

  Directory _baseDirectory() {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['APPDATA'];
      if (localAppData != null && localAppData.trim().isNotEmpty) {
        return Directory('$localAppData${Platform.pathSeparator}LAN Chat');
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null && home.trim().isNotEmpty) {
        return Directory('$home${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support${Platform.pathSeparator}LAN Chat');
      }
    } else {
      final home = Platform.environment['HOME'];
      if (home != null && home.trim().isNotEmpty) {
        return Directory('$home${Platform.pathSeparator}.config${Platform.pathSeparator}lan_chat');
      }
    }

    return Directory.systemTemp.createTempSync('lan_chat_');
  }

  String _stableHash(String input) {
    var hash = 0x811c9dc5;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}