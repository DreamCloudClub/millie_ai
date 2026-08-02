import 'package:flutter/material.dart';
import '../utils/constants.dart';

/// Simple control bar with 3 buttons: Refresh, Play/Pause, Exit
/// Used on non-face pages (notes, schedule, identity)
class SimpleControlBar extends StatelessWidget {
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;
  final bool isPaused;

  const SimpleControlBar({
    super.key,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
    this.isPaused = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
            label: 'Reset',
            onTap: onRefresh,
            buttonColor: Colors.green,
          ),

          // Play/Pause button
          if (!isPaused)
            _ControlButton(
              icon: Icons.pause,
              label: 'Pause',
              onTap: onPause,
              buttonColor: Colors.blue,
            )
          else
            _ControlButton(
              icon: Icons.play_arrow,
              label: 'Play',
              onTap: onPlay,
              buttonColor: Colors.blue,
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
    );
  }
}

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
