import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'workflow_tools.dart';
import 'memory_tools.dart';
import 'notes_tools.dart';
import 'audio/assistant_audio_buffer.dart';
import 'audio/continuous_pcm_player.dart';
import 'audio/interruption_controller.dart';

/// Voice states for UI feedback (same as VoicePipelineService)
enum RealtimeVoiceState {
  idle,
  connecting,
  listening,
  processing,
  speaking,
}

/// OpenAI Realtime API voice service
/// Bidirectional streaming: MIC <-> WebSocket <-> OpenAI Realtime API
class RealtimeVoiceService {
  // Cached API key (set from conversation service via robot)
  static String? _cachedApiKey;

  /// Set the API key to use (called from conversation service when received from robot)
  static void setApiKey(String key) {
    _cachedApiKey = key;
    final prefix = key.length > 15 ? '${key.substring(0, 7)}...${key.substring(key.length - 4)}' : '***';
    debugPrint('🔑 [RealtimeVoice] API key set: $prefix');
  }

  /// Get the API key (from robot via rosbridge)
  static String? get apiKey => _cachedApiKey;

  // WebSocket connection
  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;

  // Audio input (microphone)
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioStreamSubscription;

  // Audio output (new architecture)
  final AssistantAudioBuffer _audioBuffer = AssistantAudioBuffer();
  final ContinuousPcmPlayer _player = ContinuousPcmPlayer();
  final InterruptionController _interruptionController = InterruptionController();

  // State
  RealtimeVoiceState _state = RealtimeVoiceState.idle;
  bool _isConnected = false;
  bool _isPaused = false;
  bool _shouldEndConversation = false;
  bool _stopped = true;
  String _currentResponseId = '';
  String _currentItemId = '';
  int _responseCount = 0;

  // Idle timeout - longer to allow natural pauses in conversation
  int _idleTimeoutSeconds = 60;
  Timer? _idleTimer;
  DateTime? _lastUserSpeechTime;

  // Session config
  String _systemPrompt = '';
  String _voice = 'alloy';
  Completer<void>? _sessionUpdateCompleter;

  // Tool handlers
  WorkflowTools? workflowToolsHandler;
  MemoryTools? memoryToolsHandler;
  NotesTools? notesToolsHandler;

  // Callbacks
  void Function(RealtimeVoiceState state)? onStateChange;
  void Function(String text)? onTranscription;
  void Function(String text)? onResponse;
  void Function(String error)? onError;

  // Token usage tracking for activity graph (per-response, not time-based)
  static const int _tokenHistoryLength = 20; // Last 20 API responses
  final List<int> _tokenHistory = List.filled(_tokenHistoryLength, 0);
  int _lastResponseTokens = 0;
  int _sessionTotalTokens = 0;
  final StreamController<List<int>> _tokenHistoryController = StreamController<List<int>>.broadcast();

  /// Stream of token history for UI graph (emits on each response)
  Stream<List<int>> get tokenHistoryStream => _tokenHistoryController.stream;

  /// Current token history snapshot
  List<int> get tokenHistory => List.unmodifiable(_tokenHistory);

  /// Total tokens used this session
  int get sessionTotalTokens => _sessionTotalTokens;

  /// Tokens from the last API response
  int get lastResponseTokens => _lastResponseTokens;

  /// Start token tracking (just ensures stream is ready)
  void startTokenTracking() {
    debugPrint('📊 [RealtimeTokenTracking] Token tracking ready');
  }

  /// Stop token tracking
  void stopTokenTracking() {
    // Nothing to stop - no timer
  }

  /// Reset token tracking for new session
  void resetTokenTracking() {
    _tokenHistory.fillRange(0, _tokenHistoryLength, 0);
    _lastResponseTokens = 0;
    _sessionTotalTokens = 0;
    _tokenHistoryController.add(List.from(_tokenHistory));
  }

  /// Record tokens from an API response
  void _recordTokens(int tokens) {
    // Shift history left, add new response to right
    for (int i = 0; i < _tokenHistoryLength - 1; i++) {
      _tokenHistory[i] = _tokenHistory[i + 1];
    }
    _tokenHistory[_tokenHistoryLength - 1] = tokens;

    _lastResponseTokens = tokens;
    _sessionTotalTokens += tokens;

    debugPrint('📊 [RealtimeTokenTracking] Recorded $tokens tokens (session total: $_sessionTotalTokens)');

    // Notify listeners immediately
    _tokenHistoryController.add(List.from(_tokenHistory));
  }
  void Function(bool speaking)? onSpeaking;
  void Function()? onConversationComplete;
  void Function()? onPauseRequested;

