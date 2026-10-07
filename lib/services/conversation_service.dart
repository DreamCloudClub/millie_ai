import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/rosbridge.dart';
import 'voice_pipeline_service.dart';
import 'realtime_voice_service.dart';
import 'workflow_tools.dart';
import 'memory_tools.dart';
import 'local_memory_service.dart';
import 'notes_tools.dart';
import 'reminder_service.dart';
import 'local_cache_service.dart';
import 'consciousness_service.dart';
import 'fidget_service.dart';
import 'planned_search_service.dart';

/// Conversation states
enum ConversationState {
  idle,
  starting,
  greeting,
  listening,
  processing,
  speaking,
  complete,
  cancelled,
}

/// Activity log entry types
enum ActivityType {
  info,
  user,
  bot,
  state,
  movement,
  tool,
  error,
}

/// Activity log entry
class ActivityEntry {
  final String message;
  final DateTime timestamp;
  final ActivityType type;

  const ActivityEntry({
    required this.message,
    required this.timestamp,
    this.type = ActivityType.info,
  });
}

/// Manages AI conversation flow using STT → LLM → TTS pipeline
/// Supports two voice modes: turn_taking (default) and realtime (streaming)
class ConversationService extends ChangeNotifier {
  final RosBridge rosBridge;

  // Voice pipelines (two backends)
  late final VoicePipelineService _turnTakingPipeline;
  late final RealtimeVoiceService _realtimePipeline;
  late final WorkflowTools _workflowTools;
  late final LocalMemoryService _localMemoryService;
  late final MemoryTools _memoryTools;
  NotesTools? _notesTools;

  // Fidget service for subtle movements during conversation
  late final FidgetService _fidgetService;

  // Merged token stream (combines both pipelines)
  final StreamController<List<int>> _mergedTokenController = StreamController<List<int>>.broadcast();
  StreamSubscription<List<int>>? _turnTakingTokenSub;
  StreamSubscription<List<int>>? _realtimeTokenSub;

  // Consciousness service (optional, set externally)
  ConsciousnessService? _consciousnessService;

  /// Set the consciousness service for session tracking
  void setConsciousnessService(ConsciousnessService service) {
    _consciousnessService = service;
    // Connect local memory service to consciousness for long-term memory saving
    service.setLocalMemoryService(_localMemoryService);
    debugPrint('🧠 [ConversationService] Consciousness service connected');
  }

  /// Set the reminder service to enable notes and alerts tools
  void setReminderService(ReminderService service) {
    _notesTools = NotesTools(reminderService: service);

    // Wire up open note callback
    _notesTools!.onOpenNote = (noteId) {
      debugPrint('📝 [ConversationService] Open note requested: $noteId');
      onOpenNote?.call(noteId);
    };

    // Wire up to active pipeline
    _realtimePipeline.notesToolsHandler = _notesTools;
    _turnTakingPipeline.notesToolsHandler = _notesTools;
    debugPrint('📝 [ConversationService] Notes tools enabled');
  }

  // Planned search service reference
  PlannedSearchService? _plannedSearchService;

  /// Set the planned search service for object search
  void setPlannedSearchService(PlannedSearchService service) {
    _plannedSearchService = service;
    _workflowTools.plannedSearchService = service;

    // Search callbacks inject prompts - AI speaks
    service.onProgress = (message) {
      debugPrint('🔍 [ConversationService] Search progress: $message');
    };

    service.onTargetPendingVerification = (target, location, confidence, scene) {
      debugPrint('🔍 [ConversationService] Target pending verification: $target');
      injectPrompt('You see something that might be the $target. Ask the user if this is it.');
    };

    service.onTargetConfirmed = (target, location) {
      debugPrint('🎯 [ConversationService] Target confirmed: $target');
      injectPrompt('The user confirmed you found the $target. Celebrate briefly.');
    };

    service.onError = (error) {
      debugPrint('🔍 [ConversationService] Search error: $error');
      injectPrompt('Search had an issue: $error. Let the user know briefly.');
    };

    service.onSearchEnd = () {
      debugPrint('🔍 [ConversationService] Search ended');
      _workflowTools.resumeWanderAfterSearch();
      _updateFidgetState();
    };

    debugPrint('🔍 [ConversationService] Planned search service connected');
  }

  // Mode states (mutually exclusive: Wander, Follow)
  bool _wanderActive = false;   // Wander mode: wander only, AI stays active
  bool _conversationPausedForGoAway = false;  // True if we paused an active conversation to go away

  // Approach user state
  bool _approachingUser = false;

  // Navigation state
  bool _isNavigating = false;

  /// Check if robot is in any movement mode (no fidget during these)
  bool get _isInMovementMode {
    return _wanderActive ||
           _approachingUser ||
           _isNavigating ||
           (_plannedSearchService?.isSearching ?? false);
  }

  /// Update fidget state based on movement modes
  void _updateFidgetState() {
    if (_isInMovementMode) {
      _fidgetService.stop();
    } else {
      _fidgetService.start();
    }
  }

  // Track which pipeline is active
  String _activeVoiceMode = 'turn_taking';
  
  // Current state
  ConversationState _state = ConversationState.idle;
  ConversationState get state => _state;

  // Agents map (for looking up by name)
  Map<String, AgentDefinition> _agents = {};
  
  // Actions map (for looking up by name and finding default)
  Map<String, ActionDefinition> _actions = {};
  
  // Current action being executed
  ActionDefinition? _currentAction;
  ActionDefinition? get currentAction => _currentAction;

  // Flag to prevent double-handling of action complete
  bool _actionCompleteHandled = false;

  // Current agent (always uses default agent)
  AgentDefinition? _currentAgent;

  // Temp actions registry (for dynamic tasks created via queue_task)
  final Map<String, ActionDefinition> _tempActions = {};


  // Task flow state: pause → navigate → speak → resume
  String? _pendingArrivalMessage;
  bool _pausedForTask = false;

  // Search target capture - bypass AI tool calling
  bool _waitingForSearchTarget = false;

  // Callbacks for UI updates
  void Function(bool speaking)? onSpeakingChange;
  void Function(ConversationState state)? onStateChange;  // For face animations
  void Function(String text)? onBotText;
  void Function(String text)? onUserText;
  void Function(String status)? onStatus;
  void Function()? onPauseRequested;  // Called when user says "pause"

