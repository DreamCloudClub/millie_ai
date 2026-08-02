import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/rosbridge.dart';

/// Simple fidget service - one timer, periodic movements when active
class FidgetService {
  final RosBridge _rosBridge;

  Timer? _timer;
  int _moveIndex = 0;

  // Movement parameters
  static const double _twistAmount = 0.015;
  static const double _nudgeAmount = 0.01;
  static const int _moveDurationMs = 7000;
  static const int _intervalSeconds = 30;

  // Simple sequence of moves
  final List<String> _moves = ['right', 'left', 'back', 'forward'];

  FidgetService(this._rosBridge);

  /// Start fidgeting - call when conversation becomes active
  void start() {
    if (_timer != null) return;

    debugPrint('🤖 [Fidget] Started - every ${_intervalSeconds}s');
    _timer = Timer.periodic(Duration(seconds: _intervalSeconds), (_) {
      _doFidget();
    });
  }

  /// Stop fidgeting - call when conversation ends
  void stop() {
    _timer?.cancel();
    _timer = null;
    _rosBridge.publishCmdVel(0, 0);
    debugPrint('🤖 [Fidget] Stopped');
  }

  void _doFidget() {
    final move = _moves[_moveIndex];
    _moveIndex = (_moveIndex + 1) % _moves.length;

    debugPrint('🤖 [Fidget] $move');

    switch (move) {
      case 'left':
        _rosBridge.publishCmdVel(-_twistAmount, 0);
        break;
      case 'right':
        _rosBridge.publishCmdVel(_twistAmount, 0);
        break;
      case 'forward':
        _rosBridge.publishCmdVel(0, -_nudgeAmount);
        break;
      case 'back':
        _rosBridge.publishCmdVel(0, _nudgeAmount);
        break;
    }

    // Stop after duration
    Future.delayed(Duration(milliseconds: _moveDurationMs), () {
      _rosBridge.publishCmdVel(0, 0);
    });
  }

  void dispose() => stop();
}
