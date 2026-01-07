import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/eyes_widget.dart';
import '../widgets/mouth_widget.dart';
import '../widgets/control_bar.dart';
import '../utils/constants.dart';

/// Face display page - shows robot's animated face
/// Long-press to show control bar overlay
class FacePage extends StatefulWidget {
  final VoidCallback onExit;
  final VoidCallback? onPause;
  final VoidCallback? onPlay;
  final VoidCallback? onRefresh;

  const FacePage({
    super.key,
    required this.onExit,
    this.onPause,
    this.onPlay,
    this.onRefresh,
  });

  @override
  State<FacePage> createState() => FacePageState();
}

class FacePageState extends State<FacePage>
    with SingleTickerProviderStateMixin {
  bool _speaking = false;
  bool _isPaused = false;
  bool _isSleeping = false;
  bool _isIdle = true;  // True when no active conversation
  bool _showControlBar = false;
  late final AnimationController _mouthCtrl;
  String _statusText = 'Ready';

  @override
  void initState() {
    super.initState();

    // Full immersive mode for face display - hide all bars
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Mouth animation controller
    _mouthCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );

    _mouthCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  /// Called when voice service indicates speaking state
  void setSpeaking(bool speaking) {
    if (speaking) {
      _mouthCtrl.repeat();
    } else {
      _mouthCtrl.stop();
      _mouthCtrl.value = 0.0;
    }

    if (mounted) {
      setState(() {
        _speaking = speaking;
        _statusText = speaking ? 'Speaking...' : 'Listening';
      });
    }
  }

  /// Set paused state
  void setPaused(bool paused) {
    if (mounted) {
      setState(() {
        _isPaused = paused;
        _statusText = paused ? 'Paused' : 'Listening';
      });
    }
  }

  /// Set sleeping state
  void setSleeping(bool sleeping) {
    if (mounted) {
      setState(() {
        _isSleeping = sleeping;
        _statusText = sleeping ? 'Sleeping' : 'Listening';
      });
    }
  }

  /// Set idle state (no active conversation)
  void setIdle(bool idle) {
    if (mounted) {
      setState(() {
        _isIdle = idle;
        if (idle && !_isPaused) {
          _statusText = 'Ready';
        }
      });
    }
  }

  /// Update status text
  void setStatus(String status) {
    if (mounted) {
      setState(() => _statusText = status);
    }
  }

  void _handleTap() {
    // Single tap - could be used for wake or other interaction
  }

  void _handleDoubleTap() {
    // Double tap behavior:
    // - Idle → Start conversation
    // - Active (listening/speaking) → Pause
    // - Paused → Unpause
    if (_isIdle) {
      // Start new conversation
      widget.onPlay?.call();
    } else if (_isPaused) {
      // Unpause
      widget.onPlay?.call();
    } else {
      // Active conversation - pause it
      widget.onPause?.call();
    }
  }

  void _handleLongPress() {
    setState(() {
      _showControlBar = true;
    });
  }

  void _hideControlBar() {
    setState(() {
      _showControlBar = false;
    });
  }

  void _handlePause() {
    _hideControlBar();
    widget.onPause?.call();
  }

  void _handlePlay() {
    _hideControlBar();
    widget.onPlay?.call();
  }

  void _handleRefresh() {
    _hideControlBar();
    widget.onRefresh?.call();
  }

  void _handleExit() {
    _hideControlBar();
    
    // Restore top bar when exiting face
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    );
    
    widget.onExit();
  }

  @override
  void dispose() {
    _mouthCtrl.dispose();
    
    // Restore top bar when disposing
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    );
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    
    final mouthOpen = _speaking
        ? (0.5 + 0.5 * math.sin(2 * math.pi * _mouthCtrl.value))
        : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _handleTap,
        onDoubleTap: _handleDoubleTap,
        onLongPress: _handleLongPress,
        behavior: HitTestBehavior.opaque,
        child: SafeArea(
          child: Stack(
            children: [
              // Main Face Content
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(flex: 1),
                    
                    // Eyes
                    const EyesWidget(),
                    
                    SizedBox(height: screenH * 0.12),
                    
                    // Mouth
                    MouthWidget(
                      openAmount: mouthOpen,
                      baseWidth: screenW * 0.4,
                      height: 30,
                      extraWidth: 12,
                      radius: 28,
                      color: Colors.white,
                    ),
                    
                    const Spacer(flex: 1),
                    
                    // Status text
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                      child: Text(
                        _statusText,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withOpacity(0.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              
              // Control Bar Overlay
              if (_showControlBar)
                Stack(
                  children: [
                    // Backdrop that closes on tap
                    GestureDetector(
                      onTap: _hideControlBar,
                      child: Container(
                        color: Colors.black.withOpacity(0.5),
                      ),
                    ),
                    // Control bar (bottom controls only - no onTickets)
                        ControlBar(
                          onPause: _handlePause,
                          onPlay: _handlePlay,
                          onRefresh: _handleRefresh,
                          onExit: _handleExit,
                          isPaused: _isPaused,
                          isSleeping: _isSleeping,
                          isIdle: _isIdle,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
