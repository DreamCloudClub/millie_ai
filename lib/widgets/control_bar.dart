import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../utils/rosbridge.dart';

/// Control bar overlay for Face pages - matches millie_mini style
/// Top bar: Wander, Follow, Track, Search buttons with toggle states
/// Bottom bar: Control buttons with grey background
class ControlBar extends StatefulWidget {
  final RosBridge rosBridge;
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;
  final VoidCallback onHide;  // Called to hide the control bar
  final bool isPaused;
  final bool isSleeping;
  final bool isIdle;

  // Callbacks for mode changes (so face_page can coordinate with conversation_service)
  final VoidCallback? onWanderStart;
  final VoidCallback? onWanderStop;
  final VoidCallback? onFollowStart;
  final VoidCallback? onFollowStop;

  // Search mode callbacks
  final VoidCallback? onSearchStart;
  final VoidCallback? onSearchStop;
  final bool isSearchActive;
  final String? searchTarget;
  final int searchCoverage;  // 0-100 percentage

  const ControlBar({
    super.key,
    required this.rosBridge,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
    required this.onHide,
    this.isPaused = false,
    this.isSleeping = false,
    this.isIdle = true,
    this.onWanderStart,
    this.onWanderStop,
    this.onFollowStart,
    this.onFollowStop,
    this.onSearchStart,
    this.onSearchStop,
    this.isSearchActive = false,
    this.searchTarget,
    this.searchCoverage = 0,
  });

  @override
  State<ControlBar> createState() => _ControlBarState();
}

class _ControlBarState extends State<ControlBar> {
  // Raw ROS states (what's actually running)
  bool _wanderOn = false;
  bool _followOn = false;
  bool _trackActive = false;  // Camera tracking (independent)

  // Derived display states (for button UI)
  bool get _wanderActive => _wanderOn && !_followOn;
  bool get _followActive => _followOn && !_wanderOn;

  @override
  void initState() {
    super.initState();
    _setupStatusListeners();
  }

  void _setupStatusListeners() {
    // Listen for wander status changes
    widget.rosBridge.onWanderStatus = (status) {
      if (!mounted) return;
      final isOn = status != 'disabled' && status != 'idle' && status.isNotEmpty;
      if (isOn != _wanderOn) {
        setState(() => _wanderOn = isOn);
        debugPrint('🚶 Wander: $status -> wanderOn=$_wanderOn (wander=$_wanderActive)');
      }
    };

    // Listen for following mode status changes
    widget.rosBridge.onFollowingModeStatus = (status) {
      if (!mounted) return;
      final mode = status['status'] as String? ?? 'disabled';
      final isOn = mode != 'disabled';
      if (isOn != _followOn) {
        setState(() => _followOn = isOn);
        debugPrint('👤 Follow: $mode -> followOn=$_followOn (follow=$_followActive)');
      }
    };
  }

  // Handle Wander toggle
  void _handleWanderTap() {
    if (_wanderActive) {
      // Stop wander
      widget.rosBridge.deactivateWanderMode();
      widget.onWanderStop?.call();
      setState(() => _wanderOn = false);
    } else {
      // Start wander (stops other modes via rosbridge)
      widget.rosBridge.activateWanderMode();
      widget.onWanderStart?.call();
      setState(() {
        _wanderOn = true;
        _followOn = false;
        _trackActive = false;
      });
    }
    widget.onHide();
  }

  // Handle Follow toggle
  void _handleFollowTap() {
    if (_followActive) {
      // Stop follow
      widget.rosBridge.deactivateFollowMode();
      widget.onFollowStop?.call();
      setState(() => _followOn = false);
    } else {
      // Start follow (stops other modes via rosbridge)
      widget.rosBridge.activateFollowMode();
      widget.onFollowStart?.call();
      setState(() {
        _followOn = true;
        _wanderOn = false;
        _trackActive = false;
      });
    }
    widget.onHide();
  }