  RealtimeVoiceService() {
    _setupCallbacks();
  }

  bool get isConnected => _isConnected;
  bool get isPaused => _isPaused;
  RealtimeVoiceState get state => _state;

  /// Set the idle timeout (in seconds) before conversation pauses
  void setIdleTimeout(int seconds) {
    _idleTimeoutSeconds = seconds;
    debugPrint('⏱️ [Realtime] Idle timeout set to ${seconds}s');
  }

  void _setupCallbacks() {
    _interruptionController.onStateChange = (state) {
      debugPrint('🎙️ [Realtime] Interruption state: ${state.name}');
    };

    _interruptionController.onInterruptionConfirmed = () {
      debugPrint('🛑 [Realtime] Barge-in CONFIRMED - clearing audio');
      _handleConfirmedInterruption();
    };

    _audioBuffer.onReadyToPlay = () {
      debugPrint('🔊 [Realtime] Buffer ready - starting playback');
      _startPlaybackIfReady();
    };

    _audioBuffer.onUnderrun = () {
      debugPrint('⚠️ [Realtime] Buffer underrun');
    };

    _player.onStateChange = (state) {
      debugPrint('🔊 [Realtime] Player state: ${state.name}');
      if (state == PlaybackState.playing) {
        _interruptionController.markAssistantSpeaking();
      }
    };

    _player.onPlaybackComplete = () {
      debugPrint('🔊 [Realtime] Playback complete');
      _handlePlaybackComplete();
    };

    _player.onError = (error) {
      debugPrint('❌ [Realtime] Player error: $error');
      onError?.call('Audio playback error: $error');
    };
  }

