import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/rosbridge.dart';
import '../widgets/control_bar.dart';

/// Available facial expressions for the robot face
enum FaceExpression {
  neutral,    // Default: normal eyes, straight mouth
  smile,      // Normal eyes, curved-up mouth
  squint,     // Narrowed eyes (thinking/skeptical)
  surprised,  // Wide eyes, open mouth
  happy,      // Squinted eyes + smile (genuine happiness)
  thinking,   // Eyes looking up/aside, neutral mouth
}

/// Customer-facing order display with robot face and animated thought bubble
/// Face shrinks and slides down when thought bubble opens
/// Long-press to show control bar (like millie_mini FacePage)
class FacePage extends StatefulWidget {
  final RosBridge rosBridge;
  final VoidCallback onExit;
  final VoidCallback? onPause;
  final VoidCallback? onPlay;
  final VoidCallback? onRefresh;
  final VoidCallback? onNavigateLeft;   // Navigate to previous page (Chat)
  final VoidCallback? onNavigateRight;  // Navigate to next page (Notes)
  final VoidCallback? onSearchStart;
  final VoidCallback? onSearchStop;
  final bool isSearchActive;
  final String? searchTarget;
  final int searchCoverage;
  final String faceId;
  const FacePage({
    super.key,
    required this.rosBridge,
    required this.onExit,
    this.onPause,
    this.onPlay,
    this.onRefresh,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onSearchStart,
    this.onSearchStop,
    this.isSearchActive = false,
    this.searchTarget,
    this.searchCoverage = 0,
    this.faceId = '',
  });

  @override
  State<FacePage> createState() => FacePageState();
}

