// lib/services/convo_master.dart
library convo_master;

import 'dart:async';
import 'package:flutter/foundation.dart';

import 'wake_service.dart';
import 'ai_service.dart';
import '../agents/agent_manager.dart';
import 'sleep_service.dart' as sleep;

class ConvoMaster {
  ConvoMaster({
    required this.wake,
    this.onSpeaking,
    this.onUserText,
    this.onBotText,
    this.onStatus,
  }) {
    // Connect AiService callbacks to ConvoMaster
    AiService.instance.onSpeaking = notifySpeaking;
    AiService.instance.onUserText = _handleUserText;
    AiService.instance.onBotText = _handleBotText;

  }

  final WakeService wake;
  final void Function(bool)? onSpeaking;
  final void Function(String)? onUserText;
  final void Function(String)? onBotText;
  final void Function(String)? onStatus;

  bool _running = false;
  bool get isRunning => _running;

  final _history = <Map<String, String>>[];

  void Function(bool)? _onSpeaking;
  void Function(String)? _onUserText;
  void Function(String)? _onBotText;
  void Function(String)? _onStatus;

  void attachCallbacks({
    void Function(bool)? onSpeaking,
    void Function(String)? onUserText,
    void Function(String)? onBotText,
    void Function(String)? onStatus,
  }) {
    if (onSpeaking != null) _onSpeaking = onSpeaking;
    if (onUserText != null) _onUserText = onUserText;
    if (onBotText != null) _onBotText = onBotText;
    if (onStatus != null) _onStatus = onStatus;
  }

  void notifySpeaking(bool speaking) {
    (_onSpeaking ?? onSpeaking)?.call(speaking);
  }

  // ---------------------------------------------------------
  // Start realtime conversation
  // ---------------------------------------------------------
  Future<void> start() async {
    if (_running) return;
    _running = true;

    try {
      await wake.stop();
      await Future.delayed(const Duration(milliseconds: 250));
    } catch (_) {}

    // ⭐ IMMEDIATE LOCAL GREETING (UI ONLY)
    final greeting = AgentManager.instance.greeting;
    (_onBotText ?? onBotText)?.call(greeting);

    _history
      ..clear()
      ..add(AgentManager.instance.personaMessage);

    (_onStatus ?? onStatus)
        ?.call('[Convo] started as ${AgentManager.instance.activeId}');

    // Start WebRTC realtime session
    await AiService.instance.startSession();

    // Make sure data channel is ready
    await Future.delayed(const Duration(milliseconds: 150));

    // Greeting audio already played in WakeService before session starts
  }

  // ---------------------------------------------------------
  // Handle user text (STREAMING INPUT)
  // ---------------------------------------------------------
  void _handleUserText(String text) {
    if (!_running) return;
    if (text.trim().isEmpty) return;

    // ⭐ FIRST: Detect sleep BEFORE forwarding message to AI
    if (sleep.isSleepMillie(text)) {
      (_onStatus ?? onStatus)
          ?.call('[Sleep] Phrase detected — intercepting');
      sleep.SleepService.triggerSleep(this);
      return; // 🚫 DO NOT send message to AI
    }

    // Normal conversation flow
    _history.add({'role': 'user', 'content': text});
    (_onUserText ?? onUserText)?.call(text);
    (_onStatus ?? onStatus)?.call('[User] $text');
  }

  // ---------------------------------------------------------
  void _handleBotText(String text) {
    if (!_running) return;

    _history.add({'role': 'assistant', 'content': text});

    (_onBotText ?? onBotText)?.call(text);
    (_onStatus ?? onStatus)?.call('[Bot] $text');
  }

  // ---------------------------------------------------------
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    await AiService.instance.stopSession();

    (_onStatus ?? onStatus)?.call('[Convo] stopped');
  }

  // ---------------------------------------------------------
  Future<void> forceSleep() async {
    _running = false;

    await AiService.instance.stopSession();

    _history.clear();

    await wake.start();

    (_onStatus ?? onStatus)?.call('[Convo] sleep mode entered');
  }
}
