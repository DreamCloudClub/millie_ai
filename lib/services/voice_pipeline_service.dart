import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'ticket_tools_handler.dart';
import 'workflow_tools.dart';

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
  
  // State
  bool _isRecording = false;
  bool _isProcessing = false;
  bool _isPlaying = false;
  bool _isContinuousMode = false;
  bool _isPaused = false;
  bool _isStopping = false;
  bool _shouldEndConversation = false;  // Set when complete_order is called
  
  // VAD (Voice Activity Detection) parameters
  StreamSubscription? _amplitudeSubscription;
  Timer? _silenceTimer;
  Timer? _maxRecordingTimer;
  DateTime? _lastSpeechTime;
  bool _hasDetectedSpeech = false;
  String? _currentRecordingPath;
  
  static const Duration _silenceThreshold = Duration(milliseconds: 1500);  // Stop after 1.5s silence
  static const Duration _maxRecordingDuration = Duration(seconds: 30);     // Max recording time
  static const double _speechAmplitudeThreshold = -25.0;  // dB threshold for speech
  
  // Conversation history
  final List<Map<String, String>> _conversationHistory = [];
  
  // System prompt and voice
  String _systemPrompt = '';
  String _voice = 'alloy';
  
  // Tool handlers
  TicketToolsHandler? ticketToolsHandler;
  WorkflowTools? workflowToolsHandler;
  
  // Callbacks
  void Function(VoiceState state)? onStateChange;
  void Function(String text)? onTranscription;  // User's speech
  void Function(String text)? onResponse;        // AI's response
  void Function(String error)? onError;
  void Function(bool speaking)? onSpeaking;
  void Function()? onConversationComplete;       // Called when order is complete
  void Function()? onPauseRequested;             // Called when user says "pause"
  
  VoicePipelineService();
  
  bool get isRecording => _isRecording;
  bool get isPlaying => _isPlaying;
  bool get isPaused => _isPaused;
  bool get isContinuousMode => _isContinuousMode;
  
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
    
    debugPrint('🎤 Starting conversation');
    
    // Speak greeting if provided
    if (greeting != null && greeting.isNotEmpty) {
      await _speakText(greeting);
      // Add greeting to history
      _conversationHistory.add({'role': 'assistant', 'content': greeting});
    }
    
    // Start listening
    await startListening();
  }
  
  /// Speak text only (no listening after) - for delivery mode
  Future<void> speakOnly({
    required String text,
    String voice = 'alloy',
  }) async {
    _voice = voice;
    _isPaused = false;
    _isContinuousMode = false;  // Don't start continuous listening
    
    debugPrint('🔊 Speaking only (delivery mode): $text');
    await _speakText(text);
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
      
      if (_hasDetectedSpeech && _lastSpeechTime != null) {
        final silenceDuration = DateTime.now().difference(_lastSpeechTime!);
        
        if (silenceDuration >= _silenceThreshold) {
          debugPrint('🎤 Silence detected (${silenceDuration.inMilliseconds}ms) - stopping');
          timer.cancel();
          _amplitudeSubscription?.cancel();
          _maxRecordingTimer?.cancel();
          
          if (_isRecording && !_isStopping) {
            _stopAndProcess(recordingPath);
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
      
      if (transcription == null || transcription.isEmpty) {
        debugPrint('No speech detected');
        _isProcessing = false;
        if (_isContinuousMode && !_isPaused) {
          await startListening();
        }
        return;
      }
      
      debugPrint('👤 User: $transcription');
      onTranscription?.call(transcription);
      
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
      
      // Handle tool calls if any
      String? aiResponse = response.content;
      bool shouldEndAfterSpeaking = false;
      if (response.hasToolCalls && (ticketToolsHandler != null || workflowToolsHandler != null)) {
        aiResponse = await _handleToolCalls(response, transcription);
        // Check if conversation was stopped during tool handling (e.g., complete_order)
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
      
      // Check if conversation should end (after complete_order)
      if (_shouldEndConversation || shouldEndAfterSpeaking) {
        debugPrint('🏁 Ending conversation after order completion');
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
    final apiKey = dotenv.env['OPENAI_API_KEY'];
    if (apiKey == null) return null;
    
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
    final apiKey = dotenv.env['OPENAI_API_KEY'];
    if (apiKey == null) return null;
    
    try {
      // Build system prompt with context from handlers
      String enhancedPrompt = _systemPrompt;
      if (ticketToolsHandler != null) {
        enhancedPrompt += ticketToolsHandler!.getActiveTicketContext();
      }
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
      if (ticketToolsHandler != null) {
        allTools.addAll(TicketToolsHandler.toolDefinitions);
      }
      if (workflowToolsHandler != null) {
        allTools.addAll(WorkflowTools.toolDefinitions);
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
          toolCalls = (message['tool_calls'] as List)
              .map((tc) => ToolCall.fromJson(tc))
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
    if (ticketToolsHandler == null && workflowToolsHandler == null) {
      return response.content;
    }
    
    debugPrint('Handling ${response.toolCalls!.length} tool call(s)');
    
    // Ticket tool names
    const ticketTools = {'add_order_item', 'complete_order', 'cancel_order', 'get_order_summary'};
    
    // Execute each tool
    final toolResults = <Map<String, dynamic>>[];
    for (final toolCall in response.toolCalls!) {
      ToolResult result;
      
      // Route to appropriate handler
      if (ticketTools.contains(toolCall.name) && ticketToolsHandler != null) {
        result = await ticketToolsHandler!.executeTool(toolCall);
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
      
      // If complete_order or cancel_order was called successfully, end conversation after speaking
      if ((toolCall.name == 'complete_order' || toolCall.name == 'cancel_order') && result.success) {
        _shouldEndConversation = true;
        debugPrint('🏁 Order ${toolCall.name == 'cancel_order' ? 'cancelled' : 'complete'} - will end conversation after speaking');
      }
      
      // If execute_now or confirm_and_execute was called, end conversation immediately - no more speech
      if ((toolCall.name == 'execute_now' || toolCall.name == 'confirm_and_execute') && result.success) {
        _shouldEndConversation = true;
        debugPrint('🏁 Workflow executing - ending conversation immediately (no speech)');
        // Return null to skip follow-up speech - workflow is starting
        return null;
      }
    }
    
    // Get follow-up response from LLM
    final apiKey = dotenv.env['OPENAI_API_KEY'];
    if (apiKey == null) return response.content;
    
    try {
      String enhancedPrompt = _systemPrompt;
      if (ticketToolsHandler != null) {
        enhancedPrompt += ticketToolsHandler!.getActiveTicketContext();
      }
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
  
  /// Text to Speech and play (like millie_mini pattern)
  Future<void> _speakText(String text) async {
    if (text.isEmpty) return;
    
    final apiKey = dotenv.env['OPENAI_API_KEY'];
    if (apiKey == null) return;
    
    onStateChange?.call(VoiceState.speaking);
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
  
  /// Pause the conversation
  void pause() {
    _isPaused = true;
    
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
  
  /// Stop the conversation completely
  Future<void> stopConversation() async {
    _isContinuousMode = false;
    _isPaused = false;
    _shouldEndConversation = false;
    
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
    ticketToolsHandler?.clear();
    workflowToolsHandler?.clear();  // Clear pending workflow steps
    
    onStateChange?.call(VoiceState.idle);
    debugPrint('🛑 Conversation stopped - all state reset');
  }
  
  /// Clean up resources
  Future<void> dispose() async {
    await stopConversation();
    _recorder.dispose();
    _player.dispose();
  }
}

