import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'workflow_tools.dart';
import 'memory_tools.dart';
import 'notes_tools.dart';

/// Voice states for UI feedback
enum VoiceState {
  idle,
  listening,
  processing,
  speaking,
}

/// LLM Response with optional tool calls
class LLMResponse {
  final String? content;
  final List<ToolCall>? toolCalls;
  final int totalTokens;
  
  LLMResponse({
    this.content,
    this.toolCalls,
    this.totalTokens = 0,
  });
  
  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
}

/// Voice Pipeline Service for millie_ai
/// Implements: MIC → VAD → STT → LLM (with tools) → TTS → PLAY
class VoicePipelineService {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  // Cached API key (set from conversation service via robot)
  static String? _cachedApiKey;

  /// Set the API key to use (called from conversation service when received from robot)
  static void setApiKey(String key) {
    _cachedApiKey = key;
    final prefix = key.length > 15 ? '${key.substring(0, 7)}...${key.substring(key.length - 4)}' : '***';
    debugPrint('🔑 [VoicePipeline] API key set: $prefix');
  }

  /// Get the API key (from robot via rosbridge)
  static String? get apiKey => _cachedApiKey;
  
  // State
  bool _isRecording = false;
  bool _isProcessing = false;
  bool _isPlaying = false;
  bool _isContinuousMode = false;
  bool _isPaused = false;
  bool _isStopping = false;
  bool _shouldEndConversation = false;  // Currently unused - conversations don't auto-end
  bool _stopped = true;  // Hard stop flag - prevents any audio when true
  
  // VAD (Voice Activity Detection) parameters
  StreamSubscription? _amplitudeSubscription;
  Timer? _silenceTimer;
  Timer? _maxRecordingTimer;
  DateTime? _lastSpeechTime;
  DateTime? _speechStartTime;  // When speech first started
  bool _hasDetectedSpeech = false;
  String? _currentRecordingPath;

  // Idle timeout - pause if no user speech for this long
  Timer? _idleTimer;
  DateTime? _lastUserSpeechTime;
  int _idleTimeoutSeconds = 3600;  // 1 hour - effectively always listening

  static const Duration _silenceThreshold = Duration(milliseconds: 1500);  // Stop after 1.5s silence
  static const Duration _maxRecordingDuration = Duration(seconds: 30);     // Max recording time
  static const Duration _minSpeechDuration = Duration(milliseconds: 300);  // Min speech before processing
  static const double _speechAmplitudeThreshold = -20.0;  // dB threshold for speech (raised from -25)
  
  // Conversation history
  final List<Map<String, String>> _conversationHistory = [];
  
  // System prompt and voice
  String _systemPrompt = '';
  String _voice = 'alloy';
  
  // Tool handlers
  WorkflowTools? workflowToolsHandler;
  MemoryTools? memoryToolsHandler;
  NotesTools? notesToolsHandler;
  
  // Callbacks
  void Function(VoiceState state)? onStateChange;
  void Function(String text)? onTranscription;  // User's speech
  void Function(String text)? onResponse;        // AI's response

  // Flag to skip AI processing (set by callback when it handles the input directly)
  bool skipNextAIResponse = false;
  void Function(String error)? onError;
  void Function(bool speaking)? onSpeaking;
  void Function()? onConversationComplete;       // Called when conversation ends
  void Function()? onPauseRequested;             // Called when user says "pause"

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
    debugPrint('📊 [TokenTracking] Token tracking ready');
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

    debugPrint('📊 [TokenTracking] Recorded $tokens tokens (session total: $_sessionTotalTokens)');

