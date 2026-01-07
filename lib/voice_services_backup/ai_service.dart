// lib/services/ai_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../agents/agent_manager.dart';

typedef AiUserCallback = void Function(String text);
typedef AiBotCallback = void Function(String text);
typedef AiSpeakingCallback = void Function(bool speaking);
typedef AiStatusCallback = void Function(String text);

// NEW: callback for commands like "millie.sleep"
typedef AiSleepCallback = Future<void> Function();

class AiService {
  static final AiService instance = AiService._internal();
  AiService._internal();

  // ---------------- WebRTC state ----------------

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;

  bool _sessionRunning = false;
  bool _connected = false;

  // ---------------- Callbacks ----------------

  AiUserCallback? onUserText;
  AiBotCallback? onBotText;
  AiSpeakingCallback? onSpeaking;
  AiStatusCallback? onStatus;

  // NEW: optional handler for sleep command
  AiSleepCallback? onSleepCommand;

  String get greeting => AgentManager.instance.greeting;
  Map<String, String> get persona => AgentManager.instance.personaMessage;

  // ------------------------------------------------------
  // Start session (WebRTC)
  // ------------------------------------------------------

  Future<void> startSession() async {
    if (_sessionRunning) return;
    _sessionRunning = true;

    onStatus?.call('[AI] Starting WebRTC session');

    final apiKey = dotenv.env['OPENAI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      _sessionRunning = false;
      throw Exception('OPENAI_API_KEY missing');
    }

    try {
      // 1) Create session and get client_secret
      final clientSecret = await _createRealtimeSession(apiKey);

      // 2) Create WebRTC peer connection
      await _createPeerConnection();

      // 3) Get mic audio and add as track
      await _attachLocalAudio();

      // 4) Create data channel for events
      await _createDataChannel();

      // 5) Create SDP offer and send to OpenAI
      await _negotiateSdpWithOpenAI(clientSecret);

      _connected = true;
      onStatus?.call('[AI] WebRTC session started');
    } catch (e, st) {
      onStatus?.call('[AI] Failed to start WebRTC session: $e');
      print('[AI] Failed to start WebRTC session: $e\n$st');
      _sessionRunning = false;
      await _cleanup();
      rethrow;
    }
  }

  // ------------------------------------------------------
  // Stop session
  // ------------------------------------------------------

  Future<void> stopSession() async {
    if (!_sessionRunning) return;
    _sessionRunning = false;
    _connected = false;

    onStatus?.call('[AI] Stopping WebRTC session');

    await _cleanup();

    onSpeaking?.call(false);
    onStatus?.call('[AI] Session stopped');
  }

  Future<void> _cleanup() async {
    try {
      await _localStream?.dispose();
    } catch (_) {}

    try {
      await _dataChannel?.close();
    } catch (_) {}

    try {
      await _peerConnection?.close();
    } catch (_) {}

    _localStream = null;
    _dataChannel = null;
    _peerConnection = null;
  }

  // ------------------------------------------------------
  // Outbound speech (over data channel)
  // ------------------------------------------------------

  Future<void> speakGreeting() async {
    if (!_sessionRunning || !_connected) return;

    _sendJson({
      'type': 'response.create',
      'response': {'instructions': greeting}
    });
  }

  void speakGoodbye(String text) {
    if (!_sessionRunning || !_connected) return;

    _sendJson({
      'type': 'response.create',
      'response': {'instructions': text}
    });
  }

  // ------------------------------------------------------
  // Realtime Session: create + get client_secret
  // ------------------------------------------------------

  Future<String> _createRealtimeSession(String apiKey) async {
    final url = Uri.parse('https://api.openai.com/v1/realtime/sessions');

    final body = jsonEncode({
      'model': 'gpt-4o-realtime-preview-2024-12-17',
      'voice': 'alloy',
      // We can also pass basic instructions here if desired, but
      // we’ll send a more detailed persona with session.update later.
      // 'instructions': persona['content'],
    });

    final response = await http.post(
      url,
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to create realtime session: '
        '${response.statusCode} ${response.body}',
      );
    }

