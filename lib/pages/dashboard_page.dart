import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../utils/constants.dart';
import '../utils/robot_api.dart';
import '../models/consciousness.dart';
import '../services/consciousness_service.dart';
import '../services/conversation_service.dart';
import '../services/local_memory_service.dart';
import '../widgets/simple_control_bar.dart';
import '../widgets/warning_dialog.dart';
import 'face_page.dart';

/// Identity dashboard - AI control center with live activity monitoring
class DashboardPage extends StatefulWidget {
  final RobotApi robotApi;
  final ConversationService conversationService;
  final ConsciousnessService consciousnessService;
  final LocalMemoryService localMemoryService;
  final VoidCallback onNavigateToFace;
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;
  final String statusText;
  final String faceId;
  final String agentName;
  final String voice;
  final String voiceMode;

  const DashboardPage({
    super.key,
    required this.robotApi,
    required this.conversationService,
    required this.consciousnessService,
    required this.localMemoryService,
    required this.onNavigateToFace,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
    required this.statusText,
    this.faceId = '',
    this.agentName = 'Millie',
    this.voice = 'nova',
    this.voiceMode = 'turn_taking',
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

/// Dashboard tabs
enum DashboardTab {
  monitor,
  identity,
  memory,
  heart,
}

class _DashboardPageState extends State<DashboardPage> {
  // Current selected tab
  DashboardTab _selectedTab = DashboardTab.monitor;

  // Heart score computed from consciousness service
  int get _heartScore => widget.consciousnessService.currentHeartScore;
  int get _heartDelta {
    final entries = widget.consciousnessService.heartState?.entries ?? [];
    if (entries.isEmpty) return 0;
    return entries.first.delta;
  }

  // System status polling
  Timer? _pollTimer;
  SystemInfo? _systemInfo;

  // Token tracking (per-response, not time-based)
  StreamSubscription<List<int>>? _tokenSubscription;
  List<int> _tokenHistory = List.filled(20, 0);
  int _sessionTokens = 0;
  int _lastResponseTokens = 0;

  // Conversation state tracking
  bool _isPaused = true;

  // Activity log subscription (log is stored in ConversationService)
  StreamSubscription<ActivityEntry>? _activitySubscription;


  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    );
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    // Start polling system status
    _refreshStatus();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _refreshStatus());

    // Listen to conversation state changes
    _isPaused = !widget.conversationService.isActive || widget.conversationService.isPaused;
    widget.conversationService.addListener(_onConversationStateChanged);

    // Listen to consciousness service changes (for when it initializes)
    widget.consciousnessService.addListener(_onConsciousnessChanged);

    // Listen to local memory service changes
    widget.localMemoryService.addListener(_onLocalMemoryChanged);

    // Subscribe to activity stream for UI updates
    _activitySubscription = widget.conversationService.activityStream.listen((_) {
      if (mounted) setState(() {});
    });

    // Start token tracking
    widget.conversationService.startTokenTracking();
    _tokenHistory = List.from(widget.conversationService.tokenHistory);
    _sessionTokens = widget.conversationService.sessionTotalTokens;
    _lastResponseTokens = widget.conversationService.lastResponseTokens;
    _tokenSubscription = widget.conversationService.tokenHistoryStream.listen((history) {
      if (mounted) {
        setState(() {
          _tokenHistory = history;
          _sessionTokens = widget.conversationService.sessionTotalTokens;
          _lastResponseTokens = widget.conversationService.lastResponseTokens;
        });
      }
    });
  }

  void _onConsciousnessChanged() {
    if (mounted) setState(() {});
  }

  void _onLocalMemoryChanged() {
    if (mounted) setState(() {});
  }