class FacePageState extends State<FacePage>
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


  // Blink animation
  late final AnimationController _blinkCtrl;
  late Animation<double> _blinkAnimation;  // 1.0 = open, 0.0 = closed
  Timer? _blinkTimer;
  final Random _random = Random();
  int _blinkCount = 0;

  // Expressive eye states (occasional)
  bool _isHappySquint = false;   // Rounded tops, shorter
  bool _isInvertedSquint = false; // Rounded bottoms, shorter
  Timer? _expressiveEyeTimer;
  bool _inExpressiveState = false;  // Pause blinking during expression
  bool _lastWasHappy = false;  // Alternate between happy and inverted

  // Expression animation
  late final AnimationController _expressionCtrl;
  FaceExpression _currentExpression = FaceExpression.smile;
  FaceExpression _targetExpression = FaceExpression.smile;
  double _eyeHeightMultiplier = 1.0;  // For squint/surprised
  double _smileAmount = 1.0;  // -1.0 (frown) to 1.0 (smile) - default to smile
  double _mouthOpenAmount = 0.0;  // 0.0 (closed) to 1.0 (open)
  
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
    
    // Blink animation controller (300ms total: 150ms close + 150ms open)
    _blinkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _blinkAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _blinkCtrl, curve: Curves.easeInOut));

    // Expression animation controller
    _expressionCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _expressionCtrl.addListener(_updateExpressionValues);

    // Start random blink timer
    _scheduleNextBlink();

    // Don't start animations in initState - wait for state changes
    // Animations are controlled by setListening/setSpeaking
  }

  /// Schedule the next random blink (3-7 seconds)
  void _scheduleNextBlink() {
    _blinkTimer?.cancel();
    final delay = 3000 + _random.nextInt(4000);  // 3-7 seconds
    _blinkTimer = Timer(Duration(milliseconds: delay), () {
      if (mounted && !_isPaused && !_isSleeping && !_inExpressiveState) {
        blink();
      }
      _scheduleNextBlink();
    });
  }

  /// Trigger a single blink animation
  void blink() {
    if (!mounted || _blinkCtrl.isAnimating || _inExpressiveState) return;

    _blinkCount++;

    // Every 3 blinks, do an expressive squint (with delay after the blink)
    if (_blinkCount >= 3) {
      _blinkCount = 0;
      // Do the 3rd blink first, then wait before changing eye shape
      _blinkCtrl.forward(from: 0.0).then((_) {
        if (!mounted) return;
        // Wait 1-2 seconds after the blink before expressive change
        Future.delayed(Duration(milliseconds: 1000 + _random.nextInt(1000)), () {
          if (!mounted || _inExpressiveState) return;
          // Alternate between happy (rounded top) and inverted (rounded bottom)
          if (_lastWasHappy) {
            _doInvertedSquint();
          } else {
            _doHappySquint();
          }
          _lastWasHappy = !_lastWasHappy;
        });
      });
    } else {
      _blinkCtrl.forward(from: 0.0);
    }
  }

  /// Do a happy squint: smoothly transition to rounded top eyes
  void _doHappySquint() {
    _inExpressiveState = true;
    setState(() => _isHappySquint = true);

    // Hold for 5 seconds
    _expressiveEyeTimer?.cancel();
    _expressiveEyeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _isHappySquint = false);
        // Keep expressive state locked for a bit after returning to normal
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _inExpressiveState = false;
        });
      }
    });
  }

  /// Do an inverted squint: smoothly transition to rounded bottom eyes
  void _doInvertedSquint() {
    _inExpressiveState = true;
    setState(() => _isInvertedSquint = true);

    // Hold for 5 seconds
    _expressiveEyeTimer?.cancel();
    _expressiveEyeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _isInvertedSquint = false);
        // Keep expressive state locked for a bit after returning to normal
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _inExpressiveState = false;
        });
      }
    });
  }

  /// Update expression values during animation
  void _updateExpressionValues() {
    if (!mounted) return;

    final t = _expressionCtrl.value;

    // Interpolate from current to target expression
    final currentHeight = _getEyeHeightForExpression(_currentExpression);
    final currentSmile = _getSmileAmountForExpression(_currentExpression);
    final currentOpen = _getMouthOpenForExpression(_currentExpression);

    final targetHeight = _getEyeHeightForExpression(_targetExpression);
    final targetSmile = _getSmileAmountForExpression(_targetExpression);
    final targetOpen = _getMouthOpenForExpression(_targetExpression);

    setState(() {
      _eyeHeightMultiplier = _lerpDouble(currentHeight, targetHeight, t);
      _smileAmount = _lerpDouble(currentSmile, targetSmile, t);
      _mouthOpenAmount = _lerpDouble(currentOpen, targetOpen, t);

      if (t >= 1.0) {
        _currentExpression = _targetExpression;
      }
    });
  }

  double _lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }

  double _getEyeHeightForExpression(FaceExpression expr) {
    switch (expr) {
      case FaceExpression.neutral:
        return 1.0;
      case FaceExpression.smile:
        return 1.0;
      case FaceExpression.squint:
        return 0.4;
      case FaceExpression.surprised:
        return 1.2;
      case FaceExpression.happy:
        return 0.5;  // Squinted eyes for genuine happiness
      case FaceExpression.thinking:
        return 0.85;
    }
  }

  double _getSmileAmountForExpression(FaceExpression expr) {
    switch (expr) {
      case FaceExpression.neutral:
        return 0.0;
      case FaceExpression.smile:
        return 1.0;
      case FaceExpression.squint:
        return 0.0;
      case FaceExpression.surprised:
        return 0.0;
      case FaceExpression.happy:
        return 1.0;
      case FaceExpression.thinking:
        return 0.0;
    }
  }

  double _getMouthOpenForExpression(FaceExpression expr) {
    switch (expr) {
      case FaceExpression.neutral:
        return 0.0;
      case FaceExpression.smile:
        return 0.0;
      case FaceExpression.squint:
        return 0.0;
      case FaceExpression.surprised:
        return 0.8;
      case FaceExpression.happy:
        return 0.0;
      case FaceExpression.thinking:
        return 0.0;
    }
  }

  /// Set the facial expression with smooth animation
  void setExpression(FaceExpression expression) {
    if (!mounted || expression == _targetExpression) return;

    _targetExpression = expression;
    _expressionCtrl.forward(from: 0.0);
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

  /// Set speaking state (animates mouth, eyes just blink)
  void setSpeaking(bool speaking) {
    if (!mounted) return;

    if (speaking) {
      _mouthCtrl.repeat(reverse: true);
    } else {
      _mouthCtrl.stop();
      _mouthCtrl.value = 0.0;
      // Return to smile when not speaking
      setExpression(FaceExpression.smile);
    }

    setState(() {
      _speaking = speaking;
      if (speaking) {
        _statusText = 'Speaking...';
      }
    });
  }

  /// Set paused state
  /// When pausing: stop all animations and show paused status
  /// When unpausing: don't change status - let setListening handle it
  void setPaused(bool paused) {
    if (!mounted) return;

    if (paused) {
      // Stop mouth animation when pausing
      _mouthCtrl.stop();
      _mouthCtrl.value = 0.0;

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

  /// Set listening state
  void setListening(bool listening) {
    if (!mounted) return;

    setState(() {
      _isListening = listening;
      if (listening) {
        _statusText = 'Listening...';
      }
      // Don't set Ready here - only setIdle(true) should show Ready
    });
  }

  /// Set processing state (squint expression)
  void setProcessing(bool processing) {
    if (!mounted) return;

    if (processing) {
      setExpression(FaceExpression.squint);
    } else {
      setExpression(FaceExpression.smile);
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
    // E-STOP: tap face to stop all robot movement immediately
    widget.rosBridge.publishEstop();

    // Also pause conversation if active
    if (!_isIdle) {
      widget.onPause?.call();
    }
    setState(() {
      _showControlBar = true;
    });
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

  void _hideControlBar() {
    setState(() {
      _showControlBar = false;
    });
  }

  void _handlePause() {
    widget.onPause?.call();
  }

  void _handlePlay() {
    _hideControlBar();
    widget.onPlay?.call();
  }

  void _handleRefresh() {
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
    _blinkTimer?.cancel();
    _expressiveEyeTimer?.cancel();
    _mouthCtrl.dispose();
    _thoughtCtrl.dispose();
    _blinkCtrl.dispose();
    _expressionCtrl.dispose();

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

    // Space between eyes and mouth (like millie_mini: screenHeight * 0.12)
    final eyeMouthGap = screenH * 0.12;

    return GestureDetector(
      onTap: _handleTap,
      onDoubleTap: _handleDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Animated eyes + mouth
            SafeArea(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(flex: 1),
                    _buildRobotFace(screenW, screenH, eyeMouthGap),
                    const Spacer(flex: 1),
                    const SizedBox(height: 50), // Space for status pill
                  ],
                ),
              ),
            ),
            // Status text
            Positioned(
              left: 0,
              right: 0,
              bottom: 20,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _statusText,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.8),
                      fontSize: 14,
                    ),
                  ),
                ),
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
                    rosBridge: widget.rosBridge,
                    onPause: _handlePause,
                    onPlay: _handlePlay,
                    onRefresh: _handleRefresh,
                    onExit: _handleExit,
                    onHide: _hideControlBar,
                    isPaused: _isPaused,
                    isSleeping: _isSleeping,
                    isIdle: _isIdle,
                    onSearchStart: widget.onSearchStart,
                    onSearchStop: widget.onSearchStop,
                    isSearchActive: widget.isSearchActive,
                    searchTarget: widget.searchTarget,
                    searchCoverage: widget.searchCoverage,
                  ),
                ],
              ),
            // Navigation arrows (grey circles) - rendered on top of overlay
            if (widget.onNavigateLeft != null && _showControlBar)
              Positioned(
                left: 16,
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: widget.onNavigateLeft,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chevron_left,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.onNavigateRight != null && _showControlBar)
              Positioned(
                right: 16,
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: widget.onNavigateRight,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chevron_right,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }


  Widget _buildRobotFace(double screenW, double screenH, double eyeMouthGap) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Eyes
        _buildEyes(screenW, screenH),
        // Space between eyes and mouth
        SizedBox(height: eyeMouthGap),
        // Mouth
        _buildMouth(screenW),
      ],
    );
  }

  Widget _buildEyes(double screenWidth, double screenHeight) {
    // Screen relative sizing
    final eyeWidth = screenWidth * 0.32;
    // Container height stays constant to prevent layout shifts
    final containerHeight = screenHeight * 0.28;
    // Actual eye height changes for expressive squints
    final baseEyeHeight = (_isHappySquint || _isInvertedSquint)
        ? screenHeight * 0.16
        : screenHeight * 0.28;
    final eyeGap = screenWidth * 0.06;

    return AnimatedBuilder(
      animation: _blinkCtrl,
      builder: (context, child) {
        // Dim when paused or sleeping
        final double opacity = (_isPaused || _isSleeping) ? 0.5 : 1.0;

        // Apply blink animation to eye height
        final blinkMultiplier = _blinkAnimation.value;
        // Apply expression-based height multiplier
        final eyeHeight = baseEyeHeight * _eyeHeightMultiplier * blinkMultiplier;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildEye(eyeWidth, containerHeight, eyeHeight, opacity),
            SizedBox(width: eyeGap),
            _buildEye(eyeWidth, containerHeight, eyeHeight, opacity),
          ],
        );
      },
    );
  }

  Widget _buildEye(double width, double containerHeight, double eyeHeight, double opacity) {
    // Normal: uniform rounded corners
    // Happy squint: very rounded tops, flatter bottoms
    // Inverted squint: flatter tops, very rounded bottoms
    double topRadius;
    double bottomRadius;

    if (_isHappySquint) {
      topRadius = width * 0.5;
      bottomRadius = width * 0.12;
    } else if (_isInvertedSquint) {
      topRadius = width * 0.12;
      bottomRadius = width * 0.5;
    } else {
      topRadius = width * 0.12;
      bottomRadius = width * 0.12;
    }

    // Fixed-size container so eye can animate without affecting layout
    return SizedBox(
      width: width,
      height: containerHeight,
      child: Center(
        child: Opacity(
          opacity: opacity,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            width: width,
            height: eyeHeight,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(topRadius),
                bottom: Radius.circular(bottomRadius),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.3),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMouth(double screenWidth) {
    final mouthWidth = screenWidth * 0.50;
    const closedHeight = 16.0;
    const maxHeight = 200.0;
    const itemHeight = 32.0;
    const paddingHeight = 40.0;  // Match actual padding: 16 top + 24 bottom

    // Simple: expand only when items exist
    final hasItems = _orderItems.isNotEmpty;
    final contentHeight = paddingHeight + (_orderItems.length * itemHeight);
    final targetHeight = hasItems
        ? contentHeight.clamp(closedHeight, maxHeight)
        : closedHeight;

    // Glow
    final glowIntensity = _speaking ? 0.5 : 0.2;

    // If we have order items, show the expandable container
    if (hasItems) {
      final isOpen = targetHeight > closedHeight;
      final topRadius = isOpen ? 20.0 : closedHeight / 2;
      final bottomRadius = isOpen ? 20.0 : closedHeight / 2;

      return AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutBack,
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
        child: ClipRRect(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(topRadius - 2),
            bottom: Radius.circular(bottomRadius - 2),
          ),
          child: _buildMouthContent(),
        ),
      );
    }

    // Otherwise, use CustomPainter for expression-based mouth
    // Fixed height container so mouth animation doesn't shift the face
    const mouthContainerHeight = 100.0;

    // Dim when paused or sleeping
    final mouthOpacity = (_isPaused || _isSleeping) ? 0.5 : 1.0;

    return AnimatedBuilder(
      animation: _mouthCtrl,
      builder: (context, child) {
        return Opacity(
          opacity: mouthOpacity,
          child: SizedBox(
            width: mouthWidth,
            height: mouthContainerHeight,
            child: Center(
              child: CustomPaint(
                painter: ExpressionMouthPainter(
                  smileAmount: _smileAmount,
                  openAmount: _mouthOpenAmount,
                  isSpeaking: _speaking,
                  speakingAnimation: _mouthCtrl.value,
                  isListening: _isListening && !_speaking,
                ),
                size: Size(mouthWidth, mouthContainerHeight),
              ),
            ),
          ),
        );
      },
    );
  }
  
  Widget _buildMouthContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(80, 16, 16, 24),  // 80 left padding
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,  // Left align
        children: _orderItems.map((item) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            item,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 20,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.left,
          ),
        )).toList(),
      ),
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

