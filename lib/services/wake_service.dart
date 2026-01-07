import 'dart:async';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';

import 'sleep_service.dart';

typedef WakeCallback = Future<void> Function();

class WakeService {
  static final WakeService instance = WakeService._();
  WakeService._();

  PorcupineManager? _manager;
  bool _initialized = false;
  bool _isListening = false;

  bool get isListening => _isListening;

  // Prevent multiple triggers
  bool _wakeDebounce = false;

  // For avoiding wake during shutdown transitions
  bool _isTransitioning = false;

  Future<void> init({
    required WakeCallback onWake,
    double sensitivity = 0.55,
  }) async {
    if (_initialized) return;

    final accessKey = dotenv.env['PICOVOICE_ACCESS_KEY'];
    if (accessKey == null || accessKey.isEmpty) {
      throw Exception('PICOVOICE_ACCESS_KEY missing in .env');
    }

    try {
      final keywordPath = 'assets/millie_android.ppn';
      print('[Wake] init() loading keyword: $keywordPath');

      _manager = await PorcupineManager.fromKeywordPaths(
        accessKey,
        [keywordPath],
        (int index) async {
          // Avoid triggering during transition or rapid double-trigger
          if (_isTransitioning || _wakeDebounce) return;

          _wakeDebounce = true;
          Future.delayed(const Duration(milliseconds: 550), () {
            _wakeDebounce = false;
          });

          print('[Wake] Wake word detected');

          // prevent overlap while switching
          _isTransitioning = true;

          try {
            // wake robot from sleep mode
            SleepService.wakeUp();

            // stop porcupine before realtime mic takes over
            await stop();

            // start conversation (greeting comes from default action)
            await onWake();
          } catch (err) {
            print('[Wake] onWake() error: $err');
          } finally {
            _isTransitioning = false;
          }
        },
        sensitivities: [sensitivity],
      );

      _initialized = true;
      print('[Wake] init() complete');

    } on PorcupineException catch (e) {
      throw Exception('Porcupine init failed: ${e.message}');
    }
  }

  // ----------------------------------------------------
  // Start listening
  // ----------------------------------------------------
  Future<void> start() async {
    if (!_initialized || _manager == null) {
      throw Exception('WakeService.init() must be called before start()');
    }

    if (_isListening) return;

    print('[Wake] start()');

    try {
      await _manager!.start();
      _isListening = true;
      print('[Wake] Listening for "Millie"...');
    } catch (e) {
      print('[Wake] Failed to start: $e');
    }
  }

  // ----------------------------------------------------
  // Stop listening
  // ----------------------------------------------------
  Future<void> stop() async {
    if (!_isListening || _manager == null) return;

    print('[Wake] stop()');

    try {
      await _manager!.stop();
    } catch (e) {
      print('[Wake] stop() error: $e');
    }

    _isListening = false;
  }

  // ----------------------------------------------------
  // Dispose everything cleanly
  // ----------------------------------------------------
  Future<void> dispose() async {
    print('[Wake] dispose()');

    try {
      if (_isListening) {
        await _manager?.stop();
      }
      await _manager?.delete();
    } catch (e) {
      print('[Wake] dispose() error: $e');
    }

    _manager = null;
    _initialized = false;
    _isListening = false;
  }
}
