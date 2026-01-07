library sleep_service;

import 'dart:async';
import 'convo_master.dart';
import 'ai_service.dart';

/// ------------------------------------------------------------
/// TEXT NORMALIZATION + APPROX MATCH
/// ------------------------------------------------------------
String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), " ")
    .replaceAll(RegExp(r"\s+"), " ")
    .trim();

int _edit(String a, String b) {
  final m = a.length, n = b.length;
  if (m == 0) return n;
  if (n == 0) return m;
  if ((m - n).abs() > 2) return 99;
  final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
  for (var i = 0; i <= m; i++) dp[i][0] = i;
  for (var j = 0; j <= n; j++) dp[0][j] = j;
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      dp[i][j] = [
        dp[i - 1][j] + 1,        // delete
        dp[i][j - 1] + 1,        // insert
        dp[i - 1][j - 1] + cost, // substitute
      ].reduce((a, b) => a < b ? a : b);
    }
  }
  return dp[m][n];
}

bool _approx(String heard, List<String> targets, {int maxEd = 1}) {
  for (final t in targets) {
    if (heard == t) return true;
    if (heard.length <= 20 && t.length <= 20 && _edit(heard, t) <= maxEd) {
      return true;
    }
  }
  return false;
}

/// ------------------------------------------------------------
/// STRONGER, SIMPLER SLEEP DETECTION
/// ------------------------------------------------------------
bool isSleepMillie(String input) {
  final n = _norm(input);
  if (n.isEmpty) return false;

  // Direct sleep phrases
  const directPhrases = [
    'go to sleep',
    'time to sleep',
    'you can sleep',
    'sleep now',
    'enter sleep',
    'sleep mode',
    'quiet mode',
    'power down',
    'stop listening',
    'goodnight',
  ];

  for (final p in directPhrases) {
    if (_approx(n, [p], maxEd: 2)) return true;
  }

  // Token-based matching
  final toks = n.split(' ').where((w) => w.isNotEmpty).toList();

  const sleepWords = ['sleep', 'asleep', 'rest', 'nap', 'shutdown', 'power', 'down'];

  for (final w in toks) {
    if (_approx(w, sleepWords, maxEd: 1)) return true;
  }

  return false;
}

/// ------------------------------------------------------------
/// REALTIME SLEEP SERVICE
/// ------------------------------------------------------------
class SleepService {
  static bool _inFlight = false;
  static bool _isSleeping = false;

  static bool get isSleeping => _isSleeping;

  /// --------------------------------------------------------
  /// Trigger sleep inside realtime streaming
  /// --------------------------------------------------------
  static Future<void> triggerSleep(ConvoMaster cm) async {
    if (_inFlight) {
      cm.onStatus?.call('[Sleep] Already in-flight — ignoring');
      return;
    }

    _inFlight = true;

    try {
      cm.onStatus?.call('[Sleep] Triggered → shutting down realtime session');

      // Final goodbye spoken through OpenAI streaming
      AiService.instance.speakGoodbye(
        "Okay, bye for now. I will be here when you need me.",
      );

      // 🔥 FIXED: allow AI time to speak the goodbye before killing session
      await Future.delayed(const Duration(seconds: 2));

      await AiService.instance.stopSession();

      _isSleeping = true;

      await cm.forceSleep();

      cm.onStatus?.call('[Sleep] Completed — Millie is asleep');
    } catch (e) {
      cm.onStatus?.call('[Sleep] ERROR: $e');
    } finally {
      _inFlight = false;
    }
  }

  /// --------------------------------------------------------
  /// Called from WakeService when wake word is detected
  /// --------------------------------------------------------
  static void wakeUp() {
    _isSleeping = false;
  }
}