  void _onConversationStateChanged() {
    if (mounted) {
      setState(() {
        _isPaused = !widget.conversationService.isActive || widget.conversationService.isPaused;
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _activitySubscription?.cancel();
    _tokenSubscription?.cancel();
    widget.conversationService.removeListener(_onConversationStateChanged);
    widget.consciousnessService.removeListener(_onConsciousnessChanged);
    widget.localMemoryService.removeListener(_onLocalMemoryChanged);
    widget.conversationService.stopTokenTracking();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final status = await widget.robotApi.getStatus();
    if (mounted && status != null) {
      setState(() {
        _systemInfo = status.system;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar with title and back button
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  // Spacer to balance the back button
                  const SizedBox(width: 44),
                  const Expanded(
                    child: Text(
                      'AI Dashboard',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  // Back button (orange) - on right side
                  GestureDetector(
                    onTap: widget.onNavigateToFace,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.dangerBright,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.arrow_forward, color: Colors.white, size: 24),
                    ),
                  ),
                ],
              ),
            ),

            // Row 1: Agent Profile + Heart Metrics + System Vitals
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _buildAgentProfileCard()),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: _buildHeartMetricsCard()),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: _buildSystemVitalsCard()),
                  ],
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.md),

            // Tab menu
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: _buildTabMenu(),
            ),

            const SizedBox(height: AppSpacing.md),

            // Tab content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: _buildTabContent(),
              ),
            ),

            // Status text
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(
                widget.statusText,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
            ),

            // Control bar
            SimpleControlBar(
              onPause: widget.onPause,
              onPlay: widget.onPlay,
              onRefresh: widget.onRefresh,
              onExit: widget.onExit,
              isPaused: _isPaused,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgentProfileCard() {
    return GestureDetector(
      onTap: widget.onNavigateToFace,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title
            const Text(
              'Agent Profile',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Face preview
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return _buildMiniRobotFace(constraints.maxWidth);
                  },
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Agent info with icons and labels
            _buildLabeledDetailRow(Icons.smart_toy, 'Agent', widget.agentName),
            _buildLabeledDetailRow(Icons.record_voice_over, 'Voice', widget.voice),
            _buildLabeledDetailRow(Icons.swap_horiz, 'Mode', widget.voiceMode == 'realtime' ? 'Realtime' : 'Turn Taking'),
          ],
        ),
      ),
    );
  }

  Widget _buildLabeledDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textMuted, size: 12),
          const SizedBox(width: 4),
          SizedBox(
            width: 36,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textMuted, size: 14),
          const SizedBox(width: 6),
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniRobotFace(double size) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Eyes
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: size * 0.24,
              height: size * 0.32,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(size * 0.024),
              ),
            ),
            SizedBox(width: size * 0.08),
            Container(
              width: size * 0.24,
              height: size * 0.32,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(size * 0.024),
              ),
            ),
          ],
        ),
        SizedBox(height: size * 0.12),
        // Mouth
        Container(
          width: size * 0.32,
          height: size * 0.025,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(size * 0.0125),
          ),
        ),
      ],
    );
  }

  Widget _buildHeartMetricsCard() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title
          const Text(
            'Heart Metrics',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // Heart icon square
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.maxWidth;
                  return Center(
                    child: Icon(
                      Icons.favorite,
                      color: Colors.red,
                      size: size * 0.6,
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // Score and delta in columns
          Row(
            children: [
              // Current column
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.favorite, color: AppColors.textMuted, size: 12),
                        SizedBox(width: 4),
                        Text(
                          'Current',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_heartScore',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
              // Change column
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.trending_up, color: AppColors.textMuted, size: 12),
                        SizedBox(width: 4),
                        Text(
                          'Change',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          _heartDelta >= 0 ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                          color: _heartDelta >= 0 ? AppColors.success : AppColors.danger,
                          size: 36,
                        ),
                        Text(
                          '${_heartDelta.abs()}%',
                          style: TextStyle(
                            color: _heartDelta >= 0 ? AppColors.success : AppColors.danger,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSystemVitalsCard() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title
          const Text(
            'System Vitals',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // Chip/board icon square
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.maxWidth;
                  return Center(
                    child: Icon(
                      Icons.dns,
                      color: AppColors.accent,
                      size: size * 0.6,
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // Metrics stacked with icons
          _buildIconMetricRow(
            Icons.thermostat,
            'Temp',
            _systemInfo?.cpuTemp != null
                ? '${_systemInfo!.cpuTemp!.toStringAsFixed(0)}°'
                : '--',
            _getTempColor(_systemInfo?.cpuTemp),
          ),
          _buildIconMetricRow(
            Icons.speed,
            'CPU',
            _systemInfo?.cpuPercent != null
                ? '${_systemInfo!.cpuPercent!.toStringAsFixed(0)}%'
                : '--',
            _getCpuColor(_systemInfo?.cpuPercent),
          ),
          _buildIconMetricRow(
            Icons.memory,
            'Mem',
            _systemInfo?.memUsagePercent != null
                ? '${_systemInfo!.memUsagePercent!.toStringAsFixed(0)}%'
                : '--',
            null,
          ),
        ],
      ),
    );
  }

  Widget _buildIconMetricRow(IconData icon, String label, String value, Color? color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textMuted, size: 12),
          const SizedBox(width: 4),
          SizedBox(
            width: 36,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: color ?? AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMetric(IconData icon, String label, String value, Color? color) {
    return Row(
      children: [
        Icon(icon, color: AppColors.textMuted, size: 14),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            color: color ?? AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Color _getTempColor(double? temp) {
    if (temp == null) return AppColors.textMuted;
    if (temp > 70) return AppColors.danger;
    if (temp > 60) return AppColors.warning;
    return AppColors.success;
  }

  Color _getCpuColor(double? percent) {
    if (percent == null) return AppColors.textMuted;
    if (percent > 80) return AppColors.danger;
    if (percent > 50) return AppColors.warning;
    return AppColors.success;
  }

  Widget _buildTabMenu() {
    return Row(
      children: [
        _buildTabButton(DashboardTab.monitor, 'Monitor', Icons.monitor_heart),
        const SizedBox(width: AppSpacing.sm),
        _buildTabButton(DashboardTab.identity, 'Identity', Icons.psychology),
        const SizedBox(width: AppSpacing.sm),
        _buildTabButton(DashboardTab.memory, 'Memory', Icons.storage),
        const SizedBox(width: AppSpacing.sm),
        _buildTabButton(DashboardTab.heart, 'Soul', Icons.favorite),
      ],
    );
  }

  Widget _buildTabButton(DashboardTab tab, String label, IconData icon) {
    final isSelected = _selectedTab == tab;
    return _buildTabButtonBase(
      tab,
      label,
      Icon(
        icon,
        color: isSelected ? AppColors.accent : AppColors.textMuted,
        size: 24,
      ),
    );
  }

  Widget _buildTabButtonFa(DashboardTab tab, String label, FaIconData icon) {
    final isSelected = _selectedTab == tab;
    return _buildTabButtonBase(
      tab,
      label,
      FaIcon(
        icon,
        color: isSelected ? AppColors.accent : AppColors.textMuted,
        size: 22,
      ),
    );
  }

  Widget _buildTabButtonBase(DashboardTab tab, String label, Widget iconWidget) {
    final isSelected = _selectedTab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedTab = tab);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.accent.withOpacity(0.15) : const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Column(
            children: [
              iconWidget,
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? AppColors.accent : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_selectedTab) {
      case DashboardTab.monitor:
        return _buildMonitorContent();
      case DashboardTab.memory:
        return _buildMemoryContent();
      case DashboardTab.identity:
        return _buildIdentityContent();
      case DashboardTab.heart:
        return _buildHeartContent();
    }
  }

  Widget _buildMonitorContent() {
    return Column(
      children: [
        // Token Meter + Token Usage cards
        Expanded(
          flex: 2,
          child: Row(
            children: [
              // Token Meter (line graph) - 2/3
              Expanded(
                flex: 2,
                child: _buildTokenMeterCard(),
              ),
              const SizedBox(width: AppSpacing.sm),
              // Token Usage (numbers) - 1/3
              Expanded(
                flex: 1,
                child: _buildTokenUsageCard(),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // Activity log feed
        Expanded(
          flex: 3,
          child: _buildActivityFeed(),
        ),
      ],
    );
  }

  Widget _buildMemoryContent() {
    // Two-column hemisphere layout (like Identity)
    return Row(
      children: [
        // Left hemisphere: Short-term memories (session summaries)
        Expanded(
          child: _buildShortTermMemoryColumn(),
        ),
        const SizedBox(width: AppSpacing.md),
        // Right hemisphere: Long-term memories (accessed via AI tools)
        Expanded(
          child: _buildLongTermMemoryColumn(),
        ),
      ],
    );
  }

  Widget _buildShortTermMemoryColumn() {
    final summaries = widget.consciousnessService.recentSummaries;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Header with reset button
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const Text(
                  'Short-term',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _confirmResetSessionSummaries,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.restart_alt,
                      color: AppColors.danger,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // List of summaries
          Expanded(
            child: summaries.isEmpty
                ? const Center(
                    child: Text(
                      'No sessions yet',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    itemCount: summaries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final summary = summaries[index];
                      return _buildSummaryItem(summary);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryItem(SessionSummary summary) {
    final timeStr = _formatTime(summary.startTime);
    final dateStr = _formatDate(summary.startTime);

    return GestureDetector(
      onTap: () => _showSummaryDetail(summary),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date/time and mood
            Row(
              children: [
                Text(
                  '$dateStr $timeStr',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _getMoodColor(summary.mood).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    summary.mood,
                    style: TextStyle(
                      color: _getMoodColor(summary.mood),
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Summary text (truncated)
            Text(
              summary.summary,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Color _getMoodColor(String mood) {
    switch (mood.toLowerCase()) {
      case 'warm':
      case 'friendly':
      case 'happy':
        return AppColors.warning;
      case 'curious':
      case 'interested':
        return AppColors.accent;
      case 'productive':
      case 'focused':
        return AppColors.success;
      case 'playful':
      case 'fun':
        return Colors.purple;
      default:
        return AppColors.textMuted;
    }
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'pm' : 'am';
    return '$hour:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);

    if (date == today) return 'Today';
    if (date == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return '${dt.month}/${dt.day}';
  }

  void _showSummaryDetail(SessionSummary summary) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          margin: const EdgeInsets.all(AppSpacing.md),
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with delete in upper right
              Row(
                children: [
                  Text(
                    'Session ${summary.sessionId}',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getMoodColor(summary.mood).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      summary.mood,
                      style: TextStyle(
                        color: _getMoodColor(summary.mood),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Delete button
                  IconButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _confirmDeleteSummary(summary);
                    },
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                    tooltip: 'Delete',
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(8),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${_formatDate(summary.startTime)} ${_formatTime(summary.startTime)}',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Summary
              const Text(
                'Summary',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                summary.summary,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Key points
              if (summary.keyPoints.isNotEmpty) ...[
                const Text(
                  'Key Points',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                ...summary.keyPoints.map((point) => Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• ', style: TextStyle(color: AppColors.accent, fontSize: 13)),
                      Expanded(
                        child: Text(
                          point,
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                )),
                const SizedBox(height: AppSpacing.sm),
              ],
              const SizedBox(height: AppSpacing.md),
              // Close button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Close', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDeleteSummary(SessionSummary summary) async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Delete Session?',
      message: 'This will permanently delete this session summary.',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      await widget.consciousnessService.deleteSessionSummary(summary.sessionId);
      setState(() {});
    }
  }

  Widget _buildLongTermMemoryColumn() {
    final notes = widget.localMemoryService.memories.notes;
    final owner = widget.localMemoryService.memories.owner;
    final people = widget.localMemoryService.memories.people;
    final hasOwnerNotes = owner.notes.isNotEmpty;
    final hasPeople = people.isNotEmpty;
    final hasNotes = notes.isNotEmpty;
    final isEmpty = !hasOwnerNotes && !hasPeople && !hasNotes;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Header with reset button
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const Text(
                  'Long-term',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _confirmResetLongTermMemory,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.restart_alt,
                      color: AppColors.danger,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Combined content
          Expanded(
            child: isEmpty
                ? const Center(
                    child: Text(
                      'No memories stored yet',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    children: [
                      // Owner section
                      if (hasOwnerNotes) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: AppSpacing.xs),
                          child: Text(
                            'Owner',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        ...owner.notes.asMap().entries.map((entry) => Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: _buildRelationshipItem(entry.value, entry.key),
                        )),
                        if (hasPeople || hasNotes) const SizedBox(height: AppSpacing.sm),
                      ],
                      // People section
                      if (hasPeople) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: AppSpacing.xs),
                          child: Text(
                            'People',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        ...people.map((person) => Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: _buildPersonItem(person),
                        )),
                        if (hasNotes) const SizedBox(height: AppSpacing.sm),
                      ],
                      // Facts section
                      if (hasNotes) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: AppSpacing.xs),
                          child: Text(
                            'Facts',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        ...notes.map((note) => Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: _buildFactItem(note),
                        )),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFactItem(MemoryNote note) {
    return GestureDetector(
      onTap: () => _showMemoryNoteModal(note),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          note.content,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  void _showMemoryNoteModal(MemoryNote note) {
    final contentController = TextEditingController(text: note.content);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    const Text(
                      'Edit Memory',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () async {
                        Navigator.pop(context);
                        await widget.localMemoryService.removeNote(note.id);
                        setState(() {});
                      },
                      child: const Icon(
                        Icons.delete_outline,
                        color: AppColors.danger,
                        size: 24,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                // Content field
                TextField(
                  controller: contentController,
                  maxLines: 4,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Memory content...',
                    hintStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: AppColors.background,
                    contentPadding: const EdgeInsets.all(12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                // Save button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final content = contentController.text.trim();
                      if (content.isNotEmpty) {
                        Navigator.pop(context);
                        await widget.localMemoryService.updateNote(note.id, content);
                        setState(() {});
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Save',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildIdentityContent() {
    // Single scrollable column with all identity components
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        children: [
          // Top row: Core Identity + Active Personality side by side
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildCoreIdentityCard()),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: _buildActivePersonalityCard()),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Communication Style sliders
          _buildCommunicationStyleCard(),
          const SizedBox(height: AppSpacing.md),
          // Tendencies sliders
          _buildTendenciesCard(),
          const SizedBox(height: AppSpacing.md),
          // Interests card
          _buildInterestsCard(),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  Widget _buildCoreIdentityCard() {
    final items = widget.consciousnessService.coreIdentity?.statements ?? [];
    final count = items.length;

    return GestureDetector(
      onTap: _showCoreIdentityModal,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.fingerprint, color: AppColors.accent, size: 24),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Core Identity',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    count == 0 ? 'Tap to add values' : '$count value${count == 1 ? '' : 's'}',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.edit_outlined, color: AppColors.accent, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  void _showCoreIdentityModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final items = widget.consciousnessService.coreIdentity?.statements ?? [];
            final controller = TextEditingController();

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.75,
              ),
              margin: const EdgeInsets.all(AppSpacing.md),
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      const Text(
                        'Core Identity',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () async {
                          Navigator.pop(context);
                          _confirmResetCoreIdentity();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppColors.danger.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.restart_alt, color: AppColors.danger, size: 20),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // Add new field
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          style: const TextStyle(color: AppColors.textPrimary),
                          decoration: InputDecoration(
                            hintText: 'Add a core value...',
                            hintStyle: TextStyle(color: AppColors.textMuted),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: AppColors.border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: AppColors.accent),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () async {
                          final text = controller.text.trim();
                          if (text.isNotEmpty) {
                            await widget.consciousnessService.addCoreIdentity(text);
                            controller.clear();
                            setModalState(() {});
                            setState(() {});
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // List of items
                  Flexible(
                    child: items.isEmpty
                        ? const Center(
                            child: Text(
                              'No core values yet',
                              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: items.length,
                            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                            itemBuilder: (context, index) {
                              final text = items[index];
                              return Container(
                                padding: const EdgeInsets.all(AppSpacing.sm),
                                decoration: BoxDecoration(
                                  color: AppColors.background,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        text,
                                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () {
                                        _editCoreIdentityItem(text, index, () {
                                          setModalState(() {});
                                          setState(() {});
                                        });
                                      },
                                      icon: const Icon(Icons.edit_outlined, color: AppColors.accent, size: 18),
                                      constraints: const BoxConstraints(),
                                      padding: const EdgeInsets.all(4),
                                    ),
                                    IconButton(
                                      onPressed: () async {
                                        await widget.consciousnessService.removeCoreIdentity(index);
                                        setModalState(() {});
                                        setState(() {});
                                      },
                                      icon: const Icon(Icons.delete_outline, color: AppColors.danger, size: 18),
                                      constraints: const BoxConstraints(),
                                      padding: const EdgeInsets.all(4),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // Close button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Done', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _editCoreIdentityItem(String currentText, int index, VoidCallback onUpdate) {
    final controller = TextEditingController(text: currentText);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Edit Value',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final newText = controller.text.trim();
                      if (newText.isNotEmpty) {
                        await widget.consciousnessService.updateCoreIdentity(index, newText);
                        Navigator.pop(context);
                        onUpdate();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Save', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActivePersonalityCard() {
    final description = widget.consciousnessService.personalityState?.description ?? '';
    final hasContent = description.isNotEmpty;

    return GestureDetector(
      onTap: _editActivePersonality,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.face, color: AppColors.accent, size: 24),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Active Personality',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    hasContent ? 'Tap to edit' : 'Tap to describe yourself',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.edit_outlined, color: AppColors.accent, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  void _editActivePersonality() {
    final controller = TextEditingController(
      text: widget.consciousnessService.personalityState?.description ?? '',
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Active Personality',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: AppSpacing.md),
                Flexible(
                  child: TextField(
                    controller: controller,
                    maxLines: null,
                    minLines: 4,
                    expands: false,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Describe your personality...',
                      hintStyle: TextStyle(color: AppColors.textMuted),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.accent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      await widget.consciousnessService.updateDescription(controller.text.trim());
                      Navigator.pop(context);
                      setState(() {});
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Save', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCommunicationStyleCard() {
    final traits = widget.consciousnessService.personalityState?.traits ?? PersonalityTraits.defaults();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Communication Style',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.md),
            _buildTraitSlider('Serious', 'Playful', traits.playfulness, (v) => _updateTrait('playfulness', v)),
            _buildTraitSlider('Reserved', 'Expressive', traits.expressiveness, (v) => _updateTrait('expressiveness', v)),
            _buildTraitSlider('Formal', 'Casual', traits.formality, (v) => _updateTrait('formality', v)),
            _buildTraitSlider('Diplomatic', 'Direct', traits.directness, (v) => _updateTrait('directness', v)),
          ],
        ),
      ),
    );
  }

  Widget _buildTendenciesCard() {
    final traits = widget.consciousnessService.personalityState?.traits ?? PersonalityTraits.defaults();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tendencies',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.md),
            _buildTendencySlider('Humor', traits.humorUse, (v) => _updateTrait('humorUse', v)),
            _buildTendencySlider('Sarcasm', traits.sarcasmUse, (v) => _updateTrait('sarcasmUse', v)),
            _buildTendencySlider('Dramatic', traits.dramaticFlair, (v) => _updateTrait('dramaticFlair', v)),
          ],
        ),
      ),
    );
  }

  Widget _buildTraitSlider(String leftLabel, String rightLabel, int value, Function(int) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(leftLabel, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
              Text(rightLabel, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: AppColors.border,
              thumbColor: AppColors.accent,
              overlayColor: AppColors.accent.withOpacity(0.2),
              trackHeight: 4,
            ),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 100,
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTendencySlider(String label, int value, Function(int) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: AppColors.border,
                thumbColor: AppColors.accent,
                overlayColor: AppColors.accent.withOpacity(0.2),
                trackHeight: 4,
              ),
              child: Slider(
                value: value.toDouble(),
                min: 0,
                max: 100,
                onChanged: (v) => onChanged(v.round()),
              ),
            ),
          ),
          SizedBox(
            width: 35,
            child: Text('${value}%', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  void _updateTrait(String trait, int value) async {
    final current = widget.consciousnessService.personalityState?.traits ?? PersonalityTraits.defaults();
    PersonalityTraits updated;

    switch (trait) {
      case 'playfulness':
        updated = current.copyWith(playfulness: value);
        break;
      case 'expressiveness':
        updated = current.copyWith(expressiveness: value);
        break;
      case 'formality':
        updated = current.copyWith(formality: value);
        break;
      case 'directness':
        updated = current.copyWith(directness: value);
        break;
      case 'humorUse':
        updated = current.copyWith(humorUse: value);
        break;
      case 'sarcasmUse':
        updated = current.copyWith(sarcasmUse: value);
        break;
      case 'dramaticFlair':
        updated = current.copyWith(dramaticFlair: value);
        break;
      default:
        return;
    }

    await widget.consciousnessService.updatePersonalityTraits(updated);
    setState(() {});
  }

  Widget _buildInterestsCard() {
    final interests = widget.consciousnessService.personalityState?.interests ?? [];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Interests',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _addInterest,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.add, color: AppColors.accent, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (interests.isEmpty)
              const Text('No interests yet', style: TextStyle(color: AppColors.textMuted, fontSize: 13))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: interests.map((interest) => _buildInterestChip(interest)).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInterestChip(Interest interest) {
    return GestureDetector(
      onTap: () => _showInterestDetail(interest),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accent.withOpacity(0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.accent.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              interest.topic,
              style: const TextStyle(color: AppColors.accent, fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 6),
            Text(
              '${interest.intensity}',
              style: TextStyle(color: AppColors.accent.withOpacity(0.7), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  void _addInterest() {
    final topicController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add Interest',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: topicController,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Topic (e.g., Jazz, Photography)',
                    hintStyle: TextStyle(color: AppColors.textMuted),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final topic = topicController.text.trim();
                      if (topic.isNotEmpty) {
                        await widget.consciousnessService.addInterest(topic, 50, 'Added manually');
                        Navigator.pop(context);
                        setState(() {});
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Add', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showInterestDetail(Interest interest) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          margin: const EdgeInsets.all(AppSpacing.md),
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    interest.topic,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await widget.consciousnessService.removeInterest(interest.id);
                      setState(() {});
                    },
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Intensity: ${interest.intensity}%',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
              Text(
                'Origin: ${interest.origin}',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Close', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCoreIdentityColumn() {
    final items = widget.consciousnessService.coreIdentity?.statements ?? [];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const Text(
                  'Core Identity',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _onAddCoreIdentity,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.add,
                      color: AppColors.accent,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _confirmResetCoreIdentity,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.restart_alt,
                      color: AppColors.danger,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // List
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      'Tap + to add',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final text = items[index];
                      return _buildCoreIdentityItem(text, index);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoreIdentityItem(String text, int index) {
    return GestureDetector(
      onTap: () {
        _showIdentityInputModal(
          title: 'Edit Core Identity',
          initialText: text,
          onSave: (newText) async {
            await widget.consciousnessService.updateCoreIdentity(index, newText);
            setState(() {});
          },
          onDelete: () async {
            await widget.consciousnessService.removeCoreIdentity(index);
            setState(() {});
          },
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          text,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildSelfIdentityColumn() {
    final snapshots = widget.consciousnessService.identityHistory?.snapshots ?? [];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Header with reset button
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const Text(
                  'Self Identity',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _confirmResetIdentityHistory,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.restart_alt,
                      color: AppColors.danger,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // List
          Expanded(
            child: snapshots.isEmpty
                ? const Center(
                    child: Text(
                      'No entries yet',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    itemCount: snapshots.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final snapshot = snapshots[index];
                      return _buildIdentitySnapshotItem(snapshot, isLatest: index == 0);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentitySnapshotItem(IdentitySnapshot snapshot, {bool isLatest = false}) {
    // Format timestamp
    final date = snapshot.timestamp;
    final dateStr = '${date.month}/${date.day}/${date.year}';
    final timeStr = '${date.hour}:${date.minute.toString().padLeft(2, '0')}';

    // Preview of narrative (first ~60 chars)
    final preview = snapshot.narrative.length > 60
        ? '${snapshot.narrative.substring(0, 60)}...'
        : snapshot.narrative;

    return GestureDetector(
      onTap: () => _showIdentitySnapshotModal(snapshot),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: isLatest ? AppColors.accent.withOpacity(0.1) : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isLatest ? AppColors.accent.withOpacity(0.3) : AppColors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isLatest) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'CURRENT',
                      style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  dateStr,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
                const SizedBox(width: 4),
                Text(
                  timeStr,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              preview,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _showIdentitySnapshotModal(IdentitySnapshot snapshot) {
    final dateStr = '${_formatDate(snapshot.timestamp)} ${_formatTime(snapshot.timestamp)}';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          margin: const EdgeInsets.all(AppSpacing.md),
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with edit/delete in upper right
              Row(
                children: [
                  const Text(
                    'Self Identity',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  // Edit button
                  IconButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _showEditIdentitySnapshotModal(snapshot);
                    },
                    icon: const Icon(Icons.edit_outlined, color: AppColors.accent),
                    tooltip: 'Edit',
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(8),
                  ),
                  // Delete button
                  IconButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _confirmDeleteIdentitySnapshot(snapshot);
                    },
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                    tooltip: 'Delete',
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(8),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Date and session info
              Row(
                children: [
                  Text(
                    dateStr,
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  if (snapshot.sessionId.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      snapshot.sessionId,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              // Content
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    snapshot.narrative,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Close button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Close', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDeleteIdentitySnapshot(IdentitySnapshot snapshot) async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Delete Entry?',
      message: 'This will permanently delete this self identity entry.',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      await widget.consciousnessService.deleteIdentitySnapshot(snapshot.id);
      setState(() {});
    }
  }

  void _confirmResetIdentityHistory() async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Reset Self Identity?',
      message: 'This will delete all self identity entries. The AI will start fresh with no self-reflection history.',
      confirmLabel: 'Reset',
    );
    if (confirmed) {
      await widget.consciousnessService.resetIdentityHistory();
      setState(() {});
    }
  }

  void _confirmResetSessionSummaries() async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Reset Short-term Memory?',
      message: 'This will delete all session summaries. Recent conversation history will be lost.',
      confirmLabel: 'Reset',
    );
    if (confirmed) {
      await widget.consciousnessService.resetSessionSummaries();
      setState(() {});
    }
  }

  void _confirmResetHeartScore() async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Reset Heart Score?',
      message: 'This will clear all heart entries and reset the score to 50.',
      confirmLabel: 'Reset',
    );
    if (confirmed) {
      await widget.consciousnessService.resetHeartScore();
      setState(() {});
    }
  }

  void _confirmResetCoreIdentity() async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Reset Core Identity?',
      message: 'This will restore the default core identity statements.',
      confirmLabel: 'Reset',
    );
    if (confirmed) {
      await widget.consciousnessService.resetCoreIdentity();
      setState(() {});
    }
  }

  void _confirmResetLongTermMemory() async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Reset Long-term Memory?',
      message: 'This will delete all owner info, people, and stored facts.',
      confirmLabel: 'Reset',
    );
    if (confirmed) {
      await widget.localMemoryService.resetNotes();
      await widget.localMemoryService.resetRelationships();
      setState(() {});
    }
  }

  void _showEditIdentitySnapshotModal(IdentitySnapshot snapshot) {
    final controller = TextEditingController(text: snapshot.narrative);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.75,
            ),
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Edit Identity',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Flexible(
                  child: TextField(
                    controller: controller,
                    maxLines: null,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Identity narrative...',
                      hintStyle: TextStyle(color: AppColors.textMuted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.accent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final newText = controller.text.trim();
                      if (newText.isNotEmpty) {
                        await widget.consciousnessService.updateIdentitySnapshot(snapshot.id, newText);
                        setState(() {});
                      }
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Save', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildIdentityColumn({
    required String title,
    required List<String> items,
    required VoidCallback? onAdd,
    bool isCore = true,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Header with title and add button
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // Always show add button area (visible or invisible) for alignment
                GestureDetector(
                  onTap: onAdd,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: onAdd != null
                          ? AppColors.accent.withOpacity(0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.add,
                      color: onAdd != null ? AppColors.accent : Colors.transparent,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Scrollable list of items
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      onAdd != null ? 'Tap + to add' : 'None yet',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      return _buildIdentityItem(items[index], isCore: isCore);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentityItem(String text, {bool isCore = true}) {
    return GestureDetector(
      onTap: () {
        _showIdentityInputModal(
          title: isCore ? 'Edit Core Identity' : 'View Self Identity',
          initialText: text,
          onSave: (newText) {
            // TODO: Update in consciousness service
            debugPrint('Update identity: $newText');
          },
          onDelete: () {
            // TODO: Delete from consciousness service
            debugPrint('Delete identity: $text');
          },
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  List<String> _getCoreIdentityItems() {
    // Get from consciousness service
    return widget.consciousnessService.coreIdentity?.statements ?? [];
  }


  void _onAddCoreIdentity() {
    _showIdentityInputModal(
      title: 'Add Core Identity',
      initialText: '',
      onSave: (text) async {
        await widget.consciousnessService.addCoreIdentity(text);
        setState(() {});
      },
    );
  }

  void _showIdentityInputModal({
    required String title,
    required String initialText,
    required Function(String) onSave,
    VoidCallback? onDelete,
  }) {
    final controller = TextEditingController(text: initialText);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (onDelete != null)
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          onDelete();
                        },
                        child: const Icon(
                          Icons.delete_outline,
                          color: AppColors.danger,
                          size: 24,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                // Text input
                TextField(
                  controller: controller,
                  autofocus: false,
                  maxLines: 4,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter identity statement...',
                    hintStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                // Save button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      final text = controller.text.trim();
                      if (text.isNotEmpty) {
                        Navigator.pop(context);
                        onSave(text);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Save',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeartContent() {
    // Two-column layout: Personalities (history) | Heart Scores
    return Row(
      children: [
        // Left: Personalities history
        Expanded(
          child: _buildPersonalitiesColumn(),
        ),
        const SizedBox(width: AppSpacing.md),
        // Right: Heart Scores
        Expanded(
          child: _buildHeartLogColumn(),
        ),
      ],
    );
  }

  Widget _buildPersonalitiesColumn() {
    final snapshots = widget.consciousnessService.personalityHistory?.snapshots ?? [];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Header with reset button
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const Text(
                  'Personalities',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _confirmResetPersonalityHistory,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.restart_alt,
                      color: AppColors.danger,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // List
          Expanded(
            child: snapshots.isEmpty
                ? const Center(
                    child: Text(
                      'No history yet',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    itemCount: snapshots.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final snapshot = snapshots[index];
                      return _buildPersonalitySnapshotItem(snapshot, isLatest: index == 0);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalitySnapshotItem(PersonalitySnapshot snapshot, {bool isLatest = false}) {
    final dateStr = _formatDate(snapshot.timestamp);
    final timeStr = _formatTime(snapshot.timestamp);

    return GestureDetector(
      onTap: () => _showPersonalitySnapshotModal(snapshot),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: isLatest ? AppColors.accent.withOpacity(0.1) : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isLatest ? AppColors.accent.withOpacity(0.3) : AppColors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isLatest) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'CURRENT',
                      style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  dateStr,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
                const SizedBox(width: 4),
                Text(
                  timeStr,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ),
            if (snapshot.changeNotes.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                snapshot.changeNotes,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showPersonalitySnapshotModal(PersonalitySnapshot snapshot) {
    final dateStr = '${_formatDate(snapshot.timestamp)} ${_formatTime(snapshot.timestamp)}';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          margin: const EdgeInsets.all(AppSpacing.md),
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with delete in upper right
              Row(
                children: [
                  const Text(
                    'Personality',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _confirmDeletePersonalitySnapshot(snapshot);
                    },
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                    tooltip: 'Delete',
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(8),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                dateStr,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: AppSpacing.md),
              // Content
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (snapshot.changeNotes.isNotEmpty) ...[
                        const Text('Changes', style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text(snapshot.changeNotes, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                        const SizedBox(height: AppSpacing.md),
                      ],
                      const Text('Description', style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(snapshot.description.isEmpty ? '(empty)' : snapshot.description, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                      const SizedBox(height: AppSpacing.md),
                      const Text('Traits', style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('Playfulness: ${snapshot.traits.playfulness}%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      Text('Expressiveness: ${snapshot.traits.expressiveness}%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      Text('Formality: ${snapshot.traits.formality}%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      Text('Directness: ${snapshot.traits.directness}%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      Text('Humor: ${snapshot.traits.humorUse}%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      Text('Sarcasm: ${snapshot.traits.sarcasmUse}%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      Text('Dramatic: ${snapshot.traits.dramaticFlair}%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      if (snapshot.interests.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.md),
                        const Text('Interests', style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: snapshot.interests.map((i) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.accent.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('${i.topic} ${i.intensity}', style: TextStyle(color: AppColors.accent, fontSize: 11)),
                          )).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Close button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Close', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDeletePersonalitySnapshot(PersonalitySnapshot snapshot) async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Delete Entry?',
      message: 'This will permanently delete this personality history entry.',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      await widget.consciousnessService.deletePersonalitySnapshot(snapshot.id);
      setState(() {});
    }
  }

  void _confirmResetPersonalityHistory() async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Reset Personality History?',
      message: 'This will delete all personality history entries.',
      confirmLabel: 'Reset',
    );
    if (confirmed) {
      await widget.consciousnessService.resetPersonalityHistory();
      setState(() {});
    }
  }

  Widget _buildRelationshipItem(String note, int index) {
    return GestureDetector(
      onTap: () {
        _showOwnerNoteModal(
          title: 'Edit Owner Note',
          initialText: note,
          onSave: (newText) async {
            await widget.localMemoryService.updateOwnerNote(index, newText);
            setState(() {});
          },
          onDelete: () async {
            await widget.localMemoryService.removeOwnerNote(index);
            setState(() {});
          },
        );
      },
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          note,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  void _showOwnerNoteModal({
    required String title,
    required String initialText,
    required Function(String) onSave,
    VoidCallback? onDelete,
  }) {
    final controller = TextEditingController(text: initialText);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (onDelete != null)
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          onDelete();
                        },
                        child: const Icon(
                          Icons.delete_outline,
                          color: AppColors.danger,
                          size: 24,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                // Text input
                TextField(
                  controller: controller,
                  autofocus: false,
                  maxLines: 4,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter note...',
                    hintStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                // Save button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      final text = controller.text.trim();
                      if (text.isNotEmpty) {
                        Navigator.pop(context);
                        onSave(text);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Save',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPersonItem(KnownPerson person) {
    return GestureDetector(
      onTap: () => _showPersonDetailModal(person),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  person.name,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (person.relationship.isNotEmpty) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    '(${person.relationship})',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
            if (person.notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                person.notes.join(', '),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showPersonDetailModal(KnownPerson person) {
    final nameController = TextEditingController(text: person.name);
    final relationshipController = TextEditingController(text: person.relationship);
    final notesController = TextEditingController(text: person.notes.join('\n'));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    const Text(
                      'Edit Person',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () async {
                        Navigator.pop(context);
                        await widget.localMemoryService.removePerson(person.name);
                        setState(() {});
                      },
                      child: const Icon(
                        Icons.delete_outline,
                        color: AppColors.danger,
                        size: 24,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                // Name field
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Name',
                    labelStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                // Relationship field
                TextField(
                  controller: relationshipController,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Relationship',
                    labelStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                // Notes field
                TextField(
                  controller: notesController,
                  maxLines: 3,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Notes (one per line)',
                    labelStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                // Save button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final name = nameController.text.trim();
                      if (name.isNotEmpty) {
                        Navigator.pop(context);
                        // Remove old and add updated
                        await widget.localMemoryService.removePerson(person.name);
                        final notes = notesController.text
                            .split('\n')
                            .map((n) => n.trim())
                            .where((n) => n.isNotEmpty)
                            .toList();
                        await widget.localMemoryService.rememberPerson(KnownPerson(
                          name: name,
                          relationship: relationshipController.text.trim(),
                          notes: notes,
                        ));
                        setState(() {});
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Save',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeartLogColumn() {
    final entries = widget.consciousnessService.heartState?.entries ?? [];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Header with reset button
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const Text(
                  'Heart Scores',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _confirmResetHeartScore,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.restart_alt,
                      color: AppColors.danger,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Entries list
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'No entries yet',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return _buildHeartLogEntry(entry);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeartLogEntry(HeartEntry entry) {
    final isPositive = entry.delta >= 0;

    return GestureDetector(
      onTap: () => _showHeartEntryDetail(entry),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            // Score value
            Text(
              '${entry.totalAfter}',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            // Triangle arrow and delta
            Icon(
              isPositive ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              color: isPositive ? AppColors.success : AppColors.danger,
              size: 24,
            ),
            Text(
              '${entry.delta.abs()}%',
              style: TextStyle(
                color: isPositive ? AppColors.success : AppColors.danger,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            // Reason
            Expanded(
              child: Text(
                entry.reason,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showHeartEntryDetail(HeartEntry entry) {
    final isPositive = entry.delta >= 0;
    final dateStr = _formatDate(entry.timestamp);
    final timeStr = _formatTime(entry.timestamp);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          margin: const EdgeInsets.all(AppSpacing.md),
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with score, change, and delete in upper right
              Row(
                children: [
                  Text(
                    '${entry.totalAfter}',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Icon(
                    isPositive ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    color: isPositive ? AppColors.success : AppColors.danger,
                    size: 36,
                  ),
                  Text(
                    '${entry.delta.abs()}%',
                    style: TextStyle(
                      color: isPositive ? AppColors.success : AppColors.danger,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  // Delete button
                  IconButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _confirmDeleteHeartEntry(entry);
                    },
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                    tooltip: 'Delete',
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(8),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              // Date/time
              Text(
                '$dateStr $timeStr',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Reason
              const Text(
                'Reason',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                entry.reason,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              // Close button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Close', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDeleteHeartEntry(HeartEntry entry) async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Delete Entry?',
      message: 'This will delete this heart score entry and recalculate the total.',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      await widget.consciousnessService.deleteHeartEntry(entry.id);
      setState(() {});
    }
  }

  Widget _buildPlaceholderContent(String title, IconData icon, String description) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.textMuted, size: 48),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            description,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          const Text(
            'Coming soon...',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTokenCount(int tokens) {
    if (tokens >= 1000000) {
      return '${(tokens / 1000000).toStringAsFixed(1)}M';
    } else if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}K';
    }
    return tokens.toString();
  }

  Widget _buildTokenMeterCard() {
    // Find max for scale
    final maxTokens = _tokenHistory.isEmpty ? 0 : _tokenHistory.reduce((a, b) => a > b ? a : b);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Token Meter',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // Scale indicator
              Text(
                'max: ${_formatTokenCount(maxTokens)}',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: CustomPaint(
              painter: _TokenLineGraphPainter(
                tokenHistory: _tokenHistory,
                maxTokens: maxTokens,
              ),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTokenUsageCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Token Usage',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          // Total tokens
          const Text(
            'Total',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatTokenCount(_sessionTokens),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // Current/last response
          const Text(
            'Current',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatTokenCount(_lastResponseTokens),
            style: const TextStyle(
              color: AppColors.accent,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  String _activityTypeLabel(ActivityType type) {
    switch (type) {
      case ActivityType.info: return 'Info';
      case ActivityType.user: return 'User';
      case ActivityType.bot: return 'AI';
      case ActivityType.state: return 'State';
      case ActivityType.movement: return 'Move';
      case ActivityType.tool: return 'Tool';
      case ActivityType.error: return 'Error';
    }
  }

  Color _activityTypeColor(ActivityType type) {
    switch (type) {
      case ActivityType.info: return AppColors.textMuted;
      case ActivityType.user: return AppColors.accent;
      case ActivityType.bot: return AppColors.success;
      case ActivityType.state: return AppColors.textSecondary;
      case ActivityType.movement: return AppColors.warning;
      case ActivityType.tool: return AppColors.success;
      case ActivityType.error: return AppColors.danger;
    }
  }

  Widget _buildActivityFeed() {
    final activityLog = widget.conversationService.activityLog;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Activity',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: activityLog.isEmpty
                ? const Center(
                    child: Text(
                      'No activity yet',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 14,
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: false,
                    itemCount: activityLog.length,
                    itemBuilder: (context, index) {
                      final entry = activityLog[index];
                      final color = _activityTypeColor(entry.type);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Category badge
                            Container(
                              width: 44,
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: color.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _activityTypeLabel(entry.type),
                                style: TextStyle(
                                  color: color,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Message - full width, wrap as needed
                            Expanded(
                              child: Text(
                                entry.message,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

}

/// Line graph painter for token usage (per-response)
class _TokenLineGraphPainter extends CustomPainter {
  final List<int> tokenHistory;
  final int maxTokens;

  _TokenLineGraphPainter({required this.tokenHistory, required this.maxTokens});

  @override
  void paint(Canvas canvas, Size size) {
    if (tokenHistory.isEmpty) return;

    final scale = maxTokens > 0 ? maxTokens.toDouble() : 100.0;
    final pointCount = tokenHistory.length;
    final stepX = size.width / (pointCount - 1);
    final maxHeight = size.height - 4;

    // Build path for fill area
    final fillPath = Path();
    final linePath = Path();

    bool started = false;
    for (int i = 0; i < pointCount; i++) {
      final tokens = tokenHistory[i];
      final x = i * stepX;
      final y = size.height - (tokens / scale) * maxHeight;

      if (!started) {
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
        linePath.moveTo(x, y);
        started = true;
      } else {
        fillPath.lineTo(x, y);
        linePath.lineTo(x, y);
      }
    }

    // Close fill path
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    // Draw fill
    final fillPaint = Paint()
      ..color = AppColors.accent.withOpacity(0.2)
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // Draw line
    final linePaint = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, linePaint);

    // Draw current point (last value)
    if (tokenHistory.isNotEmpty) {
      final lastX = (pointCount - 1) * stepX;
      final lastY = size.height - (tokenHistory.last / scale) * maxHeight;
      final dotPaint = Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(lastX, lastY), 4, dotPaint);
    }

    // Draw baseline
    final baselinePaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      baselinePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _TokenLineGraphPainter oldDelegate) {
    return oldDelegate.tokenHistory != tokenHistory || oldDelegate.maxTokens != maxTokens;
  }
}
