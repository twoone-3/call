import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class VideoService {
  final String peerId;
  final Function(MediaStream stream) onRemoteStreamAdded;
  final Function(String candidate, int sdpMLineIndex, String sdpMid)
  onIceCandidate;
  final Function(String sdp) onOfferCreated;
  final Function(String sdp) onAnswerCreated;
  final void Function(String message)? logger;
  final MediaStream? sharedLocalStream;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  bool _ownsLocalStream = false;

  bool _audioEnabled = true;
  bool _videoEnabled = true;

  VideoService({
    required this.peerId,
    required this.onRemoteStreamAdded,
    required this.onIceCandidate,
    required this.onOfferCreated,
    required this.onAnswerCreated,
    this.sharedLocalStream,
    this.logger,
  });

  void _log(String message) {
    logger?.call('[VideoService/$peerId] $message');
  }

  String _normalizeSdp(String sdp) {
    final lines = sdp
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
    return '${lines.join('\r\n')}\r\n';
  }

  Future<void> initialize() async {
    _log('initialize start');
    await _setupLocalStream();
    await _createPeerConnection();
    _log('initialize done');
  }

  static Future<MediaStream> createLocalMediaStream() async {
    return navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'mandatory': {'minWidth': 640, 'minHeight': 480, 'minFrameRate': 15},
        'facingMode': 'user',
        'optional': [],
      },
    });
  }

  Future<void> _setupLocalStream() async {
    if (sharedLocalStream != null) {
      _localStream = sharedLocalStream;
      _ownsLocalStream = false;
      _log('using shared local stream');
      return;
    }
    _log('requesting local media');
    final stream = await createLocalMediaStream();
    _localStream = stream;
    _ownsLocalStream = true;
    _log(
      'local stream ready: audio=${stream.getAudioTracks().length}, video=${stream.getVideoTracks().length}',
    );
  }

  Future<void> _createPeerConnection() async {
    final pc = await createPeerConnection(
      {
        'iceServers': [
          {
            'urls': ['stun:stun.l.google.com:19302'],
          },
        ],
      },
      {
        'mandatory': {},
        'optional': [
          {'DtlsSrtpKeyAgreement': true},
        ],
      },
    );

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty == true) {
        _log('onIceCandidate emitted');
        onIceCandidate(
          candidate.candidate!,
          candidate.sdpMLineIndex ?? 0,
          candidate.sdpMid ?? '',
        );
      }
    };

    pc.onConnectionState = (state) {
      _log('connectionState=$state');
    };

    pc.onIceConnectionState = (state) {
      _log('iceConnectionState=$state');
    };

    pc.onIceGatheringState = (state) {
      _log('iceGatheringState=$state');
    };

    pc.onAddStream = (stream) {
      _log('onAddStream received');
      _remoteStream = stream;
      onRemoteStreamAdded(stream);
    };

    pc.onAddTrack = (stream, track) {
      _log('onAddTrack received: kind=${track.kind}');
      _remoteStream = stream;
      onRemoteStreamAdded(stream);
    };

    if (_localStream != null) {
      final local = _localStream!;
      for (var track in local.getTracks()) {
        await pc.addTrack(track, local);
        _log('local track added: kind=${track.kind}');
      }
    }

    _peerConnection = pc;
  }

  Future<void> createOffer() async {
    if (_peerConnection == null) return;
    _log('createOffer start');
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    _log('createOffer done, sdpLen=${offer.sdp?.length ?? 0}');
    onOfferCreated(offer.sdp ?? '');
  }

  Future<void> setRemoteOffer(String sdp) async {
    if (_peerConnection == null) return;
    final normalized = _normalizeSdp(sdp);
    _log(
      'setRemoteOffer start, sdpLen=${sdp.length}, normalizedLen=${normalized.length}',
    );
    final offer = RTCSessionDescription(normalized, 'offer');
    await _peerConnection!.setRemoteDescription(offer);
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    _log('setRemoteOffer done, answerLen=${answer.sdp?.length ?? 0}');
    onAnswerCreated(answer.sdp ?? '');
  }

  Future<void> setRemoteAnswer(String sdp) async {
    if (_peerConnection == null) return;
    final normalized = _normalizeSdp(sdp);
    _log(
      'setRemoteAnswer start, sdpLen=${sdp.length}, normalizedLen=${normalized.length}',
    );
    final answer = RTCSessionDescription(normalized, 'answer');
    await _peerConnection!.setRemoteDescription(answer);
    _log('setRemoteAnswer done');
  }

  Future<void> addIceCandidate(
    String candidate,
    int sdpMLineIndex,
    String sdpMid,
  ) async {
    if (_peerConnection == null) return;
    _log('addIceCandidate start');
    final cand = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    await _peerConnection!.addCandidate(cand);
    _log('addIceCandidate done');
  }

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  bool get audioEnabled => _audioEnabled;
  bool get videoEnabled => _videoEnabled;

  Future<void> setAudioEnabled(bool enabled) async {
    _audioEnabled = enabled;
    if (_localStream != null) {
      for (var track in _localStream!.getAudioTracks()) {
        track.enabled = enabled;
      }
    }
  }

  Future<void> setVideoEnabled(bool enabled) async {
    _videoEnabled = enabled;
    if (_localStream != null) {
      for (var track in _localStream!.getVideoTracks()) {
        track.enabled = enabled;
      }
    }
  }

  Future<void> dispose() async {
    _log('dispose start');
    if (_localStream != null && _ownsLocalStream) {
      for (var track in _localStream!.getTracks()) {
        await track.stop();
      }
    }
    if (_remoteStream != null) {
      for (var track in _remoteStream!.getTracks()) {
        await track.stop();
      }
    }
    await _peerConnection?.close();
    _localStream = null;
    _remoteStream = null;
    _peerConnection = null;
    _log('dispose done');
  }
}
