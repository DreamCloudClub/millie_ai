import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../utils/rosbridge.dart';
import '../utils/robot_api.dart';
import '../widgets/icon_rail.dart';
import '../widgets/top_notification.dart';
import '../services/conversation_service.dart';
import '../services/location_service.dart';
import '../services/wake_service.dart';
import '../models/ticket.dart';
import 'settings_page.dart';
import 'locations_page.dart';
import 'launch_page.dart';
import 'order_display_page.dart';
import 'tickets_page.dart';
import 'ticket_view_page.dart';

// Top-level state that persists across all rebuilds
MainView? _persistedView;

/// Display mode for face tablet
enum DisplayMode { dashboard, face, tickets }

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
  
  // Key for accessing OrderDisplayPage state
  final GlobalKey<OrderDisplayPageState> _orderDisplayKey = GlobalKey();
  
  // Key for accessing TicketsPage state
  final GlobalKey<TicketsPageState> _ticketsKey = GlobalKey();
  
  // Current ticket (last created, for "Display Current Ticket")
  Ticket? _currentTicket;
  
  // PageController for Face/Tickets swipe navigation
  late PageController _faceTicketsController;
  
  // Use top-level persisted state with fallback defaults
  // Default to Launch page for the face tablet
  MainView get _currentView => _persistedView ?? MainView.launch;
  set _currentView(MainView view) => _persistedView = view;

  // Track current workflow state
  String _workflowStatus = 'idle';
  bool _orderInProgress = false;

  @override
  void initState() {
    super.initState();
    robotApi = RobotApi("http://192.168.1.14:5050");
    rosBridge = RosBridge("ws://192.168.1.14:9090");
    
    // Initialize PageController (Face = 0, Tickets = 1)
    _faceTicketsController = PageController(initialPage: 0);
    
    // Initialize location service for ticket creation
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
    
    // Listen for action execution requests
    rosBridge.onActionExecute = _handleActionExecute;
    
    // Listen for display commands from workflow
    rosBridge.onDisplayCommand = _handleDisplayCommand;
    
    // Try to connect to ROSBridge immediately
    rosBridge.connect();
    
    // Initialize wake word detection
    _initWakeService();
  }
  
  Future<void> _initWakeService() async {
    try {
      await WakeService.instance.init(
        onWake: () async {
          // Debug: log current state
          debugPrint('🎤 Wake word detected!');
          debugPrint('   isPaused: ${conversationService.isPaused}');
          debugPrint('   isIdle: ${conversationService.isIdle}');
          debugPrint('   state: ${conversationService.state}');
          
          // Wake word behavior:
          // - Paused → Resume listening (no greeting)
          // - Idle → Start new conversation (with greeting)
          if (conversationService.isPaused) {
            // Resume paused conversation - just start listening again
            debugPrint('🎤 → Resuming paused conversation');
            await conversationService.resumeConversation();
            _orderDisplayKey.currentState?.setPaused(false);
          } else if (conversationService.isIdle) {
            // Start new conversation with greeting
            debugPrint('🎤 → Starting default conversation');
            await conversationService.startDefaultConversation();
          } else {
            debugPrint('🎤 → Ignoring (active conversation)');
          }
        },
      );
      debugPrint('✅ Wake service initialized');
    } catch (e) {
      debugPrint('⚠️ Wake service init failed: $e');
    }
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
          _orderDisplayKey.currentState?.setIdle(false);
          _orderDisplayKey.currentState?.setListening(true);
          _orderDisplayKey.currentState?.setProcessing(false);
          _orderDisplayKey.currentState?.setSpeaking(false);
          // Stop wake word when conversation is active
          WakeService.instance.stop();
          break;
        case ConversationState.processing:
          _orderDisplayKey.currentState?.setIdle(false);
          _orderDisplayKey.currentState?.setListening(false);
          _orderDisplayKey.currentState?.setProcessing(true);
          _orderDisplayKey.currentState?.setSpeaking(false);
          break;
        case ConversationState.speaking:
          _orderDisplayKey.currentState?.setIdle(false);
          _orderDisplayKey.currentState?.setListening(false);
          _orderDisplayKey.currentState?.setProcessing(false);
          _orderDisplayKey.currentState?.setSpeaking(true);
          break;
        case ConversationState.starting:
        case ConversationState.greeting:
          _orderDisplayKey.currentState?.setIdle(false);
          _orderDisplayKey.currentState?.setListening(false);
          _orderDisplayKey.currentState?.setProcessing(false);
          // Stop wake word when conversation is starting
          WakeService.instance.stop();
          break;
        case ConversationState.idle:
        case ConversationState.complete:
        case ConversationState.cancelled:
          _orderDisplayKey.currentState?.setIdle(true);
          _orderDisplayKey.currentState?.setListening(false);
          _orderDisplayKey.currentState?.setProcessing(false);
          // Close thought bubble when conversation ends
          closeThoughtBubble();
          _orderInProgress = false;
          // Restart wake word when idle and on face page (delay for mic release)
          if (_displayMode == DisplayMode.face) {
            Future.delayed(const Duration(milliseconds: 500), () {
              WakeService.instance.start();
            });
          }
          break;
      }
    };
    
    conversationService.onOrderStarted = () {
      startRecordingOrder();
    };
    
    conversationService.onOrderItemAdded = (item) {
      addOrderItem(item);
    };
    
    conversationService.onOrderComplete = (ticket) {
      // Add to tickets list
      _ticketsKey.currentState?.addTicket(ticket);
      // Store as current ticket for "Display Current Ticket" command
      _currentTicket = ticket;
      debugPrint('✅ Ticket created: ${ticket.title}');
      // Close thought bubble - order is complete
      closeThoughtBubble();
      _orderInProgress = false;
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
      _orderDisplayKey.currentState?.setPaused(true);
      // Start wake word so "Hey Millie" can resume
      WakeService.instance.start();
    };
  }
  
  /// Handle action execution from workflow
  void _handleActionExecute(ActionDefinition action, Ticket? ticket) {
    debugPrint('🎯 Executing action: ${action.name}');
    if (ticket != null) {
      debugPrint('📦 With ticket: ${ticket.title} (${ticket.items.length} items)');
    }
    
    // Make sure we're in face mode
    if (_displayMode != DisplayMode.face) {
      _launchFace();
    }
    
    // Start the conversation with optional ticket context
    conversationService.startConversation(action, ticket: ticket);
  }

  /// Handle display commands from workflow
  void _handleDisplayCommand(String displayName) {
    debugPrint('📺 Display command received: "$displayName" (current mode: $_displayMode)');
    
    if (!mounted) {
      debugPrint('📺 WARNING: Not mounted, ignoring command');
      return;
    }
    
    // Pop any pushed routes (like TicketViewPage) before handling display commands
    if (Navigator.of(context).canPop()) {
      debugPrint('📺 Popping overlay routes to show display');
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    
    // Handle different display commands
    switch (displayName) {
      case 'Show Face':
        // Explicit face display command
        debugPrint('📺 Handling Show Face command');
        _launchFace();  // Always call - it handles the animation
        break;
      case 'Display Tickets':
        _showTickets();
        break;
      case 'Display Current Ticket':
        _showCurrentTicket();
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
  
  /// Show the current ticket (last created during workflow)
  void _showCurrentTicket() {
    if (_currentTicket == null) {
      debugPrint('⚠️ No current ticket to display');
      // Fall back to tickets list
      _showTickets();
      return;
    }
    
    // Reset conversation service state - workflow is done, ticket is saved
    debugPrint('📋 Displaying current ticket - resetting conversation state');
    conversationService.cancelConversation();
    
    // Navigate to ticket view page
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => TicketViewPage(
          ticket: _currentTicket!,
          rosBridge: rosBridge,
          onExit: () {
            debugPrint('🚪 Exit from ticket view - current displayMode: $_displayMode');
            Navigator.of(context).pop();
            debugPrint('🚪 After pop, calling _exitToLaunch');
            _exitToLaunch();
            debugPrint('🚪 After _exitToLaunch, displayMode: $_displayMode');
          },
          onTicketUpdated: (updated) {
            _ticketsKey.currentState?.updateTicket(updated);
            _currentTicket = updated;
          },
          onTicketDeleted: () {
            final ticketId = _currentTicket!.id;
            _currentTicket = null;
            _ticketsKey.currentState?.deleteTicket(ticketId);
            Navigator.of(context).pop();
          },
          onPause: () {
            debugPrint('⏸️ Pause pressed');
            conversationService.pauseConversation();
            _orderDisplayKey.currentState?.setPaused(true);
            // Start wake word so "Hey Millie" can resume
            WakeService.instance.start();
          },
          onPlay: () async {
            debugPrint('▶️ Play pressed');
            if (conversationService.isPaused) {
              // Resume paused conversation - just start listening again
              debugPrint('▶️ Resuming paused conversation');
              await conversationService.resumeConversation();
              _orderDisplayKey.currentState?.setPaused(false);
            } else if (conversationService.isIdle) {
              // No active conversation - start default conversation
              debugPrint('🎯 Starting default conversation');
              await conversationService.startDefaultConversation();
            }
          },
          onRefresh: () async {
            debugPrint('🔄 Refresh pressed - cancelling conversation and resetting counter');
            await conversationService.cancelConversation();
            conversationService.resetTicketCounter();
            rosBridge.publishWorkflowCancel();
          },
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
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
    if (status == 'started' && _displayMode == DisplayMode.dashboard) {
      _launchFace();
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
      
      // Restart wake word when workflow finishes (robot arrived at destination)
      if (_displayMode == DisplayMode.face) {
        debugPrint('🎤 Workflow $status - restarting wake word');
        WakeService.instance.start();
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
  @override
  void dispose() {
    rosBridge.removeWorkflowStatusListener(_handleWorkflowStatus);
    _faceTicketsController.dispose();
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
    debugPrint('🎭 _launchFace() called - current mode: $_displayMode');
    final wasInPageView = _displayMode == DisplayMode.face || _displayMode == DisplayMode.tickets;
    debugPrint('🎭 wasInPageView: $wasInPageView, hasClients: ${_faceTicketsController.hasClients}');
    
    setState(() => _displayMode = DisplayMode.face);
    
    // Start wake word listening when entering face mode (if idle)
    if (conversationService.isIdle) {
      WakeService.instance.start();
    }
    
    // Animate to face page (index 0) if already in PageView, otherwise jump after frame
    if (wasInPageView && _faceTicketsController.hasClients) {
      debugPrint('🎭 Animating to face page (index 0)');
      _faceTicketsController.animateToPage(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      debugPrint('🎭 Jumping to face page after frame');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('🎭 Post-frame callback - hasClients: ${_faceTicketsController.hasClients}');
        if (_faceTicketsController.hasClients) {
          _faceTicketsController.jumpToPage(0);
        }
      });
    }
  }

  void _showTickets() {
    final wasInPageView = _displayMode == DisplayMode.face || _displayMode == DisplayMode.tickets;
    setState(() => _displayMode = DisplayMode.tickets);
    // Animate to tickets page (index 1) if already in PageView, otherwise jump after frame
    if (wasInPageView && _faceTicketsController.hasClients) {
      _faceTicketsController.animateToPage(
        1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_faceTicketsController.hasClients) {
          _faceTicketsController.jumpToPage(1);
        }
      });
    }
  }

  void _exitToLaunch() {
    // Stop AI conversation and clear context (like millie_mini)
    conversationService.cancelConversation();
    // Stop wake word when leaving face mode
    WakeService.instance.stop();
    setState(() => _displayMode = DisplayMode.dashboard);
  }

  /// Open the thought bubble (when ticket creation starts)
  void openThoughtBubble() {
    _orderDisplayKey.currentState?.openThoughtBubble();
  }

  /// Close thought bubble and restore face
  void closeThoughtBubble() {
    _orderDisplayKey.currentState?.closeThoughtBubble();
  }

  /// Add a processed order item (from LLM)
  void addOrderItem(String item) {
    _orderDisplayKey.currentState?.addOrderItem(item);
  }

  /// Set mouth speaking state
  void setSpeaking(bool speaking) {
    _orderDisplayKey.currentState?.setSpeaking(speaking);
  }

  void _onPageChanged(int page) {
    setState(() {
      _displayMode = page == 0 ? DisplayMode.face : DisplayMode.tickets;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Face/Tickets mode - swipeable PageView
    if (_displayMode == DisplayMode.face || _displayMode == DisplayMode.tickets) {
      return PageView(
        controller: _faceTicketsController,
        onPageChanged: _onPageChanged,
        children: [
          // Page 0: Face
          OrderDisplayPage(
        key: _orderDisplayKey,
        onExit: _exitToLaunch,
        onTickets: _showTickets,
            onPause: () {
              debugPrint('⏸️ Pause pressed');
              conversationService.pauseConversation();
              _orderDisplayKey.currentState?.setPaused(true);
              // Start wake word so "Hey Millie" can resume
              WakeService.instance.start();
            },
            onPlay: () async {
              debugPrint('▶️ Play pressed');
              if (conversationService.isPaused) {
                // Resume paused conversation - just start listening again
                debugPrint('▶️ Resuming paused conversation');
                await conversationService.resumeConversation();
                _orderDisplayKey.currentState?.setPaused(false);
              } else if (conversationService.isIdle) {
                // No active conversation - start default conversation
                debugPrint('🎯 Starting default conversation');
                await conversationService.startDefaultConversation();
              }
            },
            onRefresh: () async {
              debugPrint('🔄 Refresh pressed - cancelling conversation and resetting counter');
              await conversationService.cancelConversation();
              conversationService.resetTicketCounter();
              // Also cancel any running workflow
              rosBridge.publishWorkflowCancel();
            },
          ),
          // Page 1: Tickets
          TicketsPage(
            rosBridge: rosBridge,
            onBack: _launchFace,  // Back arrow goes to face
            onExit: _exitToLaunch,  // Exit button goes to dashboard
          ),
        ],
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
      case MainView.launch:
        return LaunchPage(
          rosBridge: rosBridge,
          onLaunch: _launchFace,
          onShowTickets: _showTickets,
        );
      case MainView.locations:
        return LocationsPage(rosBridge: rosBridge);
      case MainView.settings:
        return SettingsPage(
          rosBridge: rosBridge,
          robotApi: robotApi,
          onModeStarted: _onRosStarted,
        );
    }
  }
}
