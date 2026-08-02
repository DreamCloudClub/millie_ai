import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/rosbridge.dart';
import '../utils/robot_api.dart';
import '../services/consciousness_service.dart';
import '../services/conversation_service.dart';
import '../services/local_memory_service.dart';
import '../services/reminder_service.dart';
import '../services/reminder_scheduler_service.dart';
import 'face_page.dart';
import 'dashboard_page.dart';
import 'notes_page.dart';
import 'schedule_page.dart';

/// Main conversation page with swipeable navigation between pages
/// Page order: Dashboard(0) -> Face(1) -> Notes(2) -> Schedule(3)
class SwipeableConversationPage extends StatefulWidget {
  final RosBridge rosBridge;
  final RobotApi robotApi;
  final ConversationService conversationService;
  final ConsciousnessService consciousnessService;
  final LocalMemoryService localMemoryService;
  final ReminderService reminderService;
  final VoidCallback onExit;
  final VoidCallback? onPause;
  final VoidCallback? onPlay;
  final VoidCallback? onRefresh;
  final String faceId;
  final String agentName;
  final String voice;
  final String voiceMode;

  const SwipeableConversationPage({
    super.key,
    required this.rosBridge,
    required this.robotApi,
    required this.conversationService,
    required this.consciousnessService,
    required this.localMemoryService,
    required this.reminderService,
    required this.onExit,
    this.onPause,
    this.onPlay,
    this.onRefresh,
    this.faceId = '',
    this.agentName = 'Millie',
    this.voice = 'nova',
    this.voiceMode = 'turn_taking',
  });

  @override
  State<SwipeableConversationPage> createState() => SwipeableConversationPageState();
}

class SwipeableConversationPageState extends State<SwipeableConversationPage> {
  late PageController _pageController;

  // Keys to access page states
  final GlobalKey<FacePageState> _facePageKey = GlobalKey<FacePageState>();
  final GlobalKey<NotesPageState> _notesPageKey = GlobalKey<NotesPageState>();
  final GlobalKey<SchedulePageState> _schedulePageKey = GlobalKey<SchedulePageState>();

  // Page indices: Dashboard(0) -> Face(1) -> Notes(2) -> Schedule(3)
  static const int dashboardPageIndex = 0;
  static const int facePageIndex = 1;
  static const int notesPageIndex = 2;
  static const int schedulePageIndex = 3;

  // Voice status text shared across pages
  String _statusText = 'Ready';

  // Conversation state synced across all pages
  bool _isPaused = true;

  // Current page index for scheduler
  int _currentPageIndex = facePageIndex;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: facePageIndex);

    // Start with face page - hide status bar
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Listen to conversation service for pause state sync
    _isPaused = !widget.conversationService.isActive || widget.conversationService.isPaused;
    widget.conversationService.addListener(_onConversationStateChanged);

    // Initialize reminder scheduler
    ReminderSchedulerService.instance.init(
      reminderService: widget.reminderService,
      conversationService: widget.conversationService,
    );
    ReminderSchedulerService.instance.setOnFacePage(true); // Start on face page
    ReminderSchedulerService.instance.setUsername(widget.agentName);
    ReminderSchedulerService.instance.startPolling();
  }

  void _onConversationStateChanged() {
    if (mounted) {
      setState(() {
        _isPaused = !widget.conversationService.isActive || widget.conversationService.isPaused;
      });
    }
  }

  /// Navigate to a specific page by index
  void navigateToPage(int pageIndex) {
    _pageController.animateToPage(
      pageIndex,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _navigateToDashboard() => navigateToPage(dashboardPageIndex);
  void _navigateToFace() => navigateToPage(facePageIndex);
  void _navigateToNotes() => navigateToPage(notesPageIndex);

  @override
  void dispose() {
    widget.conversationService.removeListener(_onConversationStateChanged);
    _pageController.dispose();
    ReminderSchedulerService.instance.stopPolling();

    // Restore system UI
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    );

    super.dispose();
  }

  /// Update status bar visibility based on current page
  void _updateStatusBar(int pageIndex) {
    _currentPageIndex = pageIndex;
    // Update scheduler - alerts only trigger on face page
    ReminderSchedulerService.instance.setOnFacePage(pageIndex == facePageIndex);

    if (pageIndex == facePageIndex) {
      // Face page - hide status bar for immersive experience
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      // Other pages - show status bar with white icons
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [SystemUiOverlay.top],
      );
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ));
    }
  }

  // === Expose FacePage methods for external control ===

  void setSpeaking(bool speaking) {
    _facePageKey.currentState?.setSpeaking(speaking);
    if (speaking) setState(() => _statusText = 'Talking');
  }

  void setPaused(bool paused) {
    _facePageKey.currentState?.setPaused(paused);
    if (paused) setState(() => _statusText = 'Paused');
  }

  void setListening(bool listening) {
    _facePageKey.currentState?.setListening(listening);
    if (listening) setState(() => _statusText = 'Listening');
  }

  void setProcessing(bool processing) {
    _facePageKey.currentState?.setProcessing(processing);
    if (processing) setState(() => _statusText = 'Thinking...');
  }

  void setIdle(bool idle) {
    _facePageKey.currentState?.setIdle(idle);
    if (idle) setState(() => _statusText = 'Ready');
  }

  void openThoughtBubble() {
    _facePageKey.currentState?.openThoughtBubble();
  }

  void closeThoughtBubble() {
    _facePageKey.currentState?.closeThoughtBubble();
  }

  void addOrderItem(String item) {
    _facePageKey.currentState?.addOrderItem(item);
  }

  void openNote(String noteId) {
    _notesPageKey.currentState?.openNoteById(noteId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          // Update status bar visibility based on page
          _updateStatusBar(index);
        },
        children: [
          // Page 0: Dashboard Page (leftmost)
          DashboardPage(
            robotApi: widget.robotApi,
            conversationService: widget.conversationService,
            consciousnessService: widget.consciousnessService,
            localMemoryService: widget.localMemoryService,
            onNavigateToFace: _navigateToFace,
            onPause: widget.onPause ?? () {},
            onPlay: widget.onPlay ?? () {},
            onRefresh: widget.onRefresh ?? () {},
            onExit: widget.onExit,
            statusText: _statusText,
            faceId: widget.faceId,
            agentName: widget.agentName,
            voice: widget.voice,
            voiceMode: widget.voiceMode,
          ),

          // Page 1: Face Page (center, default)
          FacePage(
            key: _facePageKey,
            rosBridge: widget.rosBridge,
            faceId: widget.faceId,
            onExit: widget.onExit,
            onPause: widget.onPause,
            onPlay: widget.onPlay,
            onRefresh: widget.onRefresh,
            onNavigateLeft: _navigateToDashboard,
            onNavigateRight: _navigateToNotes,
          ),

          // Page 2: Notes Page
          NotesPage(
            key: _notesPageKey,
            onNavigateToFace: _navigateToFace,
            onPause: widget.onPause ?? () {},
            onPlay: widget.onPlay ?? () {},
            onRefresh: widget.onRefresh ?? () {},
            onExit: widget.onExit,
            statusText: _statusText,
            isPaused: _isPaused,
          ),

          // Page 3: Schedule Page (rightmost)
          SchedulePage(
            key: _schedulePageKey,
            reminderService: widget.reminderService,
            onNavigateToFace: _navigateToFace,
            onPause: widget.onPause ?? () {},
            onPlay: widget.onPlay ?? () {},
            onRefresh: widget.onRefresh ?? () {},
            onExit: widget.onExit,
            statusText: _statusText,
            isPaused: _isPaused,
          ),
        ],
      ),
    );
  }
}