  // Activity log callbacks (legacy - still used for chaining)
  void Function(String event)? onMovementEvent;  // Wander, navigation
  void Function(String event)? onToolEvent;      // Workflow, memory, tasks
  void Function(String page)? onShowPage;        // Navigate to a page (face, dashboard, notes, schedule)
  void Function(String noteId)? onOpenNote;      // Open a specific note by ID

  // Activity log (persists across page swipes)
  static const int _maxActivityEntries = 50;
  final List<ActivityEntry> _activityLog = [];
  final StreamController<ActivityEntry> _activityController = StreamController<ActivityEntry>.broadcast();

  /// Stream of new activity entries
  Stream<ActivityEntry> get activityStream => _activityController.stream;

  /// Current activity log (newest first)
  List<ActivityEntry> get activityLog => List.unmodifiable(_activityLog);

  /// Add an activity entry
  void addActivity(String message, {ActivityType type = ActivityType.info}) {
    final entry = ActivityEntry(
      message: message,
      timestamp: DateTime.now(),
      type: type,
    );
    _activityLog.insert(0, entry);
    if (_activityLog.length > _maxActivityEntries) {
      _activityLog.removeRange(_maxActivityEntries, _activityLog.length);
    }
    _activityController.add(entry);
  }

  /// Clear activity log
  void clearActivityLog() {
    _activityLog.clear();
  }
  
  ConversationService({required this.rosBridge}) {
    _workflowTools = WorkflowTools(rosBridge);
    _localMemoryService = LocalMemoryService();
    _memoryTools = MemoryTools(_localMemoryService);
    _turnTakingPipeline = VoicePipelineService();
    _realtimePipeline = RealtimeVoiceService();
    _fidgetService = FidgetService(rosBridge);

    _setupTurnTakingCallbacks();
    _setupRealtimeCallbacks();
    _setupRosBridgeCallbacks();
    _setupWorkflowCallbacks();
    _loadCachedSettings();
    _initializeLocalMemory();
  }

  Future<void> _initializeLocalMemory() async {
    await _localMemoryService.initialize();
    debugPrint('🧠 [ConversationService] Local memory initialized');
  }

  /// Load cached settings on startup
  Future<void> _loadCachedSettings() async {
    final timeout = await LocalCacheService.loadVoiceIdleTimeout();
    debugPrint('⏱️ [ConversationService] Loaded cached voice timeout: ${timeout}s');
    _turnTakingPipeline.setIdleTimeout(timeout);
    _realtimePipeline.setIdleTimeout(timeout);

    // Load cached API key
    final cachedApiKey = await LocalCacheService.loadOpenAIApiKey();
    if (cachedApiKey != null && cachedApiKey.isNotEmpty) {
      VoicePipelineService.setApiKey(cachedApiKey);
      RealtimeVoiceService.setApiKey(cachedApiKey);
      WorkflowTools.setApiKey(cachedApiKey);
      debugPrint('🔑 [ConversationService] Loaded cached API key');
    }

    // Wire up LiDAR data to WorkflowTools for vision
    rosBridge.addLaserScanListener((scan) {
      _workflowTools.updateLaserScan(scan);
    });
  }
  
  void _setupTurnTakingCallbacks() {
    _turnTakingPipeline.onStateChange = (state) {
      if (_activeVoiceMode != 'turn_taking') return;
      switch (state) {
        case VoiceState.idle:
          _setState(ConversationState.idle);
          break;
        case VoiceState.listening:
          _setState(ConversationState.listening);
          break;
        case VoiceState.processing:
          _setState(ConversationState.processing);
          break;
        case VoiceState.speaking:
          _setState(ConversationState.speaking);
          break;
      }
    };

    _turnTakingPipeline.onTranscription = (text) {
      if (_activeVoiceMode != 'turn_taking') return;
      debugPrint('👤 User: $text');
      onUserText?.call(text);
      addActivity(text, type: ActivityType.user);
      // Record for consciousness
      _consciousnessService?.recordUserMessage(text);

      // Search handled by AI via tools (start_search, confirm_search_target, reject_search_target)
      // No interception - AI responds naturally with one voice
    };

    _turnTakingPipeline.onResponse = (text) {
      if (_activeVoiceMode != 'turn_taking') return;
      debugPrint('🤖 AI: $text');
      onBotText?.call(text);
      addActivity(text, type: ActivityType.bot);
      // Record for consciousness
      _consciousnessService?.recordAssistantMessage(text);
    };

    _turnTakingPipeline.onSpeaking = (speaking) {
      if (_activeVoiceMode != 'turn_taking') return;
      onSpeakingChange?.call(speaking);
    };

    _turnTakingPipeline.onPauseRequested = () {
      if (_activeVoiceMode != 'turn_taking') return;
      debugPrint('⏸️ Pause requested (voice command or idle timeout)');
      _fidgetService.stop();
      onPauseRequested?.call();
    };

    _turnTakingPipeline.onError = (error) {
      if (_activeVoiceMode != 'turn_taking') return;
      debugPrint('❌ Pipeline error: $error');
      onStatus?.call('Error: $error');
      addActivity('Error: $error', type: ActivityType.error);
    };

    _turnTakingPipeline.onConversationComplete = () {
      if (_activeVoiceMode != 'turn_taking') return;
      _handleConversationComplete();
    };
  }

  void _setupRealtimeCallbacks() {
    _realtimePipeline.onStateChange = (state) {
      if (_activeVoiceMode != 'realtime') return;
      switch (state) {
        case RealtimeVoiceState.idle:
          _setState(ConversationState.idle);
          break;
        case RealtimeVoiceState.connecting:
          _setState(ConversationState.starting);
          break;
        case RealtimeVoiceState.listening:
          _setState(ConversationState.listening);
          break;
        case RealtimeVoiceState.processing:
          _setState(ConversationState.processing);
          break;
        case RealtimeVoiceState.speaking:
          _setState(ConversationState.speaking);
          break;
      }
    };

    _realtimePipeline.onTranscription = (text) {
      if (_activeVoiceMode != 'realtime') return;
      debugPrint('👤 User: $text');
      onUserText?.call(text);
      addActivity(text, type: ActivityType.user);
      // Record for consciousness
      _consciousnessService?.recordUserMessage(text);
    };

    _realtimePipeline.onResponse = (text) {
      if (_activeVoiceMode != 'realtime') return;
      debugPrint('🤖 AI: $text');
      onBotText?.call(text);
      addActivity(text, type: ActivityType.bot);
      // Record for consciousness
      _consciousnessService?.recordAssistantMessage(text);
    };

    _realtimePipeline.onSpeaking = (speaking) {
      if (_activeVoiceMode != 'realtime') return;
      onSpeakingChange?.call(speaking);
    };

    _realtimePipeline.onPauseRequested = () {
      if (_activeVoiceMode != 'realtime') return;
      debugPrint('⏸️ Pause requested (voice command or idle timeout)');
      _fidgetService.stop();
      onPauseRequested?.call();
    };

    _realtimePipeline.onError = (error) {
      if (_activeVoiceMode != 'realtime') return;
      debugPrint('❌ Realtime error: $error');
      onStatus?.call('Error: $error');
      addActivity('Error: $error', type: ActivityType.error);
    };

    _realtimePipeline.onConversationComplete = () {
      if (_activeVoiceMode != 'realtime') return;
      _handleConversationComplete();
    };
  }