    final json = jsonDecode(response.body);
    final clientSecret = json['client_secret']?['value'] as String?;
    if (clientSecret == null || clientSecret.isEmpty) {
      throw Exception('Missing client_secret from realtime session response');
    }

    onStatus?.call('[AI] Realtime session created');
    return clientSecret;
  }

  // ------------------------------------------------------
  // WebRTC: create peer connection
  // ------------------------------------------------------

  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });

    if (_peerConnection == null) {
      throw Exception('Failed to create RTCPeerConnection');
    }

    onStatus?.call('[AI] PeerConnection created');

    // When we receive a remote media stream (AI voice)
    _peerConnection!.onAddStream = (MediaStream stream) {
      print('[AI] Received remote media stream');
      final audioTracks = stream.getAudioTracks();
      if (audioTracks.isNotEmpty) {
        print('[AI] Remote audio track received');
        // Route audio to speaker
        Helper.setSpeakerphoneOn(true);
        onSpeaking?.call(true); // optional – will also be controlled via events
      }
    };

    // Log ICE candidates as they are gathered
    _peerConnection!.onIceCandidate = (RTCIceCandidate? candidate) {
      if (candidate == null) return;
      print('[AI] Local ICE candidate: ${candidate.candidate}');
    };

    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      print('[AI] ICE gathering state: $state');
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      print('[AI] onTrack: kind=${event.track.kind}');
      if (event.track.kind == 'audio') {
        Helper.setSpeakerphoneOn(true);
      }
    };
  }

  // ------------------------------------------------------
  // WebRTC: attach local mic audio
  // ------------------------------------------------------

  Future<void> _attachLocalAudio() async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
      'mandatory': {
        'googNoiseSuppression': true,
        'googEchoCancellation': true,
        'googAutoGainControl': true,
      },
      'optional': [
        {'googHighpassFilter': true},
      ],
    });

    if (_localStream == null) {
      throw Exception('Failed to get local audio stream');
    }

    for (var track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    onStatus?.call('[AI] Local mic audio attached');
  }

  // ------------------------------------------------------
  // WebRTC: create data channel for events
  // ------------------------------------------------------

  Future<void> _createDataChannel() async {
    if (_peerConnection == null) {
      throw Exception('PeerConnection not initialized');
    }

    _dataChannel = await _peerConnection!.createDataChannel(
      'oai-events',
      RTCDataChannelInit(),
    );

    if (_dataChannel == null) {
      throw Exception('Failed to create data channel');
    }

    onStatus?.call('[AI] Data channel created');

    _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
      print('[AI] Data channel state: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onStatus?.call('[AI] Data channel open');

        // Send persona / instructions once channel is open
        final instructions = persona['content'];
        if (instructions != null && instructions.isNotEmpty) {
          _sendJson({
            'type': 'session.update',
            'session': {
              'instructions': instructions,
            }
          });
        }
      }
    };

    _dataChannel!.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary) {
        // For WebRTC mode, audio is on the media track, not data channel.
        print(
          '[AI] Data channel binary message (len=${message.binary?.length})',
        );
        return;
      }

      final text = message.text;
      if (text == null || text.isEmpty) return;
      _handleEvent(text);
    };
  }

  // ------------------------------------------------------
  // WebRTC: SDP negotiation with OpenAI
  // ------------------------------------------------------

  Future<void> _negotiateSdpWithOpenAI(String clientSecret) async {
    if (_peerConnection == null) {
      throw Exception('PeerConnection not initialized');
    }

    // Create offer and set as local description.
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    onStatus?.call('[AI] Local SDP offer created (initial)');

    // Wait for ICE gathering to complete
    final gatherCompleter = Completer<void>();

    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      print('[AI] ICE gathering state (negotiate): $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gatherCompleter.isCompleted) {
        gatherCompleter.complete();
      }
    };

    Future.delayed(const Duration(seconds: 5), () {
      if (!gatherCompleter.isCompleted) {
        print('[AI] ICE gathering timeout, continuing with current SDP');
        gatherCompleter.complete();
      }
    });

    await gatherCompleter.future;

    final localDesc = await _peerConnection!.getLocalDescription();
    final localSdp = localDesc?.sdp;
    if (localSdp == null || localSdp.isEmpty) {
      throw Exception('Local SDP is empty after ICE gathering');
    }

    onStatus?.call('[AI] Sending SDP offer to OpenAI (${localSdp.length} chars)');

    final remoteSdp = await _sendSdpToOpenAI(localSdp, clientSecret);
    final remoteDescription = RTCSessionDescription(remoteSdp, 'answer');
    await _peerConnection!.setRemoteDescription(remoteDescription);

    onStatus?.call('[AI] Remote SDP answer set');
  }

  Future<String> _sendSdpToOpenAI(
    String sdp,
    String clientSecret,
  ) async {
    final url = Uri.parse('https://api.openai.com/v1/realtime');

    final client = HttpClient();
    final request = await client.postUrl(url);

    request.headers.set('Authorization', 'Bearer $clientSecret');
    request.headers.set('Content-Type', 'application/sdp');
    request.write(sdp);

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Failed to exchange SDP with OpenAI: '
        '${response.statusCode} $responseBody',
      );
    }

    if (responseBody.isEmpty) {
      throw Exception('Empty SDP answer from OpenAI');
    }

    print('[AI] SDP answer received (${responseBody.length} chars)');
    return responseBody;
  }

  // ------------------------------------------------------
  // Incoming events (over data channel)
  // ------------------------------------------------------

  void _handleEvent(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return;

      final type = data['type'] as String? ?? '';

      switch (type) {
        case 'input_text.delta':
          final t = data['delta'] ?? '';
          if (t is String && t.trim().isNotEmpty) {
            onUserText?.call(t);
          }
          break;

        case 'response.text.delta':
          final t = data['delta'] ?? '';
          if (t is String && t.trim().isNotEmpty) {
            onBotText?.call(t);
          }
          break;

        case 'response.audio.start':
          onSpeaking?.call(true);
          break;

        case 'response.audio.end':
          onSpeaking?.call(false);
          break;

        // For WebRTC, audio bytes are *not* sent over data channel,
        // but we may still receive audio-related events.
        case 'response.audio.delta':
        case 'response.audio':
        case 'response.audio.append':
          break;

        case 'response.completed':
          // Optional: mark that a full response finished.
          break;

        // NEW: custom sleep command from the AI
        case 'millie.sleep':
          onStatus?.call('[AI] Received millie.sleep command');
          if (onSleepCommand != null) {
            // fire and forget; we don't await here
            onSleepCommand!();
          } else {
            onStatus?.call(
              '[AI] millie.sleep received but no onSleepCommand handler is set',
            );
          }
          break;

        case 'error':
          final err = data['error'];
          onStatus?.call('[AI] Error event: $err');
          print('[AI] Error event: $err');
          break;

        default:
          // Optional: log other events for debugging.
          // print('[AI] Event: $type -> $data');
          break;
      }
    } catch (e, st) {
      print('[AI] Error handling event: $e\n$st');
    }
  }

  // ------------------------------------------------------
  // Send JSON over data channel
  // ------------------------------------------------------

  void _sendJson(Map<String, dynamic> obj) {
    if (_dataChannel == null) return;

    try {
      final jsonStr = jsonEncode(obj);
      _dataChannel!.send(RTCDataChannelMessage(jsonStr));
    } catch (e) {
      onStatus?.call('[AI] JSON send error: $e');
      print('[AI] JSON send error: $e');
    }
  }
}
