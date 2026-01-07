import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/constants.dart';
import '../widgets/control_bar.dart';

/// Customer-facing order display with robot face and animated thought bubble
/// Face shrinks and slides down when thought bubble opens
/// Long-press to show control bar (like millie_mini FacePage)
class OrderDisplayPage extends StatefulWidget {
  final VoidCallback onExit;
  final VoidCallback? onPause;
  final VoidCallback? onPlay;
  final VoidCallback? onRefresh;
  final VoidCallback? onTickets;  // Navigate to tickets page
  
  const OrderDisplayPage({
    super.key,
    required this.onExit,
    this.onPause,
    this.onPlay,
    this.onRefresh,
    this.onTickets,
  });

  @override
  State<OrderDisplayPage> createState() => OrderDisplayPageState();
}

class OrderDisplayPageState extends State<OrderDisplayPage>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  
  @override
  bool get wantKeepAlive => true;
  // Mouth animation
  late final AnimationController _mouthCtrl;
  bool _speaking = false;
  bool _isPaused = false;
  bool _isSleeping = false;
  bool _isListening = false;
  bool _isProcessing = false;
  bool _isIdle = true;  // True when no active conversation
  String _statusText = 'Ready';  // Idle state like millie_mini
  
  // Control bar overlay
  bool _showControlBar = false;
  
  // Thought bubble animation (controls face shrink + bubble expand)
  late final AnimationController _thoughtCtrl;
  bool _showThought = false;
  
  // Order items (processed by LLM, not raw transcript)
  final List<String> _orderItems = [];
  
  // Face stays the same size now - just show bubble above
  double get _faceScale => 1.0;  // No shrinking
  double get _faceOffset => 0.0;  // No offset
  
  // Eye animations (glowing effects)
  late final AnimationController _pulseCtrl;   // For speaking
  late final AnimationController _breathCtrl;  // For listening
  late Animation<double> _pulseAnimation;
  late Animation<double> _breathAnimation;
  late Animation<double> _opacityAnimation;
  
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

    // Thought bubble animation (smooth spring-like curve)
    _thoughtCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _thoughtCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    
    // Pulse animation for speaking (subtle scale) - like millie_mini
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    
    // Breath animation for listening (subtle scale + opacity) - like millie_mini
    _breathCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _breathAnimation = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _breathCtrl, curve: Curves.easeInOut),
    );
    _opacityAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _breathCtrl, curve: Curves.easeInOut),
    );
    
    // Don't start animations in initState - wait for state changes
    // Animations are controlled by setListening/setSpeaking
  }

  /// Open thought bubble and shrink face
  void openThoughtBubble() {
    if (_showThought) return;
    setState(() {
      _showThought = true;
      // Don't set status here - let speaking/listening state handle it
    });
    _thoughtCtrl.forward(from: 0.0);
  }

  /// Close thought bubble and restore face
  void closeThoughtBubble() {
    _thoughtCtrl.reverse().then((_) {
      if (mounted) {
        setState(() {
          _showThought = false;
          _orderItems.clear();
          _statusText = 'Ready';
        });
      }
    });
  }

  /// Add a processed order item (from LLM)
  void addOrderItem(String item) {
    setState(() {
      _orderItems.add(item);
    });
  }

  /// Clear all order items
  void clearOrder() {
    setState(() {
      _orderItems.clear();
    });
  }

  /// Set speaking state (animates mouth and eyes)
  void setSpeaking(bool speaking) {
    if (!mounted) return;
    
    // Stop all eye animations first (like millie_mini)
    _pulseCtrl.stop();
    _breathCtrl.stop();
    
    if (speaking) {
      _mouthCtrl.repeat();
      // Start pulse animation for speaking
      _pulseCtrl.repeat(reverse: true);
    } else {
      _mouthCtrl.stop();
      _mouthCtrl.value = 0.0;
      // Don't auto-start breath here - let setListening handle it
    }
    
      setState(() {
        _speaking = speaking;
      if (speaking) {
        _statusText = 'Speaking...';
        }
      // Don't change status when speaking stops - let setListening handle it
      });
  }

  /// Set paused state
  /// When pausing: stop all animations and show paused status
  /// When unpausing: don't change status - let setListening handle it
  void setPaused(bool paused) {
    if (!mounted) return;
    
    if (paused) {
      // Stop all animations when pausing
      _mouthCtrl.stop();
      _mouthCtrl.value = 0.0;
      _pulseCtrl.stop();
      _breathCtrl.stop();
      
      setState(() {
        _isPaused = true;
        _speaking = false;  // Clear speaking state
        _isListening = false;  // Clear listening state
        _isProcessing = false;  // Clear processing state
        _statusText = 'Paused';
      });
    } else {
      setState(() {
        _isPaused = false;
        // When unpausing, don't set status to 'Ready' - the listening callback will set 'Listening...'
        // This matches millie_mini behavior where resume goes directly to listening state
      });
    }
  }

  /// Set sleeping state
  void setSleeping(bool sleeping) {
    if (mounted) {
      setState(() {
        _isSleeping = sleeping;
        _statusText = sleeping ? 'Ready' : 'Ready';  // Both are idle states
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

  /// Set listening state (like millie_mini)
  void setListening(bool listening) {
    if (!mounted) return;
    
    // Stop all eye animations first
    _pulseCtrl.stop();
    _breathCtrl.stop();
    
    if (listening && !_speaking) {
      // Start breathing animation for listening
      _breathCtrl.repeat(reverse: true);
    }
    
    setState(() {
      _isListening = listening;
      if (listening) {
        _statusText = 'Listening...';
      } else if (!_speaking && !_isProcessing) {
        _statusText = 'Ready';
      }
    });
  }

  /// Set processing state (like millie_mini - static, fully bright)
  void setProcessing(bool processing) {
    if (!mounted) return;
    
    if (processing) {
      // Stop all animations - static bright
      _pulseCtrl.stop();
      _breathCtrl.stop();
    }
    
    setState(() {
      _isProcessing = processing;
      if (processing) {
        _statusText = 'Thinking...';
      }
    });
  }

  /// Update status text
  void setStatus(String status) {
    if (mounted) {
      setState(() => _statusText = status);
    }
  }

  void _handleTap() {
    // Single tap could be used for interaction
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
    closeThoughtBubble();
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
    _thoughtCtrl.dispose();
    _pulseCtrl.dispose();
    _breathCtrl.dispose();
    
    // Restore top bar when disposing
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    );
    
    super.dispose();
  }

  @override
  @override
  Widget build(BuildContext context) {
    super.build(context);  // Required for AutomaticKeepAliveClientMixin
    
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    
    // Mouth no longer bounces - just uses glow animation like millie_mini

    // Eased animation value
    final animValue = Curves.easeOutBack.transform(_thoughtCtrl.value);
    
    // Space between eyes and mouth (like millie_mini: screenHeight * 0.12)
    final eyeMouthGap = screenH * 0.12;

    return GestureDetector(
      onTap: _handleTap,
      onDoubleTap: _handleDoubleTap,
      onLongPress: _handleLongPress,
      behavior: HitTestBehavior.opaque,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              // Main content - centered like millie_mini
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Spacer above face
                    const Spacer(flex: 1),
                    
                    // Face (stays same size now)
                    Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Eyes
                            _buildEyes(screenW, screenH),
                            
                        // Space between eyes and mouth
                        SizedBox(height: eyeMouthGap),
                            
                            // Mouth
                        _buildMouth(screenW),
                          ],
                    ),
                    
                    // Spacer below face
                    const Spacer(flex: 1),
                    
                    // Status text at bottom
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Text(
                        _statusText,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 14,
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
                    // Backdrop that closes on tap (semi-transparent)
                    GestureDetector(
                      onTap: _hideControlBar,
                      child: Container(
                        color: Colors.black.withOpacity(0.5),
                      ),
                    ),
                    // Control bar (top nav + bottom controls)
                    ControlBar(
                      onPause: _handlePause,
                      onPlay: _handlePlay,
                      onRefresh: _handleRefresh,
                      onExit: _handleExit,
                      onTickets: widget.onTickets,
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



  /// Get base opacity based on current state
  double get _baseOpacity {
    if (_isPaused || _isSleeping) return 0.7;
    return 1.0;
  }

  /// Get glow intensity based on current state
  double get _glowIntensity {
    if (_isPaused || _isSleeping) return 0.2;
    if (_isListening) return 0.4;
    if (_isProcessing) return 0.5;
    if (_speaking) return 0.6;
    return 0.3;
  }

  Widget _buildEyes(double screenWidth, double screenHeight) {
    // Use millie_mini proportions - screen relative sizing
    final eyeWidth = screenWidth * 0.32;
    final eyeHeight = screenHeight * 0.28;
    final eyeGap = screenWidth * 0.06;

    return AnimatedBuilder(
      animation: Listenable.merge([_pulseCtrl, _breathCtrl]),
      builder: (context, child) {
        double scale = 1.0;
        double opacity = _baseOpacity;
        
        if (_speaking) {
          scale = _pulseAnimation.value;
        } else if (_isListening && !_isPaused && !_isSleeping) {
          scale = _breathAnimation.value;
          opacity = _opacityAnimation.value;
        }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
            _buildEye(eyeWidth, eyeHeight, scale, opacity),
            SizedBox(width: eyeGap),
            _buildEye(eyeWidth, eyeHeight, scale, opacity),
          ],
        );
      },
    );
  }

  Widget _buildEye(double width, double height, double scale, double opacity) {
    final borderRadius = width * 0.12;  // Slightly rounder
    final glowIntensity = _glowIntensity;

    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: opacity,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(borderRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.white.withOpacity(glowIntensity),
                blurRadius: 20 * glowIntensity * 2,
                spreadRadius: 5 * glowIntensity,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMouth(double screenWidth) {
    final mouthWidth = screenWidth * 0.50;
    const closedHeight = 16.0;
    const maxHeight = 200.0;  // Max height before scrolling
    const itemHeight = 28.0;  // Approx height per item (font + padding)
    const paddingHeight = 20.0;  // Top + bottom padding
    
    // Calculate dynamic height based on items
    final shouldExpand = _showThought && _orderItems.isNotEmpty;
    final contentHeight = paddingHeight + (_orderItems.length * itemHeight);
    final targetHeight = shouldExpand 
        ? contentHeight.clamp(closedHeight, maxHeight)
        : closedHeight;
    
    // Glow intensity based on speaking state
    final glowIntensity = _speaking ? (0.3 + 0.3 * _mouthCtrl.value) : 0.2;
    final opacity = _speaking ? 1.0 : 0.8;
    
    // Border radius - pill when closed, nicely rounded when open (like eyes)
    final openProgress = shouldExpand ? ((targetHeight - closedHeight) / (maxHeight - closedHeight)).clamp(0.0, 1.0) : 0.0;
    final topRadius = closedHeight / 2 + (20 - closedHeight / 2) * openProgress;  // Grows to 20
    final bottomRadius = closedHeight / 2 + (20 - closedHeight / 2) * openProgress;  // Grows to 20

    return Opacity(
      opacity: opacity,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: shouldExpand ? Curves.easeOutBack : Curves.easeInBack,
        width: mouthWidth,
        height: targetHeight,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(topRadius),
            bottom: Radius.circular(bottomRadius),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.white.withOpacity(glowIntensity),
              blurRadius: 15,
              spreadRadius: 2,
            ),
          ],
        ),
        child: shouldExpand
            ? ClipRRect(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(topRadius - 2),
                  bottom: Radius.circular(bottomRadius - 2),
                ),
                child: _buildTicketContent(),
              )
            : null,
      ),
    );
  }
  
  Widget _buildTicketContent() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: _orderItems.length,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            _orderItems[index],
            style: const TextStyle(
              color: Colors.black,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }
}

/// Pulsing recording indicator dot
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.5 + 0.5 * _controller.value),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.blue.withOpacity(0.4 * _controller.value),
                blurRadius: 10,
                spreadRadius: 3,
              ),
            ],
          ),
        );
      },
    );
  }
}
