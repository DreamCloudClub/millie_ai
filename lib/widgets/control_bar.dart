import 'package:flutter/material.dart';
import '../utils/constants.dart';

/// Control bar overlay for Face pages - matches millie_mini style
/// Top bar: Navigation buttons with grey background
/// Bottom bar: Control buttons with grey background
class ControlBar extends StatelessWidget {
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;
  final bool isPaused;
  final bool isSleeping;
  final bool isIdle;

  const ControlBar({
    super.key,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
    this.isPaused = false,
    this.isSleeping = false,
    this.isIdle = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
                  onTap: onRefresh,
                  buttonColor: AppColors.success,
                ),
                // Play/Pause button
                // Show Play when idle, paused, or sleeping; Pause when actively conversing
                if (isIdle || isPaused || isSleeping)
                  _ControlButton(
                    icon: Icons.play_arrow,
                    label: isSleeping ? 'Wake' : 'Play',
                    onTap: onPlay,
                    buttonColor: AppColors.accent,
                  )
                else
                  _ControlButton(
                    icon: Icons.pause,
                    label: 'Pause',
                    onTap: onPause,
                    buttonColor: AppColors.accent,
                  ),
                // Exit button
                _ControlButton(
                  icon: Icons.close,
                  label: 'Exit',
                  onTap: onExit,
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