  void injectPrompt(String prompt) {
    if (!_isConnected || _isPaused || _stopped) {
      debugPrint('⚠️ [Realtime] Cannot inject prompt - not active');
      return;
    }

    debugPrint('💬 [Realtime] Injecting prompt: $prompt');

    final createItem = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': '[EVENT: $prompt]'},
        ],
      },
    };
    _sendEvent(createItem);
    _sendEvent({'type': 'response.create'});
  }

  /// Inject context into conversation WITHOUT triggering a vocal response.
  /// Used for adding instructions that the AI should follow silently.
  void injectContext(String context) {
    if (!_isConnected || _isPaused || _stopped) {
      debugPrint('⚠️ [Realtime] Cannot inject context - not active');
      return;
    }

    debugPrint('📋 [Realtime] Injecting context (silent): $context');

    // Add as system message so AI knows these are instructions, not user speech
    final createItem = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': '[INSTRUCTIONS - DO NOT RESPOND TO THIS, JUST REMEMBER: $context]'},
        ],
      },
    };
    _sendEvent(createItem);
    // NOTE: No response.create - context is added silently
  }

  Future<void> startConversation({
    required String systemPrompt,
    String voice = 'alloy',
    String? greeting,
  }) async {
    _systemPrompt = systemPrompt;
    _voice = voice;
    _isPaused = false;
    _shouldEndConversation = false;
    _stopped = false;
    _responseCount = 0;
    _audioChunkCount = 0;

    debugPrint('🎤 [Realtime] Starting conversation with voice: $voice');
    _setState(RealtimeVoiceState.connecting);

    try {
      await _player.initialize();

      debugPrint('🔌 [Realtime] Connecting to WebSocket...');
      await _connect();
      debugPrint('🔌 [Realtime] Connected, configuring session...');

      await _configureSession();
      debugPrint('🔌 [Realtime] Session configured');

      // If greeting provided, add it to conversation history
      // Otherwise, trigger AI to speak first
      if (greeting != null && greeting.isNotEmpty) {
        await _sendGreeting(greeting);
      } else {
        // No greeting - trigger AI to generate first message
        debugPrint('🤖 [Realtime] No greeting - AI will speak first');
        await _triggerAiFirstMessage();
      }

      // Start mic stream (but won't send audio until greeting finishes)
      debugPrint('🎙️ [Realtime] Starting audio stream...');
      await _startAudioStream();
      debugPrint('🎙️ [Realtime] Audio stream started');

      _startIdleTimer();

      _interruptionController.markListening();
      _setState(RealtimeVoiceState.listening);
    } catch (e, stackTrace) {
      debugPrint('❌ [Realtime] Connection error: $e');
      debugPrint('❌ [Realtime] Stack trace: $stackTrace');
      onError?.call('Failed to connect to Realtime API: $e');
      _setState(RealtimeVoiceState.idle);
    }
  }

  Future<void> _connect() async {
    final apiKey = RealtimeVoiceService.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('OpenAI API key not configured');
    }

    await _disconnect();

    final uri = Uri.parse('wss://api.openai.com/v1/realtime?model=gpt-realtime-2');

    _channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $apiKey'},
    );

    await _channel!.ready;
    _isConnected = true;
    debugPrint('✅ [Realtime] WebSocket connected');

    _channelSubscription = _channel!.stream.listen(
      _handleMessage,
      onError: (error) {
        debugPrint('❌ [Realtime] WebSocket error: $error');
        onError?.call('Connection error');
        _handleDisconnect();
      },
      onDone: () {
        debugPrint('👋 [Realtime] WebSocket closed');
        _handleDisconnect();
      },
    );
  }

  Future<void> _configureSession() async {
    final tools = <Map<String, dynamic>>[];

    if (workflowToolsHandler != null) {
      for (final tool in WorkflowTools.toolDefinitions) {
        tools.add(_convertToolForRealtime(tool));
      }
    }

    if (memoryToolsHandler != null) {
      for (final tool in MemoryTools.toolDefinitions) {
        tools.add(_convertToolForRealtime(tool));
      }
    }

    if (notesToolsHandler != null) {
      for (final tool in NotesTools.toolDefinitions) {
        tools.add(_convertToolForRealtime(tool));
      }
    }

    String enhancedPrompt = _systemPrompt;
    if (workflowToolsHandler != null) {
      enhancedPrompt += workflowToolsHandler!.getWorkflowContext();
    }
    if (memoryToolsHandler != null) {
      enhancedPrompt += memoryToolsHandler!.getMemoryContext();
    }
    if (notesToolsHandler != null) {
      enhancedPrompt += notesToolsHandler!.getNotesContext();
    }

    final vadConfig = InterruptionController.getRecommendedVadConfig();

    final sessionConfig = {
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        'model': 'gpt-realtime-2',
        'output_modalities': ['audio'],
        'instructions': enhancedPrompt,
        'audio': {
          'input': {
            'format': {'type': 'audio/pcm', 'rate': 24000},
            'turn_detection': vadConfig,
            'transcription': {'model': 'gpt-4o-mini-transcribe'},
          },
          'output': {
            'format': {'type': 'audio/pcm', 'rate': 24000},
            'voice': _voice,
          },
        },
        if (tools.isNotEmpty) 'tools': tools,
      },
    };

    debugPrint('📝 [Realtime] Sending session config with voice: $_voice');

    _sessionUpdateCompleter = Completer<void>();
    _sendEvent(sessionConfig);

    try {
      await _sessionUpdateCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('⚠️ [Realtime] Session update timeout');
        },
      );
    } catch (e) {
      debugPrint('⚠️ [Realtime] Session update wait error: $e');
    }
    _sessionUpdateCompleter = null;

    debugPrint('📝 [Realtime] Session configured with ${tools.length} tools');
  }

  Map<String, dynamic> _convertToolForRealtime(Map<String, dynamic> chatTool) {
    final function = chatTool['function'] as Map<String, dynamic>;
    return {
      'type': 'function',
      'name': function['name'],
      'description': function['description'],
      'parameters': function['parameters'],
    };
  }

  Future<void> _sendGreeting(String greeting) async {
    // Add greeting to conversation history as context
    // Don't call response.create - that would let OpenAI generate tool calls
    // The greeting was already spoken via turn-taking TTS in startup sequence
    final createItem = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': greeting},
        ],
      },
    };
    _sendEvent(createItem);

    debugPrint('🗣️ [Realtime] Greeting added to history: $greeting');
    onResponse?.call(greeting);
  }

  /// Trigger AI to generate the first message (no user input yet)
  Future<void> _triggerAiFirstMessage() async {
    debugPrint('🤖 [Realtime] Triggering AI first message...');

    // Send response.create to have AI speak first
    final responseCreate = {
      'type': 'response.create',
    };
    _sendEvent(responseCreate);
  }

  Future<void> _startAudioStream() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw Exception('Microphone permission denied');
    }

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 24000,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
    );

    _audioStreamSubscription = stream.listen(
      (data) {
        if (!_isConnected || _isPaused) return;
        // Don't send audio while assistant is speaking - prevents false interruptions
        if (_player.isPlaying) return;
        _sendAudioChunk(data);
      },
      onError: (error) {
        debugPrint('❌ [Realtime] Audio stream error: $error');
      },
    );

    debugPrint('🎤 [Realtime] Audio stream started (24kHz PCM16)');
  }

  int _audioChunkCount = 0;

  void _sendAudioChunk(Uint8List audioData) {
    _audioChunkCount++;
    if (_audioChunkCount % 25 == 1) {
      debugPrint('🎵 [Realtime] Audio chunk #$_audioChunkCount (${audioData.length} bytes)');
    }
    final event = {
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(audioData),
    };
    _sendEvent(event);
  }

  void _handleMessage(dynamic data) {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      final type = message['type'] as String?;

      if (type != 'response.audio.delta' && type != 'response.audio_transcript.delta') {
        debugPrint('📥 [Realtime] Received: $type');
      }

      switch (type) {
        case 'session.created':
          debugPrint('✅ [Realtime] Session created');
          break;

        case 'session.updated':
          if (_sessionUpdateCompleter != null && !_sessionUpdateCompleter!.isCompleted) {
            _sessionUpdateCompleter!.complete();
          }
          break;

        case 'input_audio_buffer.speech_started':
          debugPrint('🎤 [Realtime] User speech started');
          _handleUserSpeechStarted();
          break;

        case 'input_audio_buffer.speech_stopped':
          debugPrint('🎤 [Realtime] User speech stopped');
          _handleUserSpeechStopped();
          break;

        case 'conversation.item.input_audio_transcription.completed':
          final transcript = message['transcript'] as String? ?? '';
          debugPrint('👤 [Realtime] User: $transcript');
          if (transcript.isNotEmpty) {
            // If waiting for a transcription response (Q&A flow), complete it
            if (_transcriptionCompleter != null && !_transcriptionCompleter!.isCompleted) {
              debugPrint('✅ [Realtime] Completing transcription completer: $transcript');
              _transcriptionCompleter!.complete(transcript);
            }
            onTranscription?.call(transcript);
            _checkForPauseCommand(transcript);
          }
          break;

        case 'response.created':
          _responseCount++;
          final responseId = message['response']?['id'] as String? ?? '';
          _currentResponseId = responseId;
          debugPrint('🤖 [Realtime] Response #$_responseCount started: $_currentResponseId');
          _audioBuffer.markResponseStart(responseId);
          _interruptionController.markAssistantBuffering();
          break;

        case 'response.output_item.added':
          final item = message['item'] as Map<String, dynamic>?;
          _currentItemId = item?['id'] as String? ?? '';
          break;

        case 'response.audio.delta':
        case 'response.output_audio.delta':
          final delta = message['delta'] as String? ?? '';
          if (delta.isNotEmpty) {
            _handleAudioDelta(delta);
          }
          break;

        case 'response.audio.done':
        case 'response.output_audio.done':
          debugPrint('🔊 [Realtime] Audio response complete');
          _audioBuffer.markResponseEnd(_currentResponseId);
          break;

        case 'response.audio_transcript.done':
        case 'response.output_audio_transcript.done':
          final transcript = message['transcript'] as String? ?? '';
          debugPrint('🤖 [Realtime] AI: $transcript');
          if (transcript.isNotEmpty) {
            onResponse?.call(transcript);
          }
          break;

        case 'response.function_call_arguments.done':
          _handleFunctionCall(message);
          break;

        case 'response.done':
          debugPrint('✅ [Realtime] Response complete');
          // Extract token usage from response
          final response = message['response'] as Map<String, dynamic>?;
          final usage = response?['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            final totalTokens = (usage['total_tokens'] as int?) ?? 0;
            if (totalTokens > 0) {
              _recordTokens(totalTokens);
            }
          }
          _handleResponseComplete();
          break;

        case 'error':
          final error = message['error'] as Map<String, dynamic>?;
          final errorMsg = error?['message'] as String? ?? 'Unknown error';
          debugPrint('❌ [Realtime] Error: $errorMsg');
          onError?.call(errorMsg);
          break;
      }
    } catch (e) {
      debugPrint('⚠️ [Realtime] Error parsing message: $e');
    }
  }

  void _startIdleTimer() {
    _idleTimer?.cancel();
    _lastUserSpeechTime = DateTime.now();
    _idleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkIdleTimeout();
    });
  }

  void _checkIdleTimeout() {
    if (_lastUserSpeechTime == null || !_isConnected || _isPaused || _stopped) {
      return;
    }
    final secondsSinceLastSpeech = DateTime.now().difference(_lastUserSpeechTime!).inSeconds;
    if (secondsSinceLastSpeech >= _idleTimeoutSeconds) {
      debugPrint('⏱️ [Realtime] Idle timeout - pausing');
      _idleTimer?.cancel();
      pause();
      onPauseRequested?.call();
    }
  }

  void _resetIdleTimer() {
    _lastUserSpeechTime = DateTime.now();
  }

  void _handleUserSpeechStarted() {
    // Ignore speech events while assistant is speaking - prevents false interruptions
    if (_player.isPlaying) {
      debugPrint('🎤 [Realtime] Ignoring speech_started while playing');
      return;
    }
    _resetIdleTimer();
    _setState(RealtimeVoiceState.listening);
    _interruptionController.handleSpeechStarted();
  }

  void _handleUserSpeechStopped() {
    _interruptionController.handleSpeechStopped();
    _setState(RealtimeVoiceState.processing);
  }

  void _handleConfirmedInterruption() {
    _audioBuffer.clear(reason: 'user_interruption');
    _player.handleInterruption();
    onSpeaking?.call(false);

    if (_currentResponseId.isNotEmpty) {
      _sendEvent({'type': 'response.cancel'});
    }

    _setState(RealtimeVoiceState.listening);
  }

  void _handleAudioDelta(String base64Audio) {
    if (_stopped || _isPaused) return;
    if (_interruptionController.isInterruptionConfirmed) return;

    try {
      final audioBytes = base64Decode(base64Audio);
      _audioBuffer.appendChunk(audioBytes, responseId: _currentResponseId);
    } catch (e) {
      debugPrint('⚠️ [Realtime] Audio decode error: $e');
    }
  }

  void _startPlaybackIfReady() {
    if (_stopped || _isPaused) return;
    // Check both playing and starting states to prevent multiple start() calls
    if (_player.isPlaying || _player.state == PlaybackState.starting) return;

    _setState(RealtimeVoiceState.speaking);
    onSpeaking?.call(true);
    _player.start(_audioBuffer);
  }

  void _handlePlaybackComplete() {
    onSpeaking?.call(false);
    _interruptionController.markAssistantDone();

    // Complete speak completer if waiting (for speakAndResume flow)
    if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
      debugPrint('✅ [Realtime] Speak completer completing after playback');
      _speakCompleter!.complete();
      // speakAndResume will handle starting the audio stream
      return;
    }

    if (!_isPaused && !_stopped) {
      _restartAudioStream().then((_) {
        _setState(RealtimeVoiceState.listening);
        debugPrint('🎤 [Realtime] Ready for next input');
      });
    }
  }

  Future<void> _restartAudioStream() async {
    debugPrint('🎙️ [Realtime] Restarting audio stream...');
    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;

    try {
      await _recorder.stop();
    } catch (e) {
      // May already be stopped
    }

    _audioChunkCount = 0;
    await _startAudioStream();
  }

  Future<void> _handleFunctionCall(Map<String, dynamic> message) async {
    final callId = message['call_id'] as String? ?? '';
    final name = message['name'] as String? ?? '';
    final argumentsStr = message['arguments'] as String? ?? '{}';

    debugPrint('🔧 [Realtime] Function call: $name');

    Map<String, dynamic> arguments;
    try {
      arguments = jsonDecode(argumentsStr) as Map<String, dynamic>;
    } catch (e) {
      arguments = {};
    }

    final toolCall = ToolCall(id: callId, name: name, arguments: arguments);

    ToolResult result;
    const memoryTools = {
      'add_owner_note', 'remember_person', 'add_memory_note',
      'recall_memories', 'get_owner_info'
    };
    const notesTools = {
      'create_note', 'list_notes', 'search_notes', 'open_note', 'get_note', 'delete_note',
      'create_alert', 'list_alerts', 'delete_alert', 'update_alert'
    };

    if (memoryTools.contains(name) && memoryToolsHandler != null) {
      result = await memoryToolsHandler!.executeTool(toolCall);
    } else if (notesTools.contains(name) && notesToolsHandler != null) {
      result = await notesToolsHandler!.executeTool(toolCall);
    } else if (workflowToolsHandler != null) {
      result = await workflowToolsHandler!.executeTool(toolCall);
    } else {
      result = ToolResult(success: false, message: 'No handler for: $name');
    }

    debugPrint('🔧 [Realtime] Tool $name: ${result.success ? "success" : "failed"}');
    _sendFunctionResult(callId, _currentItemId, result);
  }

  void _sendFunctionResult(String callId, String itemId, ToolResult result) {
    final outputEvent = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'function_call_output',
        'call_id': callId,
        'output': jsonEncode(result.toJson()),
      },
    };
    _sendEvent(outputEvent);
    _sendEvent({'type': 'response.create'});
  }

  void _handleResponseComplete() {
    _currentResponseId = '';
    _currentItemId = '';

    if (_shouldEndConversation) {
      debugPrint('🏁 [Realtime] Ending conversation');
      _shouldEndConversation = false;
      onConversationComplete?.call();
      stopConversation();
    }

    // Fallback: if speak completer is waiting but playback didn't start,
    // complete it after a brief delay to allow any pending audio to finish
    if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
          debugPrint('⚠️ [Realtime] Speak completer fallback completion');
          _speakCompleter!.complete();
        }
      });
    }
  }

  void _checkForPauseCommand(String text) {
    final words = text.toLowerCase().replaceAll(RegExp(r'[.,!?]'), '').split(RegExp(r'\s+'));
    if (words.contains('pause')) {
      debugPrint('⏸️ [Realtime] Pause command detected');
      pause();
      onPauseRequested?.call();
    }
  }

  void pause() {
    _isPaused = true;
    _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;
    _recorder.stop();
    _audioBuffer.clear(reason: 'pause');
    _player.stop();
    onSpeaking?.call(false);
    _interruptionController.markIdle();
    debugPrint('⏸️ [Realtime] Conversation paused');
  }

  Future<void> resume() async {
    _isPaused = false;
    _stopped = false;

    if (!_isConnected) {
      debugPrint('⚠️ [Realtime] Not connected - reconnecting...');
      // Reconnect with stored settings
      try {
        await _player.initialize();
        await _connect();
        await _configureSession();
        await _startAudioStream();
        debugPrint('🔄 [Realtime] Reconnected and resumed');
      } catch (e) {
        debugPrint('❌ [Realtime] Failed to reconnect: $e');
        onError?.call('Failed to reconnect: $e');
        return;
      }
    } else {
      await _startAudioStream();
      debugPrint('▶️ [Realtime] Conversation resumed');
    }

    _startIdleTimer();
    _interruptionController.markListening();
    _setState(RealtimeVoiceState.listening);
  }

  /// Trigger AI to generate a response (for resume, etc.)
  void triggerResponse() {
    if (_isConnected) {
      _triggerAiFirstMessage();
    }
  }

  // Completer for waiting on speech to finish
  Completer<void>? _speakCompleter;

  // Completer for waiting on user transcription (for Q&A flow)
  Completer<String>? _transcriptionCompleter;

  /// Speak a message and then resume listening (for task arrivals)
  /// Returns when speaking is complete
  Future<void> speakAndResume(String message) async {
    debugPrint('💬 [Realtime] Speaking and resuming: $message');

    _isPaused = false;
    _stopped = false;

    // Reconnect if needed
    if (!_isConnected) {
      try {
        await _player.initialize();
        await _connect();
        await _configureSession();
      } catch (e) {
        debugPrint('❌ [Realtime] Failed to reconnect: $e');
        onError?.call('Failed to reconnect: $e');
        return;
      }
    }

    // Create completer to wait for playback to complete
    _speakCompleter = Completer<void>();

    // Inject a user message instructing the AI to speak the exact message
    // This is more reliable than adding an assistant message and calling response.create
    final createItem = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': '[TASK DELIVERY: Say this exactly to the person: "$message"]'},
        ],
      },
    };
    _sendEvent(createItem);

    // Request AI to generate audio response
    _sendEvent({'type': 'response.create'});

    // Notify UI
    onResponse?.call(message);

    // Wait for speaking to complete (playback done)
    try {
      await _speakCompleter!.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint('⚠️ [Realtime] Speak timeout: $e');
    }
    _speakCompleter = null;

    // Start listening after speaking completes
    await _startAudioStream();
    _startIdleTimer();
    _interruptionController.markListening();
    _setState(RealtimeVoiceState.listening);
  }

  /// Ask a question and wait for the user's spoken response
  /// Returns the transcribed response text
  Future<String> askQuestionAndGetResponse(String question, {int timeoutSeconds = 15}) async {
    debugPrint('❓ [Realtime] Asking question: $question');

    _isPaused = false;
    _stopped = false;

    // Reconnect if needed
    if (!_isConnected) {
      try {
        await _player.initialize();
        await _connect();
        await _configureSession();
      } catch (e) {
        debugPrint('❌ [Realtime] Failed to reconnect: $e');
        onError?.call('Failed to reconnect: $e');
        return '';
      }
    }

    // Create completer to wait for speech to finish
    _speakCompleter = Completer<void>();

    // Inject a user message instructing the AI to ask the question naturally
    final createItem = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': '[CONFIRMATION: Ask this question and wait for their answer: "$question"]'},
        ],
      },
    };
    _sendEvent(createItem);

    // Request AI to generate audio response
    _sendEvent({'type': 'response.create'});

    // Notify UI
    onResponse?.call(question);

    // Wait for speaking to complete
    try {
      await _speakCompleter!.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint('⚠️ [Realtime] Question speak timeout: $e');
    }
    _speakCompleter = null;

    // Now set up to listen for the user's response
    _transcriptionCompleter = Completer<String>();

    // Start listening
    await _startAudioStream();
    _interruptionController.markListening();
    _setState(RealtimeVoiceState.listening);

    // Wait for transcription
    String response = '';
    try {
      response = await _transcriptionCompleter!.future.timeout(Duration(seconds: timeoutSeconds));
      debugPrint('✅ [Realtime] Got response: $response');
    } catch (e) {
      debugPrint('⚠️ [Realtime] Response timeout: $e');
    }
    _transcriptionCompleter = null;

    return response;
  }

  Future<void> stopConversation() async {
    debugPrint('🛑 [Realtime] Stopping conversation');

    _idleTimer?.cancel();
    _idleTimer = null;
    _stopped = true;
    _isPaused = false;
    _shouldEndConversation = false;

    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;
    await _recorder.stop();

    _audioBuffer.clear(reason: 'stop_conversation');
    await _player.stop();

    await _disconnect();

    workflowToolsHandler?.clear();

    _interruptionController.markIdle();
    _setState(RealtimeVoiceState.idle);
    onSpeaking?.call(false);
  }

  Future<void> _disconnect() async {
    _isConnected = false;
    await _channelSubscription?.cancel();
    _channelSubscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void _handleDisconnect() {
    _isConnected = false;
    _interruptionController.markError();
    _setState(RealtimeVoiceState.idle);
    onSpeaking?.call(false);
  }

  void _sendEvent(Map<String, dynamic> event) {
    if (_channel != null && _isConnected) {
      final eventType = event['type'] as String?;
      if (eventType != 'input_audio_buffer.append') {
        debugPrint('📤 [Realtime] Sending: $eventType');
      }
      _channel!.sink.add(jsonEncode(event));
    } else {
      debugPrint('⚠️ [Realtime] Cannot send - not connected');
    }
  }

  void _setState(RealtimeVoiceState newState) {
    _state = newState;
    onStateChange?.call(newState);
    debugPrint('📍 [Realtime] State: ${newState.name}');
  }

  Future<void> dispose() async {
    await stopConversation();
    stopTokenTracking();
    await _tokenHistoryController.close();
    _recorder.dispose();
    await _player.dispose();
    _interruptionController.dispose();
  }
}