    // Notify listeners immediately
    _tokenHistoryController.add(List.from(_tokenHistory));
  }

  VoicePipelineService();
  
  bool get isRecording => _isRecording;
  bool get isPlaying => _isPlaying;
  bool get isPaused => _isPaused;
  bool get isContinuousMode => _isContinuousMode;

  /// Set the idle timeout (in seconds) before conversation pauses
  void setIdleTimeout(int seconds) {
    _idleTimeoutSeconds = seconds;
    debugPrint('⏱️ [TurnTaking] Idle timeout set to ${seconds}s');
  }
  
  /// Start a conversation with the given system prompt
  Future<void> startConversation({
    required String systemPrompt,
    String voice = 'alloy',
    String? greeting,
  }) async {
    _systemPrompt = systemPrompt;
    _voice = voice;
    _conversationHistory.clear();
    _isPaused = false;
    _isContinuousMode = true;
    _shouldEndConversation = false;
    _stopped = false;  // Allow audio

    // Start idle timer
    _startIdleTimer();

    debugPrint('🎤 Starting conversation');

    // Speak greeting if provided, otherwise just start listening
    if (greeting != null && greeting.isNotEmpty) {
      await _speakText(greeting);
      _conversationHistory.add({'role': 'assistant', 'content': greeting});
    }

    // Start listening
    await startListening();
  }

  /// Generate AI's first message when no greeting is provided
  Future<void> _generateAiFirstMessage() async {
    onStateChange?.call(VoiceState.processing);

    try {
      // Call LLM with empty user message to let AI speak first
      final response = await _callLLM('');
      final content = response?.content;
      if (content != null && content.isNotEmpty && !_stopped) {
        _conversationHistory.add({'role': 'assistant', 'content': content});
        await _speakText(content);
      }
    } catch (e) {
      debugPrint('❌ Error generating first message: $e');
    }
  }
  
  /// Speak text only (no listening after) - for delivery mode
  Future<void> speakOnly({
    required String text,
    String voice = 'alloy',
  }) async {
    _voice = voice;
    _isPaused = false;
    _isContinuousMode = false;  // Don't start continuous listening
    _stopped = false;  // Allow audio

    debugPrint('🔊 Speaking only (delivery mode): $text');
    await _speakText(text);
  }

  /// Deliver an alert message, then start listening for response
  /// Used for reminder/alert delivery - speaks the alert, adds to conversation history,
  /// then automatically starts listening so user can respond
  Future<void> deliverAlertAndListen({
    required String alertMessage,
    required String alertContext,
    String voice = 'alloy',
  }) async {
    debugPrint('🔔 [VoicePipeline] deliverAlertAndListen called');
    debugPrint('🔔 [VoicePipeline] API key set: ${VoicePipelineService.apiKey != null}');

    _voice = voice;
    _conversationHistory.clear();
    _isPaused = false;
    _isContinuousMode = true;
    _shouldEndConversation = false;
    _stopped = false;

    // Start idle timer
    _startIdleTimer();

    debugPrint('🔔 Delivering alert: $alertMessage');

    // Add system context about the alert
    _conversationHistory.add({
      'role': 'system',
      'content': 'You just delivered an alert to the user: "$alertContext". The user may respond or ask follow-up questions about this reminder.',
    });

    // Add the alert as assistant message (what we spoke)
    _conversationHistory.add({'role': 'assistant', 'content': alertMessage});

    // Speak the alert
    debugPrint('🔔 [VoicePipeline] About to speak alert text');
    await _speakText(alertMessage);
    debugPrint('🔔 [VoicePipeline] Finished speaking alert');

    // Start listening for user response
    await startListening();
  }

  /// Listen once and return the transcription (for confirmation flows)
  Future<String> listenOnce() async {
    final completer = Completer<String>();

    // Brief pause to ensure audio buffers are flushed
    await Future.delayed(const Duration(milliseconds: 1200));

    // Store original callback
    final originalOnTranscription = onTranscription;

    // Set up one-time transcription callback
    onTranscription = (text) {
      if (!completer.isCompleted) {
        completer.complete(text);
      }
      // Restore original callback
      onTranscription = originalOnTranscription;
    };

    // Start listening (non-continuous mode)
    _isContinuousMode = false;
    await startListening();

    // Wait for transcription with timeout
    try {
      final result = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('⏱️ listenOnce timed out');
          stopListening();
          onTranscription = originalOnTranscription;
          return '';
        },
      );
      return result;
    } catch (e) {
      debugPrint('❌ listenOnce error: $e');
      onTranscription = originalOnTranscription;
      return '';
    }
  }

  /// Start listening for audio with VAD
  Future<void> startListening() async {
    if (_isRecording || _isProcessing || _isPlaying || _isStopping) {
      debugPrint('Cannot start listening: busy (recording=$_isRecording, processing=$_isProcessing, playing=$_isPlaying, stopping=$_isStopping)');
      // Force reset if stuck
      if (!_isRecording && !_isProcessing) {
        debugPrint('🔧 Force resetting stuck flags');
        _isPlaying = false;
        _isStopping = false;
      } else {
        return;
      }
    }
    
    if (_isPaused) {
      debugPrint('Cannot start listening: paused');
      return;
    }
    
    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        onError?.call('Microphone permission denied');
        return;
      }
      
      // Emit listening state immediately (like millie_mini) for faster UI update
      onStateChange?.call(VoiceState.listening);
      
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
      _currentRecordingPath = path;
      
      // Use WAV at 16kHz like millie_mini - optimal for Whisper, smaller files
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      
      _isRecording = true;
      _isStopping = false;
      debugPrint('🎤 Listening...');
      
      // Start VAD monitoring
      _startVADMonitoring(path);
      
    } catch (e) {
      debugPrint('Error starting recording: $e');
      onError?.call('Failed to start recording');
    }
  }
  
  /// Start VAD monitoring to auto-stop after silence
  void _startVADMonitoring(String recordingPath) {
    _hasDetectedSpeech = false;
    _lastSpeechTime = DateTime.now();
    _speechStartTime = null;
    
    // Max recording timer (safety fallback)
    _maxRecordingTimer = Timer(_maxRecordingDuration, () {
      if (_isRecording && !_isStopping) {
        debugPrint('🎤 Max recording duration reached - stopping');
        _stopAndProcess(recordingPath);
      }
    });
    
    // Monitor amplitude for speech detection
    _amplitudeSubscription = Stream.periodic(
      const Duration(milliseconds: 200),
    ).asyncMap((_) async {
      if (!_isRecording || _isPaused) return null;
      try {
        return await _recorder.getAmplitude();
      } catch (e) {
        return null;
      }
    }).listen((amplitude) {
      if (amplitude == null || !_isRecording || _isPaused) return;
      
      if (amplitude.current > _speechAmplitudeThreshold) {
        // Speech detected
        if (!_hasDetectedSpeech) {
          _speechStartTime = DateTime.now();
          _hasDetectedSpeech = true;
          debugPrint('🎤 Speech detected (${amplitude.current.toStringAsFixed(1)} dB)');
        }
        _lastSpeechTime = DateTime.now();
      }
    });
    
    // Monitor for silence after speech
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!_isRecording || !_isContinuousMode || _isPaused) {
        timer.cancel();
        return;
      }
      
      if (_hasDetectedSpeech && _lastSpeechTime != null && _speechStartTime != null) {
        final silenceDuration = DateTime.now().difference(_lastSpeechTime!);
        final speechDuration = _lastSpeechTime!.difference(_speechStartTime!);

        if (silenceDuration >= _silenceThreshold) {
          timer.cancel();
          _amplitudeSubscription?.cancel();
          _maxRecordingTimer?.cancel();

          // Only process if speech was long enough (not just a noise spike)
          if (speechDuration >= _minSpeechDuration) {
            debugPrint('🎤 Silence detected (${silenceDuration.inMilliseconds}ms) after ${speechDuration.inMilliseconds}ms speech - processing');
            if (_isRecording && !_isStopping) {
              _stopAndProcess(recordingPath);
            }
          } else {
            debugPrint('🎤 Too short (${speechDuration.inMilliseconds}ms) - discarding');
            // Restart listening without processing
            if (_isRecording && !_isStopping && _isContinuousMode) {
              _hasDetectedSpeech = false;
              _speechStartTime = null;
              _startVADMonitoring(recordingPath);
            }
          }
        }
      }
    });
  }
  
  /// Stop recording and process
  Future<void> _stopAndProcess(String recordingPath) async {
    if (_isStopping) return;
    _isStopping = true;
    
    try {
      await _recorder.stop();
      _isRecording = false;
      
      if (_isContinuousMode && !_isPaused) {
        await _processRecording(recordingPath);
      }
    } catch (e) {
      debugPrint('Error stopping recording: $e');
    } finally {
      _isStopping = false;
    }
  }
  
  /// Stop listening and process the audio (manual stop)
  Future<void> stopListening() async {
    if (!_isRecording || _isStopping) return;
    
    // Cancel VAD monitoring
    _amplitudeSubscription?.cancel();
    _silenceTimer?.cancel();
    _maxRecordingTimer?.cancel();
    
    if (_currentRecordingPath != null) {
      await _stopAndProcess(_currentRecordingPath!);
    }
  }
  
  /// Process a recording through the pipeline
  Future<void> _processRecording(String recordingPath) async {
    if (_isProcessing) return;
    _isProcessing = true;
    onStateChange?.call(VoiceState.processing);
    
    try {
      // Step 1: STT (Speech to Text)
      final transcription = await _speechToText(recordingPath);
      
      // Filter out empty or very short transcripts (likely noise)
      if (transcription == null || transcription.trim().length < 2) {
        debugPrint('🎤 No valid speech (empty or too short)');
        _isProcessing = false;
        if (_isContinuousMode && !_isPaused) {
          await startListening();
        }
        return;
      }
      
      debugPrint('👤 User: $transcription');
      onTranscription?.call(transcription);

      // Check if callback handled this (e.g., search command)
      if (skipNextAIResponse) {
        skipNextAIResponse = false;
        _isProcessing = false;
        if (_isContinuousMode && !_isPaused) {
          await startListening();
        }
        return;
      }

      // Reset idle timer - user is active
      _resetIdleTimer();

      // Check for pause command
      if (_isPauseCommand(transcription)) {
        debugPrint('⏸️ Pause command detected');
        pause();
        onPauseRequested?.call();
        _isProcessing = false;
        return;
      }
      
      // Add to conversation history
      _conversationHistory.add({'role': 'user', 'content': transcription});
      
      // Step 2: LLM with tools
      final response = await _callLLM(transcription);

      if (response == null || (response.content == null && !response.hasToolCalls)) {
        onError?.call('Failed to get AI response');
        _isProcessing = false;
        if (_isContinuousMode && !_isPaused) {
          await startListening();
        }
        return;
      }

      // Record token usage for activity graph
      if (response.totalTokens > 0) {
        _recordTokens(response.totalTokens);
      }

      // Handle tool calls if any
      String? aiResponse = response.content;
      bool shouldEndAfterSpeaking = false;
      if (response.hasToolCalls && workflowToolsHandler != null) {
        aiResponse = await _handleToolCalls(response, transcription);
        // Check if conversation was stopped during tool handling
        if (!_isContinuousMode) {
          debugPrint('🛑 Conversation will end after speaking response');
          shouldEndAfterSpeaking = true;
        }
      }
      
      if (aiResponse != null && aiResponse.isNotEmpty) {
        debugPrint('🤖 AI: $aiResponse');
        onResponse?.call(aiResponse);
        
        // Add to history
        _conversationHistory.add({'role': 'assistant', 'content': aiResponse});
        
        // Step 3: TTS and play
        await _speakText(aiResponse);
      }
      
      _isProcessing = false;
      
      // Check if conversation should end
      if (_shouldEndConversation || shouldEndAfterSpeaking) {
        debugPrint('🏁 Ending conversation');
        _shouldEndConversation = false;
        // Don't call stopConversation again - it was already called
        onConversationComplete?.call();
        return;
      }
      
      // Resume listening if in continuous mode
      if (_isContinuousMode && !_isPaused) {
        await startListening();
      }
      
    } catch (e) {
      debugPrint('Pipeline error: $e');
      onError?.call('An error occurred');
      _isProcessing = false;
      
      if (_isContinuousMode && !_isPaused) {
        await startListening();
      }
    }
  }
  
  /// Speech to Text via Whisper API
  Future<String?> _speechToText(String audioPath) async {
    final apiKey = VoicePipelineService.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('❌ [VoicePipeline] STT failed - API key not set');
      return null;
    }
    
    try {
      final file = File(audioPath);
      if (!await file.exists()) return null;
      
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
      );
      
      request.headers['Authorization'] = 'Bearer $apiKey';
      request.fields['model'] = 'whisper-1';
      request.fields['language'] = 'en';
      request.files.add(await http.MultipartFile.fromPath('file', audioPath));
      
      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      
      if (response.statusCode == 200) {
        final json = jsonDecode(responseBody);
        return json['text'] as String?;
      } else {
        debugPrint('STT error: $responseBody');
        return null;
      }
    } catch (e) {
      debugPrint('STT error: $e');
      return null;
    }
  }
  
  /// Call LLM with function calling support
  Future<LLMResponse?> _callLLM(String userMessage) async {
    final apiKey = VoicePipelineService.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('❌ [VoicePipeline] LLM call failed - API key not set');
      return null;
    }
    
    try {
      // Build system prompt with context from handlers
      String enhancedPrompt = _systemPrompt;
      if (workflowToolsHandler != null) {
        enhancedPrompt += workflowToolsHandler!.getWorkflowContext();
      }
      
      // Build messages
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': enhancedPrompt},
        ..._conversationHistory,
      ];
      
      // Build request body
      final body = <String, dynamic>{
        'model': 'gpt-4o-mini',
        'messages': messages,
      };
      
      // Combine tools from all available handlers
      final allTools = <Map<String, dynamic>>[];
      if (workflowToolsHandler != null) {
        allTools.addAll(WorkflowTools.toolDefinitions);
      }
      if (memoryToolsHandler != null) {
        allTools.addAll(MemoryTools.toolDefinitions);
      }
      if (notesToolsHandler != null) {
        allTools.addAll(NotesTools.toolDefinitions);
      }
      
      // Add tools if any handlers are available
      if (allTools.isNotEmpty) {
        body['tools'] = allTools;
        body['tool_choice'] = 'auto';
      }
      
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final choice = json['choices'][0];
        final message = choice['message'];
        final usage = json['usage'];
        
        // Check for tool calls
        List<ToolCall>? toolCalls;
        if (message['tool_calls'] != null) {
          toolCalls = (message['tool_calls'] as List<dynamic>)
              .map<ToolCall>((tc) => ToolCall.fromJson(tc as Map<String, dynamic>))
              .toList();
        }
        
        return LLMResponse(
          content: message['content'] as String?,
          toolCalls: toolCalls,
          totalTokens: usage?['total_tokens'] ?? 0,
        );
      } else {
        debugPrint('LLM error: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('LLM error: $e');
      return null;
    }
  }
  
  /// Handle tool calls from the LLM
  Future<String?> _handleToolCalls(LLMResponse response, String userMessage) async {
    if (!response.hasToolCalls) {
      return response.content;
    }
    
    // Check if we have any handlers
    if (workflowToolsHandler == null && memoryToolsHandler == null) {
      return response.content;
    }

    debugPrint('Handling ${response.toolCalls!.length} tool call(s)');

    // Tool name sets for routing
    const memoryTools = {'add_owner_note', 'remember_person', 'add_memory_note', 'recall_memories', 'get_owner_info'};
    const notesTools = {
      'create_note', 'list_notes', 'search_notes', 'open_note', 'get_note', 'delete_note',
      'create_alert', 'list_alerts', 'delete_alert', 'update_alert'
    };

    // Execute each tool
    final toolResults = <Map<String, dynamic>>[];
    for (final toolCall in response.toolCalls!) {
      ToolResult result;

      // Route to appropriate handler
      if (memoryTools.contains(toolCall.name) && memoryToolsHandler != null) {
        result = await memoryToolsHandler!.executeTool(toolCall);
      } else if (notesTools.contains(toolCall.name) && notesToolsHandler != null) {
        result = await notesToolsHandler!.executeTool(toolCall);
      } else if (workflowToolsHandler != null) {
        result = await workflowToolsHandler!.executeTool(toolCall);
      } else {
        result = ToolResult(success: false, message: 'No handler for tool: ${toolCall.name}');
      }

      toolResults.add({
        'tool_call_id': toolCall.id,
        'role': 'tool',
        'content': jsonEncode(result.toJson()),
      });
      debugPrint('Tool ${toolCall.name}: ${result.success ? "success" : "failed"}');
    }
    
    // Get follow-up response from LLM
    final apiKey = VoicePipelineService.apiKey;
    if (apiKey == null || apiKey.isEmpty) return response.content;
    
    try {
      String enhancedPrompt = _systemPrompt;
      if (workflowToolsHandler != null) {
        enhancedPrompt += workflowToolsHandler!.getWorkflowContext();
      }
      
      // Build messages with tool results
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': enhancedPrompt},
        ..._conversationHistory,
        {
          'role': 'assistant',
          'tool_calls': response.toolCalls!.map((tc) => {
            'id': tc.id,
            'type': 'function',
            'function': {'name': tc.name, 'arguments': jsonEncode(tc.arguments)},
          }).toList(),
        },
        ...toolResults,
      ];
      
      final followUpResponse = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'gpt-4o-mini',
          'messages': messages,
        }),
      );
      
      if (followUpResponse.statusCode == 200) {
        final json = jsonDecode(followUpResponse.body);
        return json['choices'][0]['message']['content'] as String?;
      }
    } catch (e) {
      debugPrint('Follow-up LLM error: $e');
    }
    
    return response.content;
  }
  
  /// Public method to speak text (for remote commands)
  Future<void> speakText(String text) => _speakText(text);

  /// Inject a prompt and get AI to respond (for search events, etc.)
  Future<void> injectPrompt(String prompt) async {
    if (_stopped || _isPaused) return;

    debugPrint('💉 Injecting prompt: $prompt');

    // Add as system instruction
    _conversationHistory.add({'role': 'user', 'content': '[System: $prompt]'});

    // Get AI response
    final response = await _callLLM(prompt);
    if (response?.content != null && response!.content!.isNotEmpty) {
      onResponse?.call(response.content!);
      _conversationHistory.add({'role': 'assistant', 'content': response.content!});
      await _speakText(response.content!);
    }

    // Resume listening if in continuous mode
    if (_isContinuousMode && !_isPaused) {
      await startListening();
    }
  }

  /// Text to Speech and play (like millie_mini pattern)
  Future<void> _speakText(String text) async {
    debugPrint('🔊 TTS: _speakText called with ${text.length} chars');
    if (text.isEmpty) {
      debugPrint('🔊 TTS: Aborted - empty text');
      return;
    }
    if (_stopped) {
      debugPrint('🔊 TTS: Aborted - conversation stopped');
      return;
    }

    final apiKey = VoicePipelineService.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('🔊 TTS: Aborted - API key not set');
      return;
    }

    onStateChange?.call(VoiceState.speaking);
    _idleTimer?.cancel(); // Stop idle timer while speaking
    onSpeaking?.call(true);
    _isPlaying = true;
    debugPrint('🔊 TTS: Starting...');

    try {
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/audio/speech'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'tts-1',
          'voice': _voice,
          'input': text,
        }),
      );

      // Check again after HTTP request - might have been stopped while waiting
      if (_stopped) {
        debugPrint('🔊 TTS: Aborted after request - conversation stopped');
        _isPlaying = false;
        onSpeaking?.call(false);
        return;
      }

      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
        await file.writeAsBytes(response.bodyBytes);

        // Stop any previous playback
        try { await _player.stop(); } catch (_) {}
        
        // Use Completer pattern like millie_mini for reliable completion detection
        final completer = Completer<void>();
        StreamSubscription<PlayerState>? subscription;
        
        subscription = _player.playerStateStream.listen((state) {
          // Complete on either: finished playing OR stopped (e.g., paused)
          if (state.processingState == ProcessingState.completed ||
              state.processingState == ProcessingState.idle) {
            if (!completer.isCompleted) {
              completer.complete();
              subscription?.cancel();
            }
          }
        });
        
        await _player.setFilePath(file.path);
        await _player.play();
        
        // Wait for completion with timeout
        await completer.future.timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            subscription?.cancel();
          },
        );
        
        debugPrint('🔊 TTS: Done');
      } else {
        debugPrint('🔊 TTS: API error ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('🔊 TTS error: $e');
    } finally {
      // Reset state (may already be false if paused)
      _isPlaying = false;
      // Only notify if not already paused (pause() already called onSpeaking(false))
      if (!_isPaused) {
        onSpeaking?.call(false);
        _startIdleTimer(); // Restart idle timer now that we're done speaking
      }
    }
  }
  
  /// Check if transcription is a pause command
  /// Only triggers on the word "pause" - simple and unique
  bool _isPauseCommand(String text) {
    // Normalize: lowercase, trim, and remove common punctuation
    final normalized = text.toLowerCase().trim();
    final cleaned = normalized.replaceAll(RegExp(r'[.,!?]'), '').trim();
    
    // Split into words and check for "pause"
    final words = cleaned.split(RegExp(r'\s+'));
    
    if (words.contains('pause')) {
      debugPrint('✅ Pause command detected: "$text"');
      return true;
    }
    
    return false;
  }

  /// Start idle timer - pauses conversation if no user speech for timeout period
  void _startIdleTimer() {
    _lastUserSpeechTime = DateTime.now();
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkIdleTimeout();
    });
  }

  void _resetIdleTimer() {
    _lastUserSpeechTime = DateTime.now();
  }

  void _checkIdleTimeout() {
    if (_lastUserSpeechTime == null || _isPaused || _stopped) {
      return;
    }
    final secondsSinceLastSpeech = DateTime.now().difference(_lastUserSpeechTime!).inSeconds;
    if (secondsSinceLastSpeech >= _idleTimeoutSeconds) {
      debugPrint('⏱️ [TurnTaking] Idle timeout - pausing');
      _idleTimer?.cancel();
      pause();
      onPauseRequested?.call();
    }
  }

  /// Pause the conversation
  void pause() {
    _isPaused = true;

    // Cancel idle timer
    _idleTimer?.cancel();

    // Cancel VAD monitoring timers
    _amplitudeSubscription?.cancel();
    _silenceTimer?.cancel();
    _maxRecordingTimer?.cancel();
    
    if (_isRecording) {
      _recorder.stop();
      _isRecording = false;
    }
    
    // Stop any audio that's playing and notify UI
    if (_isPlaying) {
      _player.stop();
      _isPlaying = false;
      onSpeaking?.call(false);  // IMPORTANT: Notify UI to stop speaking animation
    }
    
    debugPrint('⏸️ Conversation paused');
  }
  
  /// Resume the conversation (from paused state)
  /// Always starts listening - this re-enables continuous mode if it was stopped
  Future<void> resume() async {
    debugPrint('▶️ resume() called');
    debugPrint('   _isPaused was: $_isPaused');
    debugPrint('   _isContinuousMode was: $_isContinuousMode');
    debugPrint('   _isProcessing: $_isProcessing');
    debugPrint('   _isPlaying: $_isPlaying');

    _isPaused = false;

    // Restart idle timer
    _startIdleTimer();

    // Always try to start listening when resuming (re-enables continuous mode)
    // This matches millie_mini behavior where resume goes directly to listening
    if (!_isProcessing && !_isPlaying) {
      debugPrint('   → Enabling continuous mode and starting listening');
      _isContinuousMode = true;  // Re-enable continuous mode for resumed conversation
      await startListening();
    } else {
      debugPrint('   → NOT starting listening (busy with processing/playing)');
    }
  }

  /// Resume and have AI speak first (natural response based on context)
  Future<void> resumeWithResponse() async {
    debugPrint('▶️ resumeWithResponse() called');
    _isPaused = false;
    _isContinuousMode = true;
    _stopped = false;

    // Restart idle timer
    _startIdleTimer();

    // Have AI generate a response first, then start listening
    await _generateAiFirstMessage();
    await startListening();
  }
  
  /// Stop the conversation completely
  Future<void> stopConversation() async {
    _stopped = true;  // Hard stop - prevent any further audio
    _isContinuousMode = false;
    _isPaused = false;
    _shouldEndConversation = false;

    // Cancel idle timer
    _idleTimer?.cancel();

    // Cancel VAD monitoring
    _amplitudeSubscription?.cancel();
    _silenceTimer?.cancel();
    _maxRecordingTimer?.cancel();
    
    if (_isRecording) {
      await _recorder.stop();
      _isRecording = false;
    }
    
    await _player.stop();
    _isPlaying = false;
    _isProcessing = false;
    _isStopping = false;
    
    _conversationHistory.clear();
    workflowToolsHandler?.clear();
    
    onStateChange?.call(VoiceState.idle);
    debugPrint('🛑 Conversation stopped - all state reset');
  }
  
  /// Clean up resources
  Future<void> dispose() async {
    await stopConversation();
    stopTokenTracking();
    await _tokenHistoryController.close();
    _recorder.dispose();
    _player.dispose();
  }
}

