import 'package:flutter/material.dart';
import '../utils/constants.dart';

/// The selected view in the main content area
enum MainView { launch, locations, settings }

/// Bottom navigation bar for face tablet (portrait mode)
class IconRail extends StatelessWidget {
  final MainView selectedView;
  final ValueChanged<MainView> onViewChanged;
  final VoidCallback onEstop;
  final VoidCallback onShutdown;
  final VoidCallback onReboot;
  final bool rosConnected;
  final VoidCallback? onSettingsSidebarToggle;

  const IconRail({
    super.key,
    required this.selectedView,
    required this.onViewChanged,
    required this.onEstop,
    required this.onShutdown,
    required this.onReboot,
    this.rosConnected = false,
    this.onSettingsSidebarToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 12),
      color: AppColors.background,
      child: Stack(
        children: [
          // Left: E-STOP button
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(child: _EstopButton(onPressed: onEstop)),
          ),
          
          // Center: Navigation buttons (truly centered)
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _NavButton(
                  icon: Icons.smart_toy,
                  label: 'Launch',
                  isActive: selectedView == MainView.launch,
                  onPressed: () => onViewChanged(MainView.launch),
                ),
                const SizedBox(width: AppSpacing.lg),
                _NavButton(
                  icon: Icons.assignment,
                  label: 'Tasks',
                  isActive: selectedView == MainView.locations,
                  onPressed: () => onViewChanged(MainView.locations),
                ),
                const SizedBox(width: AppSpacing.lg),
                _NavButton(
                  icon: Icons.settings,
                  label: 'Settings',
                  isActive: selectedView == MainView.settings,
                  onPressed: () {
                    if (selectedView == MainView.settings && onSettingsSidebarToggle != null) {
                      onSettingsSidebarToggle!();
                    } else {
                      onViewChanged(MainView.settings);
                    }
                  },
                ),
              ],
            ),
          ),
          
          // Right: Connection indicator + Power button
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ConnectionIndicator(connected: rosConnected),
                  const SizedBox(width: AppSpacing.sm),
                  _PowerButton(onShutdown: onShutdown, onReboot: onReboot),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Connection status indicator
class _ConnectionIndicator extends StatelessWidget {
  final bool connected;
  
  const _ConnectionIndicator({required this.connected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: (connected ? AppColors.success : AppColors.textMuted).withOpacity(0.2),
        borderRadius: BorderRadius.circular(AppRadius.medium),
        border: Border.all(
          color: connected ? AppColors.success : AppColors.border,
          width: 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: connected ? AppColors.success : AppColors.textMuted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            connected ? 'ON' : 'OFF',
            style: TextStyle(
              color: connected ? AppColors.success : AppColors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// E-STOP button - prominent, always accessible
class _EstopButton extends StatelessWidget {
  final VoidCallback onPressed;
  
  const _EstopButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: AppColors.danger,
          borderRadius: BorderRadius.circular(AppRadius.medium),
          border: Border.all(color: AppColors.dangerBright, width: 2),
          boxShadow: [
            BoxShadow(
              color: AppColors.danger.withOpacity(0.4),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: const Center(
          child: Icon(
            Icons.stop_circle,
            color: Colors.white,
            size: 32,
          ),
        ),
      ),
    );
  }
}

/// Navigation button for bottom bar
class _NavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onPressed;

  const _NavButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: isActive 
              ? AppColors.accent.withOpacity(0.2) 
              : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.medium),
          border: Border.all(
            color: isActive ? AppColors.accent : AppColors.border,
            width: isActive ? 2 : 1,
          ),
        ),
        child: Center(
          child: Icon(
            icon,
            color: isActive ? AppColors.accent : AppColors.textSecondary,
            size: 28,
          ),
        ),
      ),
    );
  }
}

/// Power button with options modal
class _PowerButton extends StatelessWidget {
  final VoidCallback onShutdown;
  final VoidCallback onReboot;
  
  const _PowerButton({required this.onShutdown, required this.onReboot});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showPowerOptionsDialog(context),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.medium),
          border: Border.all(color: AppColors.border, width: 1),
        ),
        child: const Center(
          child: Icon(
            Icons.power_settings_new,
            color: AppColors.textSecondary,
            size: 28,
          ),
        ),
      ),
    );
  }

  void _showPowerOptionsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        title: const Text(
          'Power Options',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () {
                Navigator.pop(context);
                _confirmShutdown(context);
              },
              child: Container(
                width: double.infinity,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.danger.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  border: Border.all(
                    color: AppColors.danger.withOpacity(0.5),
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.power_settings_new, color: AppColors.danger, size: 24),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'Shutdown',
                      style: TextStyle(
                        color: AppColors.danger,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            GestureDetector(
              onTap: () {
                Navigator.pop(context);
                _confirmReboot(context);
              },
              child: Container(
                width: double.infinity,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  border: Border.all(
                    color: AppColors.accent.withOpacity(0.5),
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.restart_alt, color: AppColors.accent, size: 24),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'Reboot',
                      style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _confirmShutdown(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        title: const Text(
          'Confirm Shutdown',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will safely power off the robot computer.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
            ),
            onPressed: () {
              Navigator.pop(context);
              onShutdown();
            },
            child: const Text('Shutdown', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _confirmReboot(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        title: const Text(
          'Confirm Reboot',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will restart the robot computer.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
            ),
            onPressed: () {
              Navigator.pop(context);
              onReboot();
            },
            child: const Text('Reboot', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