  // Handle Track toggle (mutually exclusive with other modes)
  void _handleTrackTap() {
    if (_trackActive) {
      widget.rosBridge.publishCenterOnHuman(false);
      setState(() => _trackActive = false);
    } else {
      // Start track (stops other modes via rosbridge)
      widget.rosBridge.activateTrackMode();
      setState(() {
        _wanderOn = false;
        _followOn = false;
        _trackActive = true;
      });
    }
    widget.onHide();
  }

  // Handle Search toggle
  void _handleSearchTap() {
    if (widget.isSearchActive) {
      // Stop search
      widget.onSearchStop?.call();
    } else {
      // Start search (will prompt for target via AI)
      widget.onSearchStart?.call();
    }
    widget.onHide();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top Control Bar: Wander, Follow, Track, Search (toggle buttons)
        SafeArea(
          bottom: false,
          child: Container(
            margin: const EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              top: AppSpacing.lg,
            ),
            padding: const EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              top: AppSpacing.lg,
              bottom: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Wander button
                _ControlButton(
                  icon: _wanderActive ? Icons.explore_off : Icons.explore,
                  label: _wanderActive ? 'Stop' : 'Wander',
                  onTap: _handleWanderTap,
                  buttonColor: _wanderActive ? Colors.red : AppColors.dangerBright,
                ),
                // Follow button
                _ControlButton(
                  icon: _followActive ? Icons.person_off : Icons.person,
                  label: _followActive ? 'Stop' : 'Follow',
                  onTap: _handleFollowTap,
                  buttonColor: _followActive ? Colors.red : AppColors.success,
                ),
                // Track button
                _ControlButton(
                  icon: _trackActive ? Icons.center_focus_weak : Icons.center_focus_strong,
                  label: _trackActive ? 'Stop' : 'Track',
                  onTap: _handleTrackTap,
                  buttonColor: _trackActive ? Colors.red : AppColors.accent,
                ),
                // Search button (orange)
                _SearchButton(
                  isActive: widget.isSearchActive,
                  target: widget.searchTarget,
                  coverage: widget.searchCoverage,
                  onTap: _handleSearchTap,
                  buttonColor: AppColors.dangerBright,
                ),
              ],
            ),
          ),
        ),

        const Spacer(),

        // Bottom Control Bar with grey background
        SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              bottom: AppSpacing.lg,
            ),
            padding: const EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              top: AppSpacing.lg,
              bottom: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Refresh button
                _ControlButton(
                  icon: Icons.refresh,
                  label: 'Refresh',
                  onTap: widget.onRefresh,
                  buttonColor: AppColors.success,
                ),
                // Play/Pause button
                // Show Play when idle, paused, or sleeping; Pause when actively conversing
                if (widget.isIdle || widget.isPaused || widget.isSleeping)
                  _ControlButton(
                    icon: Icons.play_arrow,
                    label: widget.isSleeping ? 'Wake' : 'Play',
                    onTap: widget.onPlay,
                    buttonColor: AppColors.accent,
                  )
                else
                  _ControlButton(
                    icon: Icons.pause,
                    label: 'Pause',
                    onTap: widget.onPause,
                    buttonColor: AppColors.accent,
                  ),
                // Exit button
                _ControlButton(
                  icon: Icons.close,
                  label: 'Exit',
                  onTap: widget.onExit,
                  buttonColor: AppColors.dangerBright,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Colored circular control button with label
class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color buttonColor;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.buttonColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: buttonColor,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Search button with coverage overlay when active
class _SearchButton extends StatelessWidget {
  final bool isActive;
  final String? target;
  final int coverage;
  final VoidCallback onTap;
  final Color buttonColor;

  const _SearchButton({
    required this.isActive,
    required this.target,
    required this.coverage,
    required this.onTap,
    this.buttonColor = AppColors.dangerBright,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              // Background circle
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: isActive ? Colors.red : buttonColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isActive ? Icons.search_off : Icons.search,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              // Coverage overlay (circular progress) when active
              if (isActive)
                SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    value: coverage / 100.0,
                    strokeWidth: 3,
                    backgroundColor: Colors.white.withOpacity(0.2),
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            isActive
                ? (target != null ? '$coverage%' : 'Stop')
                : 'Search',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