/// CustomPainter for expression-based mouth shapes
class ExpressionMouthPainter extends CustomPainter {
  final double smileAmount;  // -1.0 (frown) to 1.0 (smile)
  final double openAmount;   // 0.0 (closed) to 1.0 (open)
  final bool isSpeaking;
  final double speakingAnimation;  // 0.0 to 1.0, oscillates while speaking
  final bool isListening;  // Asymmetric "hmm" smirk

  ExpressionMouthPainter({
    required this.smileAmount,
    required this.openAmount,
    this.isSpeaking = false,
    this.speakingAnimation = 0.0,
    this.isListening = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final mouthWidth = size.width * 0.8;
    final halfWidth = mouthWidth / 2;

    if (isSpeaking) {
      // Speaking: keep the smile stroke line, add animated fill inside

      // First draw the smile stroke (same as default, with rounded ends)
      final strokePaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16.0
        ..strokeCap = StrokeCap.round;

      final curveHeight = 30.0;  // Same as smile
      final smilePath = Path();
      smilePath.moveTo(centerX - halfWidth, centerY);
      smilePath.quadraticBezierTo(
        centerX, centerY + curveHeight,
        centerX + halfWidth, centerY,
      );
      canvas.drawPath(smilePath, strokePaint);

      // Now draw filled mouth inside that animates
      final minDip = 5.0;
      final maxDip = 50.0;
      final bottomDip = minDip + (speakingAnimation * (maxDip - minDip));

      // Slight inset from the smile edges
      final inset = halfWidth * 0.05;
      final innerLeft = centerX - halfWidth + inset;
      final innerRight = centerX + halfWidth - inset;

      final fillPath = Path();

      // Top curve aligned with smile (but slightly below the stroke)
      fillPath.moveTo(innerLeft, centerY + 8);
      fillPath.quadraticBezierTo(
        centerX, centerY + curveHeight - 4,
        innerRight, centerY + 8,
      );

      // Bottom curve animates down
      fillPath.quadraticBezierTo(
        centerX, centerY + curveHeight + bottomDip,
        innerLeft, centerY + 8,
      );

      fillPath.close();
      canvas.drawPath(fillPath, paint);
    } else if (openAmount > 0.1) {
      // Open mouth (surprised) - draw an ellipse
      final mouthHeight = 20.0 + (openAmount * 50.0);
      final rect = Rect.fromCenter(
        center: Offset(centerX, centerY),
        width: mouthWidth * 0.6,
        height: mouthHeight,
      );
      canvas.drawOval(rect, paint);
    } else if (isListening) {
      // Listening: shorter left, more smirk on right
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 16.0;
      paint.strokeCap = StrokeCap.round;

      final path = Path();
      // Left starts much closer to center (shorter)
      path.moveTo(centerX - halfWidth * 0.3, centerY + 5);

      // Smooth curve biased right, higher end point
      path.quadraticBezierTo(
        centerX + halfWidth * 0.4,   // control point x (more right of center)
        centerY + 35,                 // control point y (deeper curve)
        centerX + halfWidth,          // end point x (full width on right)
        centerY - 18,                 // end point y (much higher on right)
      );

      canvas.drawPath(path, paint);
    } else {
      // Smile/neutral: curved line
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 16.0;
      paint.strokeCap = StrokeCap.round;

      final curveHeight = smileAmount * 30.0;  // Positive = smile up, negative = frown down

      final path = Path();
      path.moveTo(centerX - halfWidth, centerY);

      // Use quadratic bezier for the curve
      path.quadraticBezierTo(
        centerX,                    // control point x (center)
        centerY + curveHeight,      // control point y (curved up or down)
        centerX + halfWidth,        // end point x
        centerY,                    // end point y
      );

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(ExpressionMouthPainter oldDelegate) {
    return oldDelegate.smileAmount != smileAmount ||
           oldDelegate.openAmount != openAmount ||
           oldDelegate.isSpeaking != isSpeaking ||
           oldDelegate.speakingAnimation != speakingAnimation ||
           oldDelegate.isListening != isListening;
  }
}