  void _handleConversationComplete() {
    debugPrint('✅ Conversation complete callback');
    // Skip if already handled by action complete
    if (_actionCompleteHandled) {
      debugPrint('⏭️ Action complete already handled - skipping');
      return;
    }
    _setState(ConversationState.complete);
    if (_currentAction != null) {
      rosBridge.publishActionComplete(_currentAction!.name);
      onToolEvent?.call('Action complete: ${_currentAction!.name}');
      addActivity('Action complete: ${_currentAction!.name}', type: ActivityType.tool);
    }

    // End consciousness session (runs AI reflection in background)
    _consciousnessService?.endSession();

    // Check if this was a temp action
    final wasTempAction = _currentAction != null && _tempActions.containsKey(_currentAction!.name);

    // Clean up temp action if it was one (both locally and on ROS2)
    if (wasTempAction && _currentAction != null) {
      final tempActionName = _currentAction!.name;
      _tempActions.remove(tempActionName);
      rosBridge.publishDeleteAction(tempActionName);
      debugPrint('🧹 [ConversationService] Cleaned up temp action: $tempActionName');
    }

    // Reset state after a brief delay so next conversation can start
    Future.delayed(const Duration(milliseconds: 500), () {
      _reset();
      debugPrint('🔄 Conversation reset - ready for next action');
    });
  }
  
  // Multi-listener references for cleanup
  late final void Function(List<AgentDefinition>) _agentListener;
  late final void Function(List<ActionDefinition>) _actionListener;

  // Person detection state for AI prompts
  String _lastPersonStatus = '';
  bool _lastPersonDetected = false;

  void _setupRosBridgeCallbacks() {
    // Listen for agents updates (multi-listener pattern)
    _agentListener = (agents) {
      _agents = {for (var a in agents) a.name: a};
      debugPrint('🤖 ConversationService: Agents loaded: ${_agents.keys.toList()}');
    };
    rosBridge.addAgentListener(_agentListener);
    
    // Listen for actions updates (multi-listener pattern)
    _actionListener = (actions) {
      _actions = {for (var a in actions) a.name: a};
      final defaultAction = actions.where((a) => a.isDefault).firstOrNull;
      debugPrint('🎯 ConversationService: Actions loaded: ${_actions.keys.toList()}');
      debugPrint('🎯 Default action: ${defaultAction?.name ?? "none"}');
    };
    rosBridge.addActionListener(_actionListener);

    // Listen for person detection status (inject into AI conversation)
    rosBridge.onPersonStatus = _handlePersonStatus;

    // Listen for following mode status
    rosBridge.onFollowingModeStatus = _handleFollowingModeStatus;

    // Listen for wander mode status
    rosBridge.onWanderStatus = _handleWanderStatus;

    // Listen for navigation complete (for task flow: pause → nav → speak → resume)
    rosBridge.onNavStatusUpdate = _handleNavStatusForTask;

    // Listen for speak commands from controller (robot speaks text)
    rosBridge.onSpeakCommand = _handleSpeakCommand;

    // Listen for voice idle timeout changes from controller
    rosBridge.onVoiceIdleTimeout = _handleVoiceIdleTimeout;

    // Listen for API key from robot
    rosBridge.onApiKeyReceived = _handleApiKeyReceived;
    rosBridge.onApiKeyStatus = _handleApiKeyStatus;

    // Request data on startup
    rosBridge.requestAgents();
    rosBridge.requestActions();
    rosBridge.requestApiKey();  // Request actual API key for voice services
  }

  /// Handle API key received from robot
  void _handleApiKeyReceived(String key) {
    if (key.isNotEmpty) {
      VoicePipelineService.setApiKey(key);
      RealtimeVoiceService.setApiKey(key);
      WorkflowTools.setApiKey(key);
      LocalCacheService.saveOpenAIApiKey(key);
      debugPrint('🔑 [ConversationService] API key received and cached');
    }
  }

  /// Handle API key status update from robot
  void _handleApiKeyStatus(Map<String, dynamic> status) {
    final isSet = status['is_set'] as bool? ?? false;
    final prefix = status['key_prefix'] as String? ?? '';
    debugPrint('🔑 [ConversationService] API key status: isSet=$isSet, prefix=$prefix');
  }

  /// Handle navigation status for task flow
  /// NOTE: Speech is handled by handleTaskAction when robot sends action execute
  void _handleNavStatusForTask(NavStatus status) {
    // Skip if not paused for a task
    if (!_pausedForTask) return;

    if (status == NavStatus.failed) {
      debugPrint('❌ [ConversationService] Navigation failed');
      _pendingArrivalMessage = null;
      _pausedForTask = false;
      onMovementEvent?.call('Navigation failed');
      addActivity('Navigation failed', type: ActivityType.movement);
      _resumeSilently();
    }
    // For succeeded: wait for action execute from workflow executor
  }

  /// Handle speak command from controller - robot speaks text out loud
  void _handleSpeakCommand(String text) {
    debugPrint('🔊 [ConversationService] Speaking from controller: $text');
    _turnTakingPipeline.speakText(text);
  }

  /// Handle voice idle timeout change from controller
  void _handleVoiceIdleTimeout(int seconds) {
    debugPrint('⏱️ [ConversationService] Voice idle timeout set to ${seconds}s');
    _turnTakingPipeline.setIdleTimeout(seconds);
    _realtimePipeline.setIdleTimeout(seconds);
    // Cache locally so it persists
    LocalCacheService.saveVoiceIdleTimeout(seconds);
  }

