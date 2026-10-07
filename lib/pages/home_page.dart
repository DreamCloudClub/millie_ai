import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../utils/rosbridge.dart';
import '../utils/robot_api.dart';
import '../widgets/icon_rail.dart';
import '../widgets/top_notification.dart';
import '../services/conversation_service.dart';
import '../services/location_service.dart';
import '../services/consciousness_service.dart';
import '../services/local_memory_service.dart';
import '../services/reminder_service.dart';
import '../services/local_cache_service.dart';
import '../services/planned_search_service.dart';
import 'settings_page.dart';
import 'locations_page.dart';
import 'launch_page.dart';
import 'face_page.dart';
import 'swipeable_conversation_page.dart';

// Top-level state that persists across all rebuilds
MainView? _persistedView;

/// Display mode for face tablet
enum DisplayMode { dashboard, face }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ROS bridge connection
  late RosBridge rosBridge;
  bool _rosbridgeConnected = false;

  // Robot API (boot server)
  late RobotApi robotApi;

  // AI Conversation service
  late ConversationService conversationService;

  // Reminder service (shared between AI and UI)
  late ReminderService reminderService;

  // Consciousness service
  late ConsciousnessService consciousnessService;

  // Local memory service
  late LocalMemoryService localMemoryService;

  // Planned search service
  late PlannedSearchService plannedSearchService;

  // Search state for UI
  bool _isSearchActive = false;
  String? _searchTarget;
  int _searchCoverage = 0;

  // Display mode (what's shown on screen)
  DisplayMode _displayMode = DisplayMode.dashboard;
  
  // Key for accessing SwipeableConversationPage state (which wraps FacePage)
  final GlobalKey<SwipeableConversationPageState> _faceKey = GlobalKey();

  // Use top-level persisted state with fallback defaults
  // Default to Launch page for the face tablet
  MainView get _currentView => _persistedView ?? MainView.launch;
  set _currentView(MainView view) => _persistedView = view;

  // Track current workflow state
  String _workflowStatus = 'idle';
  bool _orderInProgress = false;

  // Active agent info
  String _activeFaceId = '';
  String _activeAgentName = 'Millie';
  String _activeVoice = 'nova';
  String _activeVoiceMode = 'turn_taking';
  late final void Function(List<AgentDefinition>) _agentListener;

  @override
  void initState() {
    super.initState();
    robotApi = RobotApi("http://192.168.0.157:5050");
    rosBridge = RosBridge("ws://192.168.0.157:9090");

    // Initialize location service
    LocationService.instance.init(rosBridge);

    // Initialize consciousness service
    consciousnessService = ConsciousnessService();
    _initializeConsciousness();

    // Initialize local memory service
    localMemoryService = LocalMemoryService();
    _initializeLocalMemory();

    // Initialize reminder service (shared)
    reminderService = ReminderService();
    reminderService.init();

    // Initialize conversation service
    conversationService = ConversationService(rosBridge: rosBridge);
    conversationService.setConsciousnessService(consciousnessService);
    conversationService.setReminderService(reminderService);
    _setupConversationCallbacks();

    // Initialize planned search service
    plannedSearchService = PlannedSearchService(rosBridge: rosBridge);
    conversationService.setPlannedSearchService(plannedSearchService);
    _setupSearchCallbacks();
    
    // Listen for connection changes
    rosBridge.onConnectionChange = (connected) {
      if (mounted) {
        setState(() => _rosbridgeConnected = connected);
      }
    };
    
    // Listen for workflow status updates (multi-listener pattern)
    rosBridge.addWorkflowStatusListener(_handleWorkflowStatus);

    // Listen for agents to get active agent info
    _agentListener = (agents) {
      if (mounted && agents.isNotEmpty) {
        final activeAgent = agents.where((a) => a.isDefault).firstOrNull ?? agents.first;
        setState(() {
          _activeFaceId = activeAgent.faceId;
          _activeAgentName = activeAgent.name;
          _activeVoice = activeAgent.voice.isNotEmpty ? activeAgent.voice : 'nova';
          _activeVoiceMode = activeAgent.voiceMode.isNotEmpty ? activeAgent.voiceMode : 'turn_taking';
        });
      }
    };
    rosBridge.addAgentListener(_agentListener);

    // Listen for action execution requests
    rosBridge.onActionExecute = _handleActionExecute;

    // Listen for display commands from workflow
    rosBridge.onDisplayCommand = _handleDisplayCommand;

    // Listen for voice agent start from controller (play button)
    rosBridge.onVoiceAgentStart = () {
      debugPrint('🎤 Controller requested voice agent start');
      _launchFace();
    };

    // Listen for mode commands from controller (launch/play/pause buttons)
    rosBridge.onLaunch = () {
      debugPrint('🚀 Controller requested launch');
      _launchFace();
    };

    rosBridge.onPlay = () async {
      debugPrint('▶️ Controller requested play');
      if (_displayMode == DisplayMode.face) {
        if (conversationService.isPaused) {
          await conversationService.resumeConversation();
          _faceKey.currentState?.setPaused(false);
          rosBridge.publishVoicePlaying();
        } else if (conversationService.isIdle) {
          await conversationService.startDefaultConversation();
          _faceKey.currentState?.setPaused(false);
          rosBridge.publishVoicePlaying();
        }
      } else {
        // Not on face yet - show face and start AI
        setState(() => _displayMode = DisplayMode.face);
        await conversationService.startDefaultConversation();
        _faceKey.currentState?.setPaused(false);
        rosBridge.publishVoicePlaying();
      }
    };

    rosBridge.onPause = () {
      debugPrint('⏸️ Controller requested pause');
      // Pause search on pause/E-STOP
      if (plannedSearchService.isSearching && !plannedSearchService.isPaused) {
        plannedSearchService.pause();
      }
      if (_displayMode == DisplayMode.face) {
        conversationService.pauseConversation();
        _faceKey.currentState?.setPaused(true);
        rosBridge.publishVoicePaused();
      }
    };

    rosBridge.onStart = () {
      debugPrint('▶️ Controller requested start (silent)');
      _startFace();
    };

    rosBridge.onExit = () async {
      debugPrint('🚪 Controller requested exit');
      await conversationService.cancelConversation();
      rosBridge.publishVoiceIdle();
      setState(() => _displayMode = DisplayMode.dashboard);
    };

    rosBridge.onRefresh = () async {
      debugPrint('🔄 Controller requested refresh');
      await conversationService.cancelConversation();
      rosBridge.publishWorkflowCancel();
      rosBridge.publishVoiceIdle();
    };

    rosBridge.onWanderStart = () {
      debugPrint('🚶 Controller requested wander mode start');
      // Show face if not already showing
      if (_displayMode != DisplayMode.face) {
        setState(() => _displayMode = DisplayMode.face);
      }
      // Controller wander button triggers wander mode
      conversationService.startWander();
    };

    rosBridge.onWanderStop = () {
      debugPrint('🛑 Controller requested wander mode stop');
      conversationService.stopWander();
    };

    // Search commands from controller
    rosBridge.onSearchStart = () {
      debugPrint('🔍 Controller requested search start');
      // Show face if not already showing
      if (_displayMode != DisplayMode.face) {
        setState(() => _displayMode = DisplayMode.face);
      }
      // Trigger AI to prompt for search target
      _handleSearchStart();
    };

    rosBridge.onSearchStop = () {
      debugPrint('🛑 Controller requested search stop');
      plannedSearchService.stopSearch();
    };

    // Motion detector status - inject prompts in realtime mode
    rosBridge.onMotionDetectorStatus = (status) {
      if (!conversationService.isActive || conversationService.voiceMode != 'realtime') return;

      switch (status) {
        case 'approaching':
          conversationService.injectPrompt('You just noticed someone moving nearby. Call out to them in a friendly way and start a conversation as you approach.');
          break;
        case 'arrived':
          conversationService.injectPrompt('You have arrived in front of the person. Greet them warmly.');
          break;
        case 'lost':
          conversationService.injectPrompt('The person you were approaching seems to have moved away. Express mild confusion and mention you lost track of them.');
          break;
      }
    };

    // Wander status - inject prompts in realtime mode
    rosBridge.onWanderStatus = (status) {
      if (!conversationService.isActive || conversationService.voiceMode != 'realtime') return;

      switch (status) {
        case 'searching':
          conversationService.injectPrompt('You heard a voice and are looking around. Say something like you are trying to find who spoke.');
          break;
      }
    };

    // Limiter status - inject prompts when blocked by obstacle
    rosBridge.onLimiterStatus = (status) {
      if (!conversationService.isActive || conversationService.voiceMode != 'realtime') return;

      if (status == 'blocked') {
        conversationService.injectPrompt('You hit an obstacle and had to stop. Make a brief comment like "Oops!" or "Something is in the way."');
      }
    };

    // Load cached data first, then connect to ROSBridge
    _initializeRosBridge();
  }

  Future<void> _initializeRosBridge() async {
    // Load cached data first so UI shows immediately
    await rosBridge.loadFromCache();
    // Then try to connect to ROS (will overwrite cache with fresh data if connected)
    rosBridge.connect();
  }

  Future<void> _initializeConsciousness() async {
    await consciousnessService.initialize();

    // Share API key with consciousness service and planned search
    final apiKey = await LocalCacheService.loadOpenAIApiKey();
    if (apiKey != null && apiKey.isNotEmpty) {
      ConsciousnessService.setApiKey(apiKey);
      PlannedSearchService.setApiKey(apiKey);
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initializeLocalMemory() async {
    await localMemoryService.initialize();
    // Connect to consciousness service for storing memories during reflection
    consciousnessService.setLocalMemoryService(localMemoryService);
    if (mounted) {
      setState(() {});
    }
  }

  void _setupSearchCallbacks() {
    // NOTE: Most callbacks are set in conversationService.setPlannedSearchService()
    // We only set onStatusChange here for UI state updates and publishing to controller.
    // Do NOT set onProgress, onTargetPendingVerification, onTargetConfirmed, onSearchEnd,
    // or onError here - those are handled by conversation_service for speaking/verification.

    plannedSearchService.onStatusChange = (status) {
      debugPrint('🔍 [HomePage] Search status changed: $status');
      // Publish status to controller tablet
      rosBridge.publishSearchStatus(status);
      if (mounted) {
        setState(() {
          _isSearchActive = status == 'searching' || status == 'paused' || status == 'pending_verification';
          _searchTarget = plannedSearchService.searchTarget;
          _searchCoverage = plannedSearchService.coveragePercent.round();
        });
      }
    };
  }

  /// Handle search start request (from controller or UI button)
  void _handleSearchStart() {
    // Inject prompt so AI asks what to search for and uses start_search tool
    conversationService.injectPrompt('User pressed search button. Ask what they want you to find, then use start_search tool with their answer.');
  }

  void _setupConversationCallbacks() {
    conversationService.onSpeakingChange = (speaking) {
      setSpeaking(speaking);
    };
    
    // Handle face animations based on conversation state
    conversationService.onStateChange = (state) {
      debugPrint('📍 State change: ${state.name}');
      switch (state) {
        case ConversationState.listening:
          _faceKey.currentState?.setIdle(false);
          _faceKey.currentState?.setListening(true);
          _faceKey.currentState?.setProcessing(false);
          _faceKey.currentState?.setSpeaking(false);
          rosBridge.publishVoicePlaying();
          break;
        case ConversationState.processing:
          _faceKey.currentState?.setIdle(false);
          _faceKey.currentState?.setListening(false);
          _faceKey.currentState?.setProcessing(true);
          _faceKey.currentState?.setSpeaking(false);
          break;
        case ConversationState.speaking:
          _faceKey.currentState?.setIdle(false);
          _faceKey.currentState?.setListening(false);
          _faceKey.currentState?.setProcessing(false);
          _faceKey.currentState?.setSpeaking(true);
          break;
        case ConversationState.starting:
        case ConversationState.greeting:
          _faceKey.currentState?.setIdle(false);
          _faceKey.currentState?.setListening(false);
          _faceKey.currentState?.setProcessing(false);
          rosBridge.publishVoicePlaying();
          // Pause search during conversation
          if (plannedSearchService.isSearching && !plannedSearchService.isPaused) {
            debugPrint('🔍 Conversation starting - pausing search');
            plannedSearchService.pause();
          }
          break;
        case ConversationState.idle:
        case ConversationState.complete:
        case ConversationState.cancelled:
          _faceKey.currentState?.setIdle(true);
          _faceKey.currentState?.setListening(false);
          _faceKey.currentState?.setProcessing(false);
          // Close thought bubble when conversation ends
          closeThoughtBubble();
          _orderInProgress = false;
          rosBridge.publishVoiceIdle();
          // Resume search when conversation ends
          if (plannedSearchService.isSearching && plannedSearchService.isPaused) {
            debugPrint('🔍 Conversation ended - resuming search');
            plannedSearchService.resume();
          }
          break;
      }
    };
    
    // TTS is now handled directly by AiService via WebRTC
    conversationService.onBotText = (text) {
      debugPrint('🤖 Bot said: $text');
    };
    
    conversationService.onUserText = (text) {
      debugPrint('🎤 User said: $text');
    };
    
    // Handle voice command "pause"
    conversationService.onPauseRequested = () {
      debugPrint('⏸️ Voice pause command - updating UI');
      _faceKey.currentState?.setPaused(true);
      rosBridge.publishVoicePaused();
    };

    // Handle AI requesting page navigation
    conversationService.onShowPage = (page) {
      debugPrint('📺 AI requested page: $page');
      _handleShowPage(page);
    };

    // Handle AI requesting to open a specific note
    conversationService.onOpenNote = (noteId) {
      debugPrint('📝 AI requested open note: $noteId');
      _handleOpenNote(noteId);
    };
  }
  
  /// Handle action execution from workflow
  void _handleActionExecute(ActionDefinition action) {
    debugPrint('🎯 Executing action: ${action.name}');
    debugPrint('🎯 Action greeting: ${action.openingGreeting}');
    debugPrint('🎯 isPausedForTask: ${conversationService.isPausedForTask}');

    // Make sure we're in face mode
    if (_displayMode != DisplayMode.face) {
      _launchFace();
    }

    // Always use handleTaskAction - it speaks directly via TTS
    // This is more reliable than startConversation which has complex pipeline logic
    conversationService.handleTaskAction(action);
  }

  /// Handle display commands from workflow
  void _handleDisplayCommand(String displayName) {
    debugPrint('📺 Display command received: "$displayName" (current mode: $_displayMode)');

    if (!mounted) {
      debugPrint('📺 WARNING: Not mounted, ignoring command');
      return;
    }

    // Pop any pushed routes before handling display commands
    if (Navigator.of(context).canPop()) {
      debugPrint('📺 Popping overlay routes to show display');
      Navigator.of(context).popUntil((route) => route.isFirst);
    }

    // Handle different display commands
    switch (displayName) {
      case 'Show Face':
        debugPrint('📺 Handling Show Face command');
        _launchFace();
        break;
      default:
        // Unknown display - show face by default
        debugPrint('📺 Unknown display "$displayName" - showing face');
        if (_displayMode != DisplayMode.face) {
          _launchFace();
        }
        break;
    }
  }

  /// Handle AI page navigation requests
  void _handleShowPage(String page) {
    if (!mounted) return;

    // Pop any overlay pages (like NoteViewPage) first
    Navigator.of(context).popUntil((route) => route.isFirst);

    // Make sure we're in face mode first (which contains the swipeable pages)
    if (_displayMode != DisplayMode.face) {
      _launchFace();
    }

    // Navigate to the requested page within the swipeable conversation page
    switch (page) {
      case 'dashboard':
        _faceKey.currentState?.navigateToPage(SwipeableConversationPageState.dashboardPageIndex);
        break;
      case 'face':
        _faceKey.currentState?.navigateToPage(SwipeableConversationPageState.facePageIndex);
        break;
      case 'notes':
        _faceKey.currentState?.navigateToPage(SwipeableConversationPageState.notesPageIndex);
        break;
      case 'schedule':
        _faceKey.currentState?.navigateToPage(SwipeableConversationPageState.schedulePageIndex);
        break;
      default:
        debugPrint('📺 Unknown page: $page');
    }
  }

  /// Handle AI request to open a specific note
  void _handleOpenNote(String noteId) {
    if (!mounted) return;

    // Pop any overlay pages first
    Navigator.of(context).popUntil((route) => route.isFirst);

    // Make sure we're in face mode first
    if (_displayMode != DisplayMode.face) {
      _launchFace();
    }

    // Navigate to notes page and open the specific note
    _faceKey.currentState?.navigateToPage(SwipeableConversationPageState.notesPageIndex);
    // Small delay to let page navigation complete before opening the note
    Future.delayed(const Duration(milliseconds: 100), () {
      _faceKey.currentState?.openNote(noteId);
    });
  }

  /// Handle workflow status changes from robot
  void _handleWorkflowStatus(String status, int step, int total, List<Map<String, dynamic>>? steps) {
    debugPrint('📋 Workflow: $status (step $step/$total)');
    
    if (!mounted) return;
    
    final previousStatus = _workflowStatus;
    setState(() => _workflowStatus = status);
    
    // Sync workflow state and steps to LocationsPage static state
    // This ensures locations_page has data even when not mounted
    if (status == 'started' || status == 'progress' || status == 'action' || status == 'display') {
      LocationsPage.workflowState = WorkflowState.running;
    } else if (status == 'complete') {
      LocationsPage.workflowState = WorkflowState.editing;
      LocationsPage.currentStep = 0;
      LocationsPage.stepOffset = 0;
    } else if (status == 'cancelled') {
      LocationsPage.workflowState = WorkflowState.stopped;
    }
    LocationsPage.currentStep = step + LocationsPage.stepOffset;
    LocationsPage.totalSteps = total + LocationsPage.stepOffset;
    
    // Populate task steps when workflow starts (so locations_page has data even when not mounted)
    if (status == 'started' && steps != null && steps.isNotEmpty) {
      LocationsPage.taskSteps.clear();
      for (final stepData in steps) {
        final type = stepData['type'] as String? ?? '';
        final value = stepData['value'] as String? ?? '';
        
        StepType stepType;
        switch (type) {
          case 'navigate':
            stepType = StepType.navigate;
            break;
          case 'action':
            stepType = StepType.prompt;
            break;
          case 'display':
            stepType = StepType.display;
            break;
          default:
            stepType = StepType.navigate;
        }
        
        LocationsPage.taskSteps.add(TaskStep(
          type: stepType,
          value: value,
          label: value,
        ));
      }
      debugPrint('📥 home_page synced task steps: ${LocationsPage.taskSteps.length} steps');
    } else if (status == 'complete') {
      LocationsPage.taskSteps.clear();
    }
    
    // Auto-launch face when workflow starts
    if (status == 'started') {
      // Disable follow/track mode - task takes priority over autonomous behaviors
      rosBridge.publishPersonFollower(false);
      rosBridge.publishCenterOnHuman(false);

      if (_displayMode == DisplayMode.dashboard) {
        _launchFace();
      }
    }
    
    // TODO: When we add AI conversation, open thought bubble on 'action' step type
    // For now, this will be triggered by a separate topic from the AI service
    
    // When workflow completes, just close thought bubble but stay on face
    // Face page stays active until a Display command changes it
    if (status == 'complete' || status == 'cancelled' || status == 'error') {
      if (_orderInProgress) {
        _orderInProgress = false;
        // Keep bubble open briefly to show final order, then close it
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            closeThoughtBubble();
          }
        });
      }
    }
  }
  
  /// Called by AI service when order recording starts
  void startRecordingOrder() {
    if (!_orderInProgress) {
      _orderInProgress = true;
      openThoughtBubble();
    }
  }
  
  /// Called by AI service when speaking
  void onAISpeaking(bool speaking) {
    setSpeaking(speaking);
  }
  
  void _onRosStarted(String mode) {
    // Connect to rosbridge once ROS is running
    Future.delayed(const Duration(seconds: 3), () {
      rosBridge.connect();
    });
  }

  @override
  void dispose() {
    rosBridge.removeWorkflowStatusListener(_handleWorkflowStatus);
    rosBridge.removeAgentListener(_agentListener);
    plannedSearchService.dispose();
    rosBridge.close();
    super.dispose();
  }

  void _handleEstop() {
    debugPrint("🔴 E-STOP pressed!");
    rosBridge.publishEstop();

    // Stop planned search
    if (plannedSearchService.isSearching) {
      plannedSearchService.stopSearch();
    }

    // Stop conversation and fidget movements
    if (conversationService.isActive) {
      conversationService.pauseConversation();
    }

    // Exit to dashboard on E-STOP
    if (_displayMode != DisplayMode.dashboard) {
      setState(() => _displayMode = DisplayMode.dashboard);
    }

    TopNotification.show(
      context,
      message: '🛑 E-STOP ACTIVATED',
      backgroundColor: AppColors.danger,
      duration: const Duration(seconds: 3),
    );
  }

  void _handleShutdown() async {
    debugPrint("⚡ Power shutdown confirmed");
    final result = await robotApi.shutdown();
    TopNotification.show(
      context,
      message: result.success ? '🔌 Robot shutting down...' : '❌ Shutdown failed',
      backgroundColor: result.success ? AppColors.warning : AppColors.danger,
    );
  }

  void _handleReboot() async {
    debugPrint("🔄 Reboot confirmed");
    final result = await robotApi.reboot();
    TopNotification.show(
      context,
      message: result.success ? '🔄 Robot rebooting...' : '❌ Reboot failed',
      backgroundColor: result.success ? AppColors.warning : AppColors.danger,
    );
  }

  void _launchFace() {
    debugPrint('🎭 _launchFace() called');

    setState(() => _displayMode = DisplayMode.face);

    // Small delay to ensure face widget is mounted before speaking
    Future.delayed(const Duration(milliseconds: 100), () {
      // Launch runs startup sequence (motion test only, no speech)
      // Does NOT start conversation - user presses Play for that
      debugPrint('🚀 Running startup sequence');
      conversationService.runStartupSequence(
        onComplete: () {
          debugPrint('✅ Startup complete - ready state (press Play to start conversation)');
          // Don't start conversation - just stay in ready state
        },
      );
    });
  }

  void _startFace() {
    debugPrint('▶️ _startFace() called - quick start with short intro');

    setState(() => _displayMode = DisplayMode.face);

    // Small delay to ensure face widget is mounted before speaking
    Future.delayed(const Duration(milliseconds: 100), () {
      // Quick start with short intro (no motion test)
      conversationService.runQuickStart(
        onComplete: () {
          debugPrint('✅ Quick start complete - ready state');
        },
      );
    });
  }

  Future<void> _playFace() async {
    debugPrint('▶️ _playFace() called - start/resume AI');

    // If already in face mode, just start/resume conversation
    if (_displayMode != DisplayMode.face) {
      setState(() => _displayMode = DisplayMode.face);
    }

    // Start or resume AI conversation
    if (conversationService.isPaused) {
      debugPrint('▶️ Resuming conversation');
      await conversationService.resumeConversation();
      _faceKey.currentState?.setPaused(false);
      rosBridge.publishVoicePlaying();
    } else if (conversationService.isIdle) {
      debugPrint('▶️ Starting new conversation');
      await conversationService.startDefaultConversation();
      _faceKey.currentState?.setPaused(false);
      rosBridge.publishVoicePlaying();
    }
  }

  Future<void> _exitToLaunch() async {
    // Stop search if active
    if (plannedSearchService.isSearching) {
      plannedSearchService.stopSearch();
    }

    // Stop AI conversation and clear context
    await conversationService.cancelConversation();
    conversationService.resetTokenTracking();
    conversationService.clearActivityLog();
    rosBridge.publishVoiceIdle();
    setState(() => _displayMode = DisplayMode.dashboard);
  }

  /// Open the thought bubble
  void openThoughtBubble() {
    _faceKey.currentState?.openThoughtBubble();
  }

  /// Close thought bubble and restore face
  void closeThoughtBubble() {
    _faceKey.currentState?.closeThoughtBubble();
  }

  /// Add a processed order item (from LLM)
  void addOrderItem(String item) {
    _faceKey.currentState?.addOrderItem(item);
  }

  /// Set mouth speaking state
  void setSpeaking(bool speaking) {
    _faceKey.currentState?.setSpeaking(speaking);
  }

  @override
  Widget build(BuildContext context) {
    // Face mode - standalone (customer-facing) with swipeable consciousness page
    if (_displayMode == DisplayMode.face) {
      return SwipeableConversationPage(
        key: _faceKey,
        rosBridge: rosBridge,
        robotApi: robotApi,
        conversationService: conversationService,
        consciousnessService: consciousnessService,
        localMemoryService: localMemoryService,
        reminderService: reminderService,
        plannedSearchService: plannedSearchService,
        isSearchActive: _isSearchActive,
        searchTarget: _searchTarget,
        searchCoverage: _searchCoverage,
        faceId: _activeFaceId,
        agentName: _activeAgentName,
        voice: _activeVoice,
        voiceMode: _activeVoiceMode,
        onExit: _exitToLaunch,
        onPause: () {
          debugPrint('⏸️ Pausing voice (movement modes unaffected)');
          conversationService.pauseConversation();
          _faceKey.currentState?.setPaused(true);
          rosBridge.publishVoicePaused();
          // Note: Movement modes (wander, follow) are independent
          // Use stop_robot voice command or controller buttons to stop movement
        },
        onPlay: () async {
          debugPrint('▶️ Play pressed');
          if (conversationService.isPaused) {
            debugPrint('▶️ Resuming paused conversation');
            await conversationService.resumeConversation();
            _faceKey.currentState?.setPaused(false);
            rosBridge.publishVoicePlaying();
          } else if (conversationService.isIdle) {
            debugPrint('🎯 Starting default conversation');
            await conversationService.startDefaultConversation();
          }
        },
        onRefresh: () async {
          debugPrint('🔄 Refresh pressed - cancelling conversation');
          await conversationService.cancelConversation();
          conversationService.resetTokenTracking();
          rosBridge.publishWorkflowCancel();
        },
      );
    }
    
    // Normal dashboard mode - portrait layout with bottom nav
    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            // Top header bar (persistent)
            _buildTopBar(),
            // Main content area
            Expanded(
              child: Container(
                padding: const EdgeInsets.only(
                  left: AppSpacing.xs,
                  right: AppSpacing.xs,
                  bottom: AppSpacing.xs,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  child: _buildMainContent(),
                ),
              ),
            ),
            // Bottom navigation bar
            IconRail(
              selectedView: _currentView,
              onViewChanged: (view) => setState(() => _currentView = view),
              onEstop: _handleEstop,
              onShutdown: _handleShutdown,
              onReboot: _handleReboot,
              rosConnected: _rosbridgeConnected,
              onSettingsSidebarToggle: () {
                SettingsPage.toggleSidebar();
                setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      color: AppColors.background,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left: Millie Bot AI
          const Text(
            'Millie Bot AI',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          // Center: Logo in blue rounded square
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.2),
              borderRadius: BorderRadius.circular(AppRadius.small),
              border: Border.all(color: AppColors.accent, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.small - 2),
              child: Image.asset(
                'assets/icon/logo.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
          // Right: Dream Cloud
          const Text(
            'Dream Cloud',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    switch (_currentView) {
      case MainView.locations:
        return LocationsPage(rosBridge: rosBridge);
      case MainView.launch:
        return LaunchPage(
          rosBridge: rosBridge,
          onLaunch: _launchFace,
          onStart: _startFace,
        );
      case MainView.settings:
        return SettingsPage(
          rosBridge: rosBridge,
          robotApi: robotApi,
          consciousnessService: consciousnessService,
          onModeStarted: _onRosStarted,
        );
    }
  }
}
