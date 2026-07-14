import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../utils/rosbridge.dart';
import '../utils/robot_api.dart';
import '../widgets/icon_rail.dart';
import '../widgets/top_notification.dart';
import '../services/conversation_service.dart';
import '../services/location_service.dart';
import 'settings_page.dart';
import 'locations_page.dart';
import 'launch_page.dart';
import 'face_page.dart';

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
  
  // Display mode (what's shown on screen)
  DisplayMode _displayMode = DisplayMode.dashboard;
  
  // Key for accessing FacePage state
  final GlobalKey<FacePageState> _faceKey = GlobalKey();

  // Use top-level persisted state with fallback defaults
  // Default to Launch page for the face tablet
  MainView get _currentView => _persistedView ?? MainView.launch;
  set _currentView(MainView view) => _persistedView = view;

  // Track current workflow state
  String _workflowStatus = 'idle';
  bool _orderInProgress = false;

  // Active agent face
  String _activeFaceId = '';
  late final void Function(List<AgentDefinition>) _agentListener;

  @override
  void initState() {
    super.initState();
    robotApi = RobotApi("http://192.168.0.157:5050");
    rosBridge = RosBridge("ws://192.168.0.157:9090");
    
    // Initialize location service
    LocationService.instance.init(rosBridge);
    
    // Initialize conversation service
    conversationService = ConversationService(rosBridge: rosBridge);
    _setupConversationCallbacks();
    
    // Listen for connection changes
    rosBridge.onConnectionChange = (connected) {
      if (mounted) {
        setState(() => _rosbridgeConnected = connected);
      }
    };
    
    // Listen for workflow status updates (multi-listener pattern)
    rosBridge.addWorkflowStatusListener(_handleWorkflowStatus);

    // Listen for agents to get active face
    _agentListener = (agents) {
      if (mounted && agents.isNotEmpty) {
        final activeAgent = agents.where((a) => a.isDefault).firstOrNull ?? agents.first;
        setState(() => _activeFaceId = activeAgent.faceId);
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
          await conversationService.resumeConversation(greeting: "I'm back! What did I miss?");
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
      debugPrint('🔍 Controller requested patrol mode start');
      // Show face if not already showing
      if (_displayMode != DisplayMode.face) {
        setState(() => _displayMode = DisplayMode.face);
      }
      // Controller wander button triggers patrol mode (wander + person detection)
      conversationService.startPatrolMode();
    };

    rosBridge.onWanderStop = () {
      debugPrint('🛑 Controller requested patrol mode stop');
      conversationService.stopPatrolMode();
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
    rosBridge.close();
    super.dispose();
  }

  void _handleEstop() {
    debugPrint("🔴 E-STOP pressed!");
    rosBridge.publishEstop();
    
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

    // Launch runs startup sequence (motion test only, no speech)
    // Does NOT start conversation - user presses Play for that
    debugPrint('🚀 Running startup sequence');
    conversationService.runStartupSequence(
      onComplete: () {
        debugPrint('✅ Startup complete - ready state (press Play to start conversation)');
        // Don't start conversation - just stay in ready state
      },
    );
  }

  void _startFace() {
    debugPrint('▶️ _startFace() called - quick start with short intro');

    setState(() => _displayMode = DisplayMode.face);

    // Quick start with short intro (no motion test)
    conversationService.runQuickStart(
      onComplete: () {
        debugPrint('✅ Quick start complete - ready state');
      },
    );
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
    // Stop AI conversation and clear context
    await conversationService.cancelConversation();
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
    // Face mode - standalone (customer-facing)
    if (_displayMode == DisplayMode.face) {
      return FacePage(
        key: _faceKey,
        rosBridge: rosBridge,
        faceId: _activeFaceId,
        onExit: _exitToLaunch,
        onPause: () {
          debugPrint('⏸️ Pausing voice (movement modes unaffected)');
          conversationService.pauseConversation();
          _faceKey.currentState?.setPaused(true);
          rosBridge.publishVoicePaused();
          // Note: Movement modes (wander, follow, patrol) are independent
          // Use stop_robot voice command or controller buttons to stop movement
        },
        onPlay: () async {
          debugPrint('▶️ Play pressed');
          if (conversationService.isPaused) {
            debugPrint('▶️ Resuming paused conversation');
            await conversationService.resumeConversation(greeting: "I'm back! What did I miss?");
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
          onModeStarted: _onRosStarted,
        );
    }
  }
}
