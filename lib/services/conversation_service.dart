import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/rosbridge.dart';
import 'voice_pipeline_service.dart';
import 'realtime_voice_service.dart';
import 'workflow_tools.dart';
import 'memory_tools.dart';

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

/// Manages AI conversation flow using STT → LLM → TTS pipeline
/// Supports two voice modes: turn_taking (default) and realtime (streaming)
class ConversationService extends ChangeNotifier {
  final RosBridge rosBridge;

  // Voice pipelines (two backends)
  late final VoicePipelineService _turnTakingPipeline;
  late final RealtimeVoiceService _realtimePipeline;
  late final WorkflowTools _workflowTools;
  late final MemoryTools _memoryTools;

  // Mode states (mutually exclusive: Wander, Follow, Patrol)
  bool _wanderOnlyActive = false;   // Wander mode: wander only, AI stays active
  bool _patrolModeActive = false;   // Patrol mode: wander + person detection
  bool _wasPatrollingBeforeConversation = false;
  bool _conversationPausedForPatrol = false;  // True if we paused an active conversation to patrol

  // Approach user state
  bool _approachingUser = false;

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


  // Callbacks for UI updates
  void Function(bool speaking)? onSpeakingChange;
  void Function(ConversationState state)? onStateChange;  // For face animations
  void Function(String text)? onBotText;
  void Function(String text)? onUserText;
  void Function(String status)? onStatus;
  void Function()? onPauseRequested;  // Called when user says "pause"
  
  ConversationService({required this.rosBridge}) {
    _workflowTools = WorkflowTools(rosBridge);
    _memoryTools = MemoryTools(rosBridge);
    _turnTakingPipeline = VoicePipelineService();
    _realtimePipeline = RealtimeVoiceService();

    _setupTurnTakingCallbacks();
    _setupRealtimeCallbacks();
    _setupRosBridgeCallbacks();
    _setupWorkflowCallbacks();
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
    };

    _turnTakingPipeline.onResponse = (text) {
      if (_activeVoiceMode != 'turn_taking') return;
      debugPrint('🤖 AI: $text');
      onBotText?.call(text);
    };

    _turnTakingPipeline.onSpeaking = (speaking) {
      if (_activeVoiceMode != 'turn_taking') return;
      onSpeakingChange?.call(speaking);
    };

    _turnTakingPipeline.onPauseRequested = () {
      if (_activeVoiceMode != 'turn_taking') return;
      debugPrint('⏸️ Pause requested via voice command');
      onPauseRequested?.call();
    };

    _turnTakingPipeline.onError = (error) {
      if (_activeVoiceMode != 'turn_taking') return;
      debugPrint('❌ Pipeline error: $error');
      onStatus?.call('Error: $error');
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
    };

    _realtimePipeline.onResponse = (text) {
      if (_activeVoiceMode != 'realtime') return;
      debugPrint('🤖 AI: $text');
      onBotText?.call(text);
    };

    _realtimePipeline.onSpeaking = (speaking) {
      if (_activeVoiceMode != 'realtime') return;
      onSpeakingChange?.call(speaking);
    };

    _realtimePipeline.onPauseRequested = () {
      if (_activeVoiceMode != 'realtime') return;
      debugPrint('⏸️ Pause requested via voice command');
      onPauseRequested?.call();
    };

    _realtimePipeline.onError = (error) {
      if (_activeVoiceMode != 'realtime') return;
      debugPrint('❌ Realtime error: $error');
      onStatus?.call('Error: $error');
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
    }

    // Check if we should resume patrol mode
    final shouldResumePatrol = _wasPatrollingBeforeConversation;
    _wasPatrollingBeforeConversation = false;

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

      // Resume patrol mode if we were patrolling before
      if (shouldResumePatrol) {
        debugPrint('🔍 Resuming patrol mode');
        startPatrolMode();
      }
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

