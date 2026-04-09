import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DiscoveredRoom {
  final String roomId;
  final String roomName;
  final String hostIp;
  final int wsPort;
  final String hostName;
  final int onlineCount;

  const DiscoveredRoom({
    required this.roomId,
    required this.roomName,
    required this.hostIp,
    required this.wsPort,
    required this.hostName,
    required this.onlineCount,
  });

  String get serverUrl => 'ws://$hostIp:$wsPort';

  String get dedupeKey => '$roomId@$hostIp:$wsPort';
}

class DiscoveryService {
  static const int discoveryPort = 40404;
  static const String _probeType = 'discover-call-room-v1';
  static const String _announceType = 'call-room-v1';

  RawDatagramSocket? _hostSocket;

  Future<void> startHostAdvertiser({
    required String roomId,
    required String roomName,
    required int wsPort,
    required String hostName,
    required int Function() onlineCountProvider,
  }) async {
    await stopHostAdvertiser();

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;

      try {
        final obj = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (obj['type'] != _probeType) return;

        final resp = jsonEncode({
          'type': _announceType,
          'roomId': roomId,
          'roomName': roomName,
          'wsPort': wsPort,
          'hostName': hostName,
          'onlineCount': onlineCountProvider(),
        });
        socket.send(utf8.encode(resp), dg.address, dg.port);
      } catch (_) {
        // Ignore malformed UDP packets.
      }
    });

    _hostSocket = socket;
  }

  Future<void> stopHostAdvertiser() async {
    _hostSocket?.close();
    _hostSocket = null;
  }

  Future<List<InternetAddress>> _probeTargets() async {
    final targets = <String, InternetAddress>{
      '255.255.255.255': InternetAddress('255.255.255.255'),
    };

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final ni in interfaces) {
        for (final addr in ni.addresses) {
          final octets = addr.address.split('.');
          if (octets.length != 4) continue;
          final directed = '${octets[0]}.${octets[1]}.${octets[2]}.255';
          targets[directed] = InternetAddress(directed);
        }
      }
    } catch (_) {
      // Fall back to global broadcast only.
    }

    return targets.values.toList();
  }

  Future<List<DiscoveredRoom>> discoverRooms({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );

    socket.broadcastEnabled = true;
    final found = <String, DiscoveredRoom>{};

    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      try {
        final obj = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (obj['type'] != _announceType) return;

        final roomId = (obj['roomId'] as String? ?? '').trim();
        final roomName = (obj['roomName'] as String? ?? '').trim();
        final port = (obj['wsPort'] as num?)?.toInt() ?? 0;
        final hostName = (obj['hostName'] as String? ?? 'host').trim();
        if (roomId.isEmpty || port <= 0) return;

        final room = DiscoveredRoom(
          roomId: roomId,
          roomName: roomName.isEmpty ? roomId : roomName,
          hostIp: dg.address.address,
          wsPort: port,
          hostName: hostName.isEmpty ? 'host' : hostName,
          onlineCount: (obj['onlineCount'] as num?)?.toInt() ?? 1,
        );
        found[room.dedupeKey] = room;
      } catch (_) {
        // Ignore malformed UDP packets.
      }
    });

    final probe = jsonEncode({'type': _probeType});
    final targets = await _probeTargets();
    for (var round = 0; round < 3; round++) {
      for (final target in targets) {
        socket.send(utf8.encode(probe), target, discoveryPort);
      }
      if (round < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    await Future<void>.delayed(timeout);
    await sub.cancel();
    socket.close();
    return found.values.toList();
  }
}