  // ===========================================================================
  // SEARCH TARGET CAPTURE (bypasses AI tool calling)
  // ===========================================================================

  /// Set flag to capture next user speech as search target
  void setWaitingForSearchTarget(bool waiting) {
    _waitingForSearchTarget = waiting;
    debugPrint('🔍 [ConversationService] Waiting for search target: $waiting');
  }

  /// Speak a prompt and listen for response
  void speakAndListen(String prompt) {
    debugPrint('🔍 [ConversationService] Speaking and listening: $prompt');

    // Make sure conversation is active
    if (!isActive) {
      startDefaultConversation(withIntro: false);
      Future.delayed(const Duration(milliseconds: 500), () {
        _turnTakingPipeline.speakText(prompt);
      });
    } else {
      _turnTakingPipeline.speakText(prompt);
    }
  }

  /// Extract search target from voice command, or null if not a search command
  String? _extractSearchTarget(String text) {
    final lower = text.toLowerCase();

    // Patterns: "find my keys", "search for the remote", "look for my phone", "where is my wallet"
    final patterns = [
      RegExp(r"(?:find|search for|look for|looking for)\s+(?:my\s+|the\s+|a\s+)?(.+)", caseSensitive: false),
      RegExp(r"(?:where(?:'s| is| are))\s+(?:my\s+|the\s+)?(.+)", caseSensitive: false),
      RegExp(r"(?:can you find|help me find)\s+(?:my\s+|the\s+|a\s+)?(.+)", caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(lower);
      if (match != null && match.group(1) != null) {
        final target = match.group(1)!.trim();
        // Filter out non-search phrases
        if (target.isNotEmpty &&
            !target.contains('way') &&  // "find a way"
            !target.contains('out') &&  // "find out"
            target.length < 50) {
          debugPrint('🔍 [ConversationService] Detected search command: "$target"');
          return target;
        }
      }
    }
    return null;
  }

  /// Check if response is affirmative (yes, yeah, correct, etc.)
  bool _isAffirmative(String text) {
    final affirmatives = [
      'yes', 'yeah', 'yep', 'yup', 'correct', 'right', 'that\'s it',
      'thats it', 'that is it', 'found it', 'you found it', 'perfect',
      'exactly', 'bingo', 'affirmative', 'confirmed', 'sure', 'ok', 'okay',
    ];
    for (final word in affirmatives) {
      if (text.contains(word)) return true;
    }
    return false;
  }

  /// Check if response is negative (no, nope, wrong, etc.)
  bool _isNegative(String text) {
    final negatives = [
      'no', 'nope', 'nah', 'wrong', 'not it', 'that\'s not', 'thats not',
      'incorrect', 'keep looking', 'continue', 'keep searching', 'try again',
      'negative', 'not the', 'different',
    ];
    for (final word in negatives) {
      if (text.contains(word)) return true;
    }
    return false;
  }

  /// Start search directly with captured target (bypasses AI)
  void _startSearchWithTarget(String target) {
    debugPrint('🔍 [ConversationService] Starting search for: "$target"');

    if (_plannedSearchService == null) {
      debugPrint('🔍 [ConversationService] No search service!');
      return;
    }

    // Stop fidget - search is a movement mode
    _updateFidgetState();

    // Inject prompt so AI acknowledges the search
    injectPrompt('User asked you to find "$target". Briefly acknowledge and say you\'re looking.');

    // Start the search
    _plannedSearchService!.startSearch(target);
  }

  /// Resume AI silently (no "I'm back" intro)
  void _resumeSilently() {
    debugPrint('🔇 [ConversationService] Resuming silently');
    if (_activeVoiceMode == 'realtime') {
      _realtimePipeline.resume();
    } else {
      _turnTakingPipeline.resume();
    }
    _setState(ConversationState.listening);
  }

  /// Handle following mode status changes
  void _handleFollowingModeStatus(Map<String, dynamic> status) {
    final mode = status['status'] as String? ?? 'disabled';
    _workflowTools.updateFollowingStatus(status: mode);
    debugPrint('🚶 [ConversationService] Following mode: $mode');
  }

  /// Handle wander mode status changes
  void _handleWanderStatus(String status) {
    _workflowTools.updateWanderStatus(status: status);
    debugPrint('🚶 [ConversationService] Wander mode: $status');
  }

  /// Handle person detection status changes and inject prompts to AI
  void _handlePersonStatus(Map<String, dynamic> status) {
    final newStatus = status['status'] as String? ?? '';
    final personDetected = status['person_detected'] as bool? ?? false;
    final distance = status['distance'] as num?;
    final centered = status['centered'] as bool? ?? false;

    // Track detection state
    final wasDetected = _lastPersonDetected;

    // Update state first
    _lastPersonStatus = newStatus;
    _lastPersonDetected = personDetected;

    // Update workflow tools so AI can query status
    _workflowTools.updatePersonStatus(
      detected: personDetected,
      distance: distance?.toDouble(),
      centered: centered,
    );

    // Approach user mode: stop when within 1 meter
    if (_approachingUser && personDetected && distance != null && distance <= 1.0) {
      debugPrint('🚶 Approached user - within ${distance}m, stopping');
      _approachingUser = false;
      rosBridge.publishPersonFollowerDisable();
      // Don't return - let the status change prompt be injected if active
    }

    // Only inject prompts during active conversation
    if (_state == ConversationState.idle || _state == ConversationState.complete) {
      return;
    }

    // Detect significant state changes (use wasDetected from above)
    final statusChanged = newStatus != status['status'];

    String? prompt;

    if (personDetected && !wasDetected) {
      // Person just detected
      final distStr = distance != null ? '${distance.toStringAsFixed(1)} meters away' : 'nearby';
      prompt = 'I can see a person $distStr. They are ${centered ? 'directly in front of me' : 'to my side'}.';
    } else if (!personDetected && wasDetected) {
      // Person just lost
      prompt = 'I lost sight of the person.';
    } else if (personDetected && statusChanged) {
      // Status changed while tracking
      if (newStatus == 'arrived') {
        prompt = 'I have reached the person. They are right in front of me now.';
      } else if (newStatus == 'tracking') {
        prompt = 'I am now at a comfortable distance from the person.';
      }
    }

    // Log person status changes (silent - AI can query via get_robot_status tool)
    if (prompt != null) {
      debugPrint('👤 [ConversationService] Person status (silent): $prompt');
    }
  }
  
  void _setupWorkflowCallbacks() {
    _workflowTools.onWorkflowConfirmed = () {
      debugPrint('🚀 Workflow confirmed - stopping conversation immediately');
      _actionCompleteHandled = true;  // Prevent double-handling
      onToolEvent?.call('Workflow confirmed');
      addActivity('Workflow confirmed', type: ActivityType.tool);

      // Stop listening/speaking immediately - no more conversation
      // Workflow was already published by workflow_tools.confirm_and_execute
      _stopActivePipeline();
      debugPrint('🛑 Conversation stopped - workflow starting');

      // Reset conversation state (no delay needed - workflow starts now)
      _reset();
    };

    // Wander mode callbacks (wander only, AI stays active)
    _workflowTools.onWanderModeStart = () {
      debugPrint('🚶 Wander mode start requested');
      startWanderOnly();
    };

    _workflowTools.onWanderModeStop = () {
      debugPrint('🛑 Wander mode stop requested');
      stopWander();
    };

    _workflowTools.onGoAwayRequested = () {
      debugPrint('👋 Go away requested - pausing conversation for wander');

      // Pause the conversation (keep session alive) instead of stopping
      if (_activeVoiceMode == 'realtime') {
        _realtimePipeline.pause();
      } else {
        _turnTakingPipeline.pause();
      }
      _conversationPausedForGoAway = true;

      // Start wander mode
      startWander();
    };

    _workflowTools.onApproachUserRequested = () {
      debugPrint('🚶 Approach user requested - enabling person follower');
      _approachingUser = true;
      rosBridge.publishPersonFollowerEnable();
    };

    _workflowTools.onTempTaskQueued = (action, originPose) {
      debugPrint('📋 [ConversationService] Temp task queued: ${action.name}');
      // Register temp action so it can be looked up when workflow executes it
      _tempActions[action.name] = action;
      onToolEvent?.call('Task queued: ${action.name}');
      addActivity('Task queued: ${action.name}', type: ActivityType.tool);
    };

    _workflowTools.onConversationEnd = () {
      debugPrint('👋 [ConversationService] AI requested conversation end');

      // Stop the active pipeline
      _stopActivePipeline();

      // Handle completion (return to origin, cleanup, etc.)
      _handleConversationComplete();
    };

    // New task flow: pause AI → workflow handles navigate+action → speak on action execute → resume
    // NOTE: workflow_tools._go() already publishes the workflow (navigate+action steps)
    // We just need to pause AI and store message - workflow executor handles the rest
    _workflowTools.onTaskStart = (destination, messageToSpeak) {
      debugPrint('🚀 [ConversationService] Task start: $destination');
      debugPrint('💬 [ConversationService] Message to speak on arrival: $messageToSpeak');

      // Store pending message for when action executes
      _pendingArrivalMessage = messageToSpeak;
      _pausedForTask = true;
      onMovementEvent?.call('Navigating to $destination');
      addActivity('Navigating to $destination', type: ActivityType.movement);

      // IMPORTANT: Delay the pause to let the AI speak "On my way!" first
      // If we pause immediately, the response audio gets ignored
      Future.delayed(const Duration(seconds: 3), () {
        if (_pausedForTask) {  // Only pause if still in task mode
          debugPrint('⏸️ [ConversationService] Pausing AI after response delay');
          if (_activeVoiceMode == 'realtime') {
            _realtimePipeline.pause();
          } else {
            _turnTakingPipeline.pause();
          }
          debugPrint('⏸️ [ConversationService] AI paused - waiting for action execute');
        }
      });
    };

    // Handle speech only when idle/ready (not during active conversation)
    _workflowTools.onSpeakIfIdle = (text) {
      if (_state == ConversationState.idle) {
        debugPrint('🔊 [ConversationService] Speaking (idle): $text');
        _turnTakingPipeline.speakText(text);
      } else {
        debugPrint('🔇 [ConversationService] Skipping speech (in conversation): $text');
      }
    };

    // Handle page navigation requests from AI
    _workflowTools.onShowPage = (page) {
      debugPrint('📺 [ConversationService] Show page requested: $page');
      onShowPage?.call(page);
    };
  }

  // ===========================================================================
  // WANDER MODE: Simple free roaming, AI stays active
  // ===========================================================================

  /// Start wander mode - simple free roaming, AI stays active
  /// Robot can talk while moving - does NOT pause for conversation
  Future<void> startWander() async {
    debugPrint('🚶 Starting wander mode');

    _wanderActive = true;
    _updateFidgetState();  // Stop fidget during movement

    // Enable wander
    rosBridge.activateWanderMode();

    // Immediately update WorkflowTools so it knows wander is active
    // (don't wait for ROSBridge callback which may have delay)
    _workflowTools.updateWanderStatus(status: 'enabled');

    // AI stays active - no changes to conversation state
    debugPrint('✅ Wander mode active - AI can still talk');
    onMovementEvent?.call('Wander mode started');
    addActivity('Wander mode started', type: ActivityType.movement);
  }

  /// Stop wander mode
  Future<void> stopWander() async {
    debugPrint('🛑 Stopping wander mode');
    _wanderActive = false;
    _updateFidgetState();  // May resume fidget if no other movement

    // Immediately update WorkflowTools
    _workflowTools.updateWanderStatus(status: 'disabled');

    // Note: Don't stop search here - search is independent and pauses wander itself
    // If user wants to stop search, they say "stop searching"

    // Disable wander
    rosBridge.deactivateWanderMode();
    onMovementEvent?.call('Wander mode stopped');
    addActivity('Wander mode stopped', type: ActivityType.movement);
  }

  bool get isWanderActive => _wanderActive;

  // Legacy aliases for backward compatibility
  Future<void> startWanderOnly() => startWander();
  Future<void> stopWanderOnly() => stopWander();
  bool get isWanderOnlyActive => _wanderActive;

  /// Stop whichever pipeline is currently active
  Future<void> _stopActivePipeline() async {
    if (_activeVoiceMode == 'realtime') {
      await _realtimePipeline.stopConversation();
    } else {
      await _turnTakingPipeline.stopConversation();
    }
  }
  
  /// Start a conversation with the given action
  Future<void> startConversation(ActionDefinition action) async {
    // If not idle, force reset (allows new workflow to interrupt pending cleanup)
    if (_state != ConversationState.idle) {
      debugPrint('⚠️ Conversation not idle (state: $_state) - forcing reset');
      await _stopActivePipeline();
      _reset();
    }

    // Start consciousness session
    _consciousnessService?.startSession();

    _currentAction = action;
    _setState(ConversationState.starting);

    // Always use the default agent
    _currentAgent = getDefaultAgent();
    if (_currentAgent != null) {
      debugPrint('🤖 Using default agent: ${_currentAgent!.name}');
    }

    // Determine voice mode from agent (defaults to turn_taking)
    _activeVoiceMode = _currentAgent?.voiceMode ?? 'turn_taking';
    debugPrint('🎙️ Voice mode: $_activeVoiceMode');

    // Configure tool handlers - all actions get workflow + memory + notes tools
    if (_activeVoiceMode == 'realtime') {
      _realtimePipeline.memoryToolsHandler = _memoryTools;
      _realtimePipeline.workflowToolsHandler = _workflowTools;
      _realtimePipeline.notesToolsHandler = _notesTools;
      debugPrint('🧭 [Realtime] Enabled: workflow + memory + notes tools');
    } else {
      _turnTakingPipeline.memoryToolsHandler = _memoryTools;
      _turnTakingPipeline.workflowToolsHandler = _workflowTools;
      _turnTakingPipeline.notesToolsHandler = _notesTools;
      debugPrint('🧭 [TurnTaking] Enabled: workflow + memory + notes tools');
    }

    debugPrint('🎬 Starting conversation: ${action.name}');

    // Build system prompt (uses agent if available)
    final systemPrompt = buildSystemPrompt();

    // Get greeting from action (if any) and apply template substitution
    // If no greeting, AI will speak first naturally based on identity context
    String? greeting;
    if (action.openingGreeting.isNotEmpty) {
      greeting = _substituteTemplateVariables(action.openingGreeting);
    }

    // Get voice
    final voice = getVoice();

    // Start the appropriate pipeline based on voice mode
    if (_activeVoiceMode == 'realtime') {
      await _realtimePipeline.startConversation(
        systemPrompt: systemPrompt,
        voice: voice,
        greeting: greeting,
      );
    } else {
      await _turnTakingPipeline.startConversation(
        systemPrompt: systemPrompt,
        voice: voice,
        greeting: greeting,
      );
    }

    _setState(ConversationState.listening);
  }
  
  /// Substitute template variables in text
  /// Supported: {robot_name}
  String _substituteTemplateVariables(String text) {
    // Robot name from current agent (or default to Millie)
    final robotName = _currentAgent?.name ?? 'Millie';
    text = text.replaceAll('{robot_name}', robotName);
    return text;
  }
  
  /// Pause the conversation
  void pauseConversation() {
    if (_activeVoiceMode == 'realtime') {
      _realtimePipeline.pause();
    } else {
      _turnTakingPipeline.pause();
    }
    // Stop fidgeting when paused
    _fidgetService.stop();
    onStatus?.call('Paused');
    notifyListeners();
  }

  /// Resume the conversation - just start listening (no AI intro)
  Future<void> resumeConversation() async {
    // Restart fidgeting when conversation resumes
    _fidgetService.start();
    if (_activeVoiceMode == 'realtime') {
      await _realtimePipeline.resume();
      // Just resume listening - no AI intro
    } else {
      await _turnTakingPipeline.resumeWithResponse();
    }
    onStatus?.call('Resumed');
    notifyListeners();
  }

  /// Deliver an alert and start listening for user response
  /// Used for reminder/alert delivery - interrupts current state
  Future<void> deliverAlert({
    required String alertMessage,
    required String alertContext,
  }) async {
    debugPrint('🔔 [ConversationService] Delivering alert: $alertMessage');

    // Stop any current conversation
    if (_state != ConversationState.idle) {
      await _stopActivePipeline();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    _activeVoiceMode = 'turn_taking';

    // Deliver the alert via turn-taking pipeline
    await _turnTakingPipeline.deliverAlertAndListen(
      alertMessage: alertMessage,
      alertContext: alertContext,
      voice: _currentAgent?.voice ?? 'nova',
    );

    _setState(ConversationState.listening);
    onStatus?.call('Alert delivered');
    notifyListeners();
  }

  /// Inject a prompt to make the AI respond
  /// Used for search events, motion detection, direction changes, etc.
  void injectPrompt(String prompt) {
    if (_state == ConversationState.idle) return;

    if (_activeVoiceMode == 'realtime') {
      _realtimePipeline.injectPrompt(prompt);
    } else {
      _turnTakingPipeline.injectPrompt(prompt);
    }
  }

  /// Inject context without triggering a vocal response (realtime mode only)
  /// Used for adding instructions the AI should follow silently.
  void injectContext(String context) {
    if (_activeVoiceMode == 'realtime' && _state != ConversationState.idle) {
      _realtimePipeline.injectContext(context);
    }
  }

  /// Check if conversation is active
  bool get isActive => _state != ConversationState.idle && _state != ConversationState.complete;

  /// Get current voice mode
  String get voiceMode => _activeVoiceMode;

  /// Token usage tracking - merged stream from both pipelines
  Stream<List<int>> get tokenHistoryStream => _mergedTokenController.stream;

  /// Current token history snapshot (from active mode)
  List<int> get tokenHistory => _activeVoiceMode == 'realtime'
      ? _realtimePipeline.tokenHistory
      : _turnTakingPipeline.tokenHistory;

  /// Total tokens used this session (combined from both services)
  int get sessionTotalTokens =>
      _turnTakingPipeline.sessionTotalTokens + _realtimePipeline.sessionTotalTokens;

  /// Tokens from the last API response
  int get lastResponseTokens => _activeVoiceMode == 'realtime'
      ? _realtimePipeline.lastResponseTokens
      : _turnTakingPipeline.lastResponseTokens;

  /// Start token tracking on both services and merge streams
  void startTokenTracking() {
    _turnTakingPipeline.startTokenTracking();
    _realtimePipeline.startTokenTracking();

    // Subscribe to both streams and forward to merged controller
    _turnTakingTokenSub?.cancel();
    _realtimeTokenSub?.cancel();

    _turnTakingTokenSub = _turnTakingPipeline.tokenHistoryStream.listen((history) {
      if (_activeVoiceMode == 'turn_taking') {
        _mergedTokenController.add(history);
      }
    });

    _realtimeTokenSub = _realtimePipeline.tokenHistoryStream.listen((history) {
      if (_activeVoiceMode == 'realtime') {
        _mergedTokenController.add(history);
      }
    });
  }

  /// Stop token tracking on both services
  void stopTokenTracking() {
    _turnTakingTokenSub?.cancel();
    _realtimeTokenSub?.cancel();
    _turnTakingPipeline.stopTokenTracking();
    _realtimePipeline.stopTokenTracking();
  }

  /// Reset token tracking on both services
  void resetTokenTracking() {
    _turnTakingPipeline.resetTokenTracking();
    _realtimePipeline.resetTokenTracking();
  }

  /// Get the default agent (if one is set)
  AgentDefinition? getDefaultAgent() {
    return _agents.values.where((a) => a.isDefault).firstOrNull;
  }
  
  /// Get the default action (if one is set)
  ActionDefinition? getDefaultAction() {
    return _actions.values.where((a) => a.isDefault).firstOrNull;
  }

  /// Look up an action by name (includes temp actions)
  ActionDefinition? getAction(String name) {
    // Check temp actions first (they take precedence)
    if (_tempActions.containsKey(name)) {
      return _tempActions[name];
    }
    // Then check regular actions
    return _actions[name];
  }
  
  /// Run startup sequence with motion test and intro speech
  /// Called when face launches - speaks intro, tests motion, then goes to ready state
  Future<void> runStartupSequence({void Function()? onComplete}) async {
    debugPrint('🚀 Running startup sequence');

    // Get default agent for voice
    _currentAgent = getDefaultAgent();
    final voice = getVoice();

    _setState(ConversationState.starting);

    // Intro speech before motion test
    await _turnTakingPipeline.speakOnly(
      text: "Hello world! Millie reporting for duty. All systems coming online. Let me check my motion control.",
      voice: voice,
    );

    // Start motion test in background (don't wait for it to finish)
    unawaited(_runMotionTest());

    // Speak completion while motion runs
    await _turnTakingPipeline.speakOnly(
      text: "Motion control systems are looking good. It's gonna be a great day!",
      voice: voice,
    );

    _setState(ConversationState.idle);
    debugPrint('✅ Startup sequence complete - ready state');

    // Call completion callback
    onComplete?.call();
  }

  /// Motion test sequence
  Future<void> _runMotionTest() async {
    // Rotate left
    rosBridge.publishCmdVel(-0.7, 0);
    await Future.delayed(const Duration(milliseconds: 1000));

    // Rotate right
    rosBridge.publishCmdVel(0.7, 0);
    await Future.delayed(const Duration(milliseconds: 2500));

    // Back to center
    rosBridge.publishCmdVel(-0.7, 0);
    await Future.delayed(const Duration(milliseconds: 1000));

    // Stop
    rosBridge.publishCmdVel(0, 0);
  }

  /// Quick start - short intro, no motion test
  /// Called when Play button is pressed (skip full startup sequence)
  Future<void> runQuickStart({void Function()? onComplete}) async {
    debugPrint('▶️ Running quick start');

    // Get default agent for voice
    _currentAgent = getDefaultAgent();
    final voice = getVoice();

    _setState(ConversationState.starting);

    // Short intro message
    await _turnTakingPipeline.speakOnly(
      text: "All systems online. It's going to be a great day!",
      voice: voice,
    );

    _setState(ConversationState.idle);
    debugPrint('✅ Quick start complete');

    // Call completion callback
    onComplete?.call();
  }

  /// Start a default conversation (for wake word, play button, or double-tap when idle)
  /// Uses the default agent directly - no action required
  /// Set [withIntro] to false for silent start (e.g., wander mode)
  Future<void> startDefaultConversation({bool withIntro = true}) async {
    // If not idle, force reset
    if (_state != ConversationState.idle) {
      debugPrint('⚠️ Conversation not idle (state: $_state) - forcing reset');
      await _stopActivePipeline();
      _reset();
    }

    // Get default agent
    _currentAgent = getDefaultAgent();
    if (_currentAgent == null) {
      debugPrint('⚠️ No default agent found - creating fallback');
      // Fallback agent if none configured
      _currentAgent = AgentDefinition(
        name: 'Assistant',
        voice: 'nova',
        voiceMode: 'turn_taking',
        personality: 'Friendly and helpful assistant.',
        isDefault: true,
      );
    }

    debugPrint('🎯 Starting conversation with agent: ${_currentAgent!.name}');

    // Start consciousness session
    _consciousnessService?.startSession();

    _setState(ConversationState.starting);

    // Determine voice mode from agent
    _activeVoiceMode = _currentAgent!.voiceMode.isNotEmpty ? _currentAgent!.voiceMode : 'turn_taking';
    debugPrint('🎙️ Voice mode: $_activeVoiceMode');

    // Configure tool handlers
    if (_activeVoiceMode == 'realtime') {
      _realtimePipeline.memoryToolsHandler = _memoryTools;
      _realtimePipeline.workflowToolsHandler = _workflowTools;
      _realtimePipeline.notesToolsHandler = _notesTools;
      debugPrint('🧭 [Realtime] All tools enabled');
    } else {
      _turnTakingPipeline.memoryToolsHandler = _memoryTools;
      _turnTakingPipeline.workflowToolsHandler = _workflowTools;
      _turnTakingPipeline.notesToolsHandler = _notesTools;
      debugPrint('🧭 [TurnTaking] All tools enabled');
    }

    // Build system prompt using agent personality
    final systemPrompt = buildSystemPrompt();

    // Get voice from agent
    final voice = getVoice();

    debugPrint('🗣️ Voice: $voice');

    // Start the appropriate pipeline - just start listening, no intro
    if (_activeVoiceMode == 'realtime') {
      await _realtimePipeline.startConversation(
        systemPrompt: systemPrompt,
        voice: voice,
      );
    } else {
      await _turnTakingPipeline.startConversation(
        systemPrompt: systemPrompt,
        voice: voice,
      );
    }

    _setState(ConversationState.listening);
  }
  
  /// Check if in idle state (no active conversation)
  bool get isIdle => _state == ConversationState.idle;
  
  /// Check if conversation is paused (mid-conversation, temporarily stopped)
  bool get isPaused => _activeVoiceMode == 'realtime'
      ? _realtimePipeline.isPaused
      : _turnTakingPipeline.isPaused;

  /// Check if paused for a task (navigate + action flow)
  bool get isPausedForTask => _pausedForTask;

  /// Handle action when paused for task - speak message and resume normal conversation
  Future<void> handleTaskAction(ActionDefinition action) async {
    debugPrint('🎯 [ConversationService] Handling task action: ${action.name}');
    debugPrint('🎯 [ConversationService] Pending message: $_pendingArrivalMessage');
    debugPrint('🎯 [ConversationService] Action greeting: ${action.openingGreeting}');
    onMovementEvent?.call('Arrived at destination');
    addActivity('Arrived at destination', type: ActivityType.movement);

    // Use the stored message or action's greeting
    final message = _pendingArrivalMessage ?? action.openingGreeting;
    _pendingArrivalMessage = null;
    _pausedForTask = false;

    debugPrint('🎯 [ConversationService] Final message to speak: $message');

    if (message.isEmpty) {
      debugPrint('⚠️ [ConversationService] No message to speak - resuming silently');
      rosBridge.publishActionComplete(action.name);
      _resumeSilently();
      return;
    }

    final voice = getVoice();
    debugPrint('💬 [ConversationService] Delivering message via direct TTS');

    // Use direct TTS for delivery (not through AI) - prevents verbose interpretation
    await _turnTakingPipeline.speakOnly(text: message, voice: voice);

    // Mark action as complete
    rosBridge.publishActionComplete(action.name, delivered: true);

    // Resume the appropriate pipeline for ongoing conversation
    if (_activeVoiceMode == 'realtime') {
      await _realtimePipeline.resume();
    } else {
      _resumeSilently();
    }
  }

  /// Stop listening (when user finishes speaking)
  Future<void> stopListening() async {
    // Only turn-taking pipeline has this method
    if (_activeVoiceMode == 'turn_taking') {
      await _turnTakingPipeline.stopListening();
    }
  }

  /// Cancel the current conversation
  Future<void> cancelConversation() async {
    if (_state == ConversationState.idle) return;

    debugPrint('❌ Conversation cancelled');
    _setState(ConversationState.cancelled);

    await _stopActivePipeline();

    // End consciousness session (runs AI reflection in background)
    // This generates a summary and updates identity even when cancelled
    _consciousnessService?.endSession();

    _reset();
  }
  
  /// Build the system prompt
  String buildSystemPrompt() {
    final buffer = StringBuffer();

    // Core role definition
    buffer.writeln('ROLE: You are a friendly robot assistant.');
    buffer.writeln('Be conversational and natural. Keep responses concise but expand when the topic warrants it.');
    buffer.writeln('IMPORTANT: Never list your capabilities or explain what you can do unless specifically asked. Greetings should be natural and brief - just say hello, not a menu of options.');
    buffer.writeln();

    // User profile (owner info)
    final userProfile = rosBridge.userProfile;
    if (userProfile != null && userProfile.username.isNotEmpty) {
      buffer.writeln('OWNER INFORMATION:');
      buffer.writeln('Name: ${userProfile.username}');
      if (userProfile.pronouns.isNotEmpty) {
        buffer.writeln('Pronouns: ${userProfile.pronouns}');
      }
      if (userProfile.bio.isNotEmpty) {
        buffer.writeln('About: ${userProfile.bio}');
      }
      buffer.writeln();
    }

    // Agent-specific context
    if (_currentAgent != null) {
      buffer.writeln('AGENT: ${_currentAgent!.name}');
      if (_currentAgent!.personality.isNotEmpty) {
        buffer.writeln('PERSONALITY: ${_currentAgent!.personality}');
      }
      buffer.writeln();
    }

    // Memory context - what the agent knows/remembers
    buffer.write(_memoryTools.getMemoryContext());

    // Consciousness context - core values, desires, greeting
    if (_consciousnessService != null && _consciousnessService!.isInitialized) {
      buffer.write(_consciousnessService!.getConsciousnessContext());
    }

    return buffer.toString();
  }
  
  /// Get the voice to use (from current agent)
  String getVoice() {
    // TTS-1: alloy, echo, fable, onyx, nova, shimmer
    // Realtime: alloy, ash, ballad, coral, echo, sage, shimmer, verse
    const validVoices = ['alloy', 'ash', 'ballad', 'coral', 'echo', 'fable', 'nova', 'onyx', 'sage', 'shimmer', 'verse'];

    if (_currentAgent != null && _currentAgent!.voice.isNotEmpty) {
      final voice = _currentAgent!.voice.toLowerCase();
      if (validVoices.contains(voice)) {
        return voice;
      }
      debugPrint('⚠️ Invalid voice "$voice", using alloy');
    }
    return 'alloy';
  }
  
  ConversationState? _lastLoggedState;

  void _setState(ConversationState newState) {
    _state = newState;
    notifyListeners();
    onStateChange?.call(newState);  // Notify UI for face animations
    debugPrint('📍 Conversation state: ${newState.name}');

    // Fidget is controlled by movement state, not conversation state
    // See _updateFidgetState() for movement-based control

    // Log meaningful state transitions to activity feed
    if (_lastLoggedState != newState) {
      switch (newState) {
        case ConversationState.starting:
          addActivity('Conversation starting', type: ActivityType.state);
          break;
        case ConversationState.listening:
          if (_lastLoggedState == ConversationState.idle ||
              _lastLoggedState == ConversationState.starting) {
            addActivity('Listening...', type: ActivityType.state);
          }
          break;
        case ConversationState.processing:
          addActivity('Processing...', type: ActivityType.state);
          break;
        case ConversationState.complete:
          addActivity('Conversation ended', type: ActivityType.state);
          break;
        case ConversationState.cancelled:
          addActivity('Conversation cancelled', type: ActivityType.state);
          break;
        default:
          break;
      }
      _lastLoggedState = newState;
    }
  }
  
  void _reset() {
    _currentAction = null;
    _currentAgent = null;
    _actionCompleteHandled = false;
    _conversationPausedForGoAway = false;
    _pendingArrivalMessage = null;
    _pausedForTask = false;
    _workflowTools.clear();
    _setState(ConversationState.idle);
    debugPrint('🔄 Conversation fully reset');
  }

  @override
  void dispose() {
    rosBridge.removeAgentListener(_agentListener);
    rosBridge.removeActionListener(_actionListener);
    _activityController.close();
    _workflowTools.dispose();
    _fidgetService.dispose();
    _turnTakingPipeline.dispose();
    _realtimePipeline.dispose();
    super.dispose();
  }
}