    // Request data on startup
    rosBridge.requestAgents();
    rosBridge.requestActions();
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
      _resumeSilently();
    }
    // For succeeded: wait for action execute from workflow executor
  }

  /// Handle speak command from controller - robot speaks text out loud
  void _handleSpeakCommand(String text) {
    debugPrint('🔊 [ConversationService] Speaking from controller: $text');
    _turnTakingPipeline.speakText(text);
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

    // In patrol mode: trigger conversation when person detected within 3m
    if (_patrolModeActive && personDetected && !wasDetected) {
      if (distance != null && distance <= 3.0) {
        debugPrint('👤 Person detected at ${distance}m during patrol - starting conversation');
        _startConversationFromPatrol();
        return;
      }
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
      stopWanderOnly();
    };

    // Patrol mode callbacks (wander + person detection)
    _workflowTools.onPatrolModeStart = () {
      debugPrint('🔍 Patrol mode start requested');
      startPatrolMode();
    };

    _workflowTools.onPatrolModeStop = () {
      debugPrint('🛑 Patrol mode stop requested');
      stopPatrolMode();
    };

    _workflowTools.onGoAwayRequested = () {
      debugPrint('👋 Go away requested - pausing conversation for patrol');

      // Pause the conversation (keep session alive) instead of stopping
      if (_activeVoiceMode == 'realtime') {
        _realtimePipeline.pause();
      } else {
        _turnTakingPipeline.pause();
      }
      _conversationPausedForPatrol = true;

      // Start patrol mode (wander + person detection + sound detection)
      startPatrolMode();
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
  }

  // ===========================================================================
  // WANDER MODE: Wander only, AI stays active, robot keeps moving while talking
  // ===========================================================================

  /// Start wander mode - wander only, no person detection, AI stays active
  /// Robot can talk while moving - does NOT pause for conversation
  Future<void> startWanderOnly() async {
    debugPrint('🚶 Starting wander mode (wander only, AI active)');

    // Stop other modes first (mutual exclusivity)
    if (_patrolModeActive) {
      await stopPatrolMode();
    }

    _wanderOnlyActive = true;

    // Enable wander only (no person follower)
    rosBridge.activateWanderMode();

    // AI stays active - no changes to conversation state
    debugPrint('✅ Wander mode active - AI can still talk');
  }

  /// Stop wander mode
  Future<void> stopWanderOnly() async {
    debugPrint('🛑 Stopping wander mode');
    _wanderOnlyActive = false;

    // Disable wander
    rosBridge.deactivateWanderMode();
  }

  bool get isWanderOnlyActive => _wanderOnlyActive;

  // ===========================================================================
  // PATROL MODE: Wander + person detection, auto-engage on detection
  // ===========================================================================

  /// Start patrol mode - wander + person detection, auto-engage on detection
  Future<void> startPatrolMode() async {
    debugPrint('🔍 Starting patrol mode (wander + person detection)');

    // Stop other modes first (mutual exclusivity)
    if (_wanderOnlyActive) {
      await stopWanderOnly();
    }

    _patrolModeActive = true;

    // Enable wander and person follower
    rosBridge.activatePatrolMode();

    debugPrint('🔍 Patrol mode active - waiting for person detection');
  }

  /// Stop patrol mode
  Future<void> stopPatrolMode() async {
    debugPrint('🛑 Stopping patrol mode');
    _patrolModeActive = false;

    // Disable wander and person follower
    rosBridge.deactivatePatrolMode();
  }

  bool get isPatrolModeActive => _patrolModeActive;

  /// Called when person detection triggers conversation during patrol mode
  void _startConversationFromPatrol() async {
    // Remember we were patrolling (for resuming after conversation ends)
    _wasPatrollingBeforeConversation = true;
    _patrolModeActive = false;

    // Wander pauses automatically when person_follower detects someone
    // Person follower will approach and stop at follow distance

    _approachingUser = true;
    debugPrint('🚶 Person detected during patrol - starting conversation');

    // Check if we have a paused conversation to resume
    if (_conversationPausedForPatrol) {
      debugPrint('🔄 Resuming paused conversation from patrol');
      _conversationPausedForPatrol = false;
      await resumeConversation(greeting: "Hey there. How's it going?");
    } else {
      // Start fresh conversation with greeting
      debugPrint('🆕 Starting new conversation from patrol');
      await startDefaultConversation(withIntro: true);
    }
  }

  // Legacy getters for backward compatibility
  @Deprecated('Use isPatrolModeActive instead')
  bool get isSilentWanderActive => _patrolModeActive;

  @Deprecated('Use startPatrolMode() instead')
  Future<void> startSilentWander() => startPatrolMode();

  @Deprecated('Use stopPatrolMode() instead')
  Future<void> stopSilentWander() => stopPatrolMode();

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

    // Configure tool handlers - all actions get workflow + memory tools
    if (_activeVoiceMode == 'realtime') {
      _realtimePipeline.memoryToolsHandler = _memoryTools;
      _realtimePipeline.workflowToolsHandler = _workflowTools;
      debugPrint('🧭 [Realtime] Enabled: workflow + memory tools');
    } else {
      _turnTakingPipeline.memoryToolsHandler = _memoryTools;
      _turnTakingPipeline.workflowToolsHandler = _workflowTools;
      debugPrint('🧭 [TurnTaking] Enabled: workflow + memory tools');
    }

    debugPrint('🎬 Starting conversation: ${action.name}');

    // Build system prompt (uses agent if available)
    final systemPrompt = buildSystemPrompt();

    // Get greeting and apply template substitution
    String greeting = action.openingGreeting.isNotEmpty
        ? action.openingGreeting
        : 'Hello! How can I help you today?';
    greeting = _substituteTemplateVariables(greeting);

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
    onStatus?.call('Paused');
  }

  /// Resume the conversation with optional greeting
  Future<void> resumeConversation({String? greeting}) async {
    // Speak greeting before resuming if provided
    if (greeting != null && greeting.isNotEmpty) {
      final voice = getVoice();
      await _turnTakingPipeline.speakOnly(text: greeting, voice: voice);
    }

    if (_activeVoiceMode == 'realtime') {
      await _realtimePipeline.resume();
    } else {
      await _turnTakingPipeline.resume();
    }
    onStatus?.call('Resumed');
  }

  /// Inject a prompt to make the AI respond (realtime mode only)
  /// Used for motion detection, direction changes, etc.
  void injectPrompt(String prompt) {
    if (_activeVoiceMode == 'realtime' && _state != ConversationState.idle) {
      _realtimePipeline.injectPrompt(prompt);
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

    _setState(ConversationState.starting);

    // Determine voice mode from agent
    _activeVoiceMode = _currentAgent!.voiceMode.isNotEmpty ? _currentAgent!.voiceMode : 'turn_taking';
    debugPrint('🎙️ Voice mode: $_activeVoiceMode');

    // Configure tool handlers
    if (_activeVoiceMode == 'realtime') {
      _realtimePipeline.memoryToolsHandler = _memoryTools;
      _realtimePipeline.workflowToolsHandler = _workflowTools;
      debugPrint('🧭 [Realtime] All tools enabled');
    } else {
      _turnTakingPipeline.memoryToolsHandler = _memoryTools;
      _turnTakingPipeline.workflowToolsHandler = _workflowTools;
      debugPrint('🧭 [TurnTaking] All tools enabled');
    }

    // Build system prompt using agent personality
    final systemPrompt = buildSystemPrompt();

    // Get voice from agent
    final voice = getVoice();

    debugPrint('🗣️ Voice: $voice');

    // Get intro message from agent (if any) - only if withIntro is true
    String? introMessage;
    if (withIntro) {
      introMessage = _currentAgent?.introMessage;
      if (introMessage != null && introMessage.isNotEmpty) {
        debugPrint('👋 Intro message: $introMessage');
      }
    }

    // Start the appropriate pipeline
    if (_activeVoiceMode == 'realtime') {
      // For realtime: speak intro via TTS first, then start realtime
      if (introMessage != null && introMessage.isNotEmpty) {
        await _turnTakingPipeline.speakOnly(text: introMessage, voice: voice);
      }
      await _realtimePipeline.startConversation(
        systemPrompt: systemPrompt,
        voice: voice,
        greeting: introMessage,  // Added to history as context
      );
    } else {
      // For turn-taking: greeting is spoken by the pipeline
      await _turnTakingPipeline.startConversation(
        systemPrompt: systemPrompt,
        voice: voice,
        greeting: introMessage,
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

    debugPrint('💬 [ConversationService] Active voice mode: $_activeVoiceMode');

    // Simple flow: deliver message, then resume normal conversation
    if (_activeVoiceMode == 'realtime') {
      await _realtimePipeline.speakAndResume(message);
    } else {
      final voice = getVoice();
      await _turnTakingPipeline.speakOnly(text: message, voice: voice);
      _resumeSilently();
    }

    // Mark action as complete
    rosBridge.publishActionComplete(action.name, delivered: true);
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

    _reset();
  }
  
  /// Build the system prompt
  String buildSystemPrompt() {
    final buffer = StringBuffer();

    // Core role definition
    buffer.writeln('ROLE: You are a friendly robot assistant.');
    buffer.writeln('Be conversational and natural. Keep responses concise but expand when the topic warrants it.');
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
  
  void _setState(ConversationState newState) {
    _state = newState;
    notifyListeners();
    onStateChange?.call(newState);  // Notify UI for face animations
    debugPrint('📍 Conversation state: ${newState.name}');
  }
  
  void _reset() {
    _currentAction = null;
    _currentAgent = null;
    _actionCompleteHandled = false;
    _conversationPausedForPatrol = false;
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
    _workflowTools.dispose();
    _memoryTools.dispose();
    _turnTakingPipeline.dispose();
    _realtimePipeline.dispose();
    super.dispose();
  }
}
