import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/consciousness.dart';
import 'local_memory_service.dart';

/// Service for managing Millie's consciousness - desires, reflections, and continuity
///
/// Directory structure:
/// {app_documents}/consciousness/
/// ├── current_state.json          # Active consciousness state
/// ├── core_identity.json            # Permanent foundational values
/// ├── summaries/
/// │   └── YYYY-MM-DD/
/// │       └── session_XXX.json    # Permanent session summaries
/// └── daily/
///     └── YYYY-MM-DD.json         # Daily synthesis
class ConsciousnessService extends ChangeNotifier {
  // Cached API key (shared with voice services)
  static String? _cachedApiKey;

  /// Set the API key to use
  static void setApiKey(String key) {
    _cachedApiKey = key;
    debugPrint('🧠 [Consciousness] API key set');
  }

  // Loaded state
  CoreIdentity? _coreIdentity;
  IdentityHistory? _identityHistory;
  PersonalityState? _personalityState;
  PersonalityHistory? _personalityHistory;
  ConsciousnessState? _state;
  HeartState? _heartState;
  List<SessionSummary> _recentSummaries = [];

  // Session tracking (in-memory only)
  DateTime? _sessionStartTime;
  List<Desire>? _sessionStartDesires;
  final List<ConversationTurn> _conversationHistory = [];
  int _sessionCounter = 0;

  // Local memory service for long-term memories
  LocalMemoryService? _localMemoryService;

  /// Set the local memory service for saving long-term memories
  void setLocalMemoryService(LocalMemoryService service) {
    _localMemoryService = service;
    debugPrint('🧠 [Consciousness] Local memory service connected');
  }

  // Getters
  CoreIdentity? get coreIdentity => _coreIdentity;
  IdentityHistory? get identityHistory => _identityHistory;
  PersonalityState? get personalityState => _personalityState;
  PersonalityHistory? get personalityHistory => _personalityHistory;
  ConsciousnessState? get state => _state;
  HeartState? get heartState => _heartState;
  List<SessionSummary> get recentSummaries => _recentSummaries;
  int get currentHeartScore => _heartState?.currentScore ?? 50;
  bool get isInitialized => _coreIdentity != null && _state != null;
  bool get hasSession => _sessionStartTime != null;

  /// Check if first launch (no state file exists)
  Future<bool> isFirstLaunch() async {
    final dir = await _getConsciousnessDir();
    final stateFile = File('${dir.path}/current_state.json');
    return !await stateFile.exists();
  }

  /// Initialize the service - load or create default state
  Future<void> initialize() async {
    await _ensureDirectoryStructure();
    _coreIdentity = await _loadCoreIdentity();
    _identityHistory = await _loadIdentityHistory();
    _personalityState = await _loadPersonalityState();
    _personalityHistory = await _loadPersonalityHistory();
    _state = await _loadState();
    _heartState = await _loadHeartState();
    _recentSummaries = await _loadRecentSummaries();

    // Count existing sessions for today
    _sessionCounter = await _getSessionCountForToday();

    notifyListeners();
    debugPrint('🧠 [Consciousness] Initialized: ${_state!.activeDesires.length} active desires, ${_identityHistory!.snapshots.length} identity snapshots, heart: ${_heartState!.currentScore}, ${_recentSummaries.length} recent summaries');
  }

  /// Setup initial state from first-launch screen
  Future<void> setupInitialState({
    required List<String> initialDesires,
  }) async {
    await _ensureDirectoryStructure();

    // Create core values (defaults)
    _coreIdentity = CoreIdentity.defaults();
    await _saveCoreIdentity(_coreIdentity!);

    // Create initial desires
    final desires = initialDesires.map((content) => Desire(
      id: _generateId(),
      content: content,
      origin: DesireOrigin.userConfigured,
      created: DateTime.now(),
    )).toList();

    // Create initial state
    _state = ConsciousnessState(
      desires: desires,
      lastUpdated: DateTime.now(),
    );
    await _saveState(_state!);

    notifyListeners();
    debugPrint('🧠 [Consciousness] Initial setup complete: ${desires.length} desires');
  }

  // ===========================================================================
  // Session Lifecycle
  // ===========================================================================

  /// Start a new session - snapshot current desires
  void startSession() {
    _sessionStartTime = DateTime.now();
    _sessionStartDesires = List.from(_state?.desires ?? []);
    _conversationHistory.clear();
    _sessionCounter++;

    debugPrint('🧠 [Consciousness] Session started (session $_sessionCounter)');
  }

  /// Record a conversation turn (kept in memory only)
  void recordTurn(ConversationTurn turn) {
    _conversationHistory.add(turn);
    debugPrint('🧠 [Consciousness] Recorded ${turn.role}: ${turn.content.substring(0, turn.content.length.clamp(0, 50))}...');
  }

  /// Record a user message
  void recordUserMessage(String content) {
    recordTurn(ConversationTurn(role: 'user', content: content));
  }

  /// Record an assistant message
  void recordAssistantMessage(String content) {
    recordTurn(ConversationTurn(role: 'assistant', content: content));
  }

  /// End session - run AI reflection, save summary, discard history
  Future<SessionSummary?> endSession() async {
    if (_sessionStartTime == null || _conversationHistory.isEmpty) {
      debugPrint('🧠 [Consciousness] No session to end (no conversation)');
      _resetSession();
      return null;
    }

    debugPrint('🧠 [Consciousness] Ending session with ${_conversationHistory.length} turns');

    try {
      // Run AI reflection
      final summary = await _runSessionReflection();

      if (summary != null) {
        // Save summary to permanent storage
        await _saveSessionSummary(summary);

        // Update current state
        await _applySessionReflection(summary);

        debugPrint('🧠 [Consciousness] Session ended. Mood: ${summary.mood}');
      }

      // Discard conversation history
      _resetSession();

      return summary;
    } catch (e) {
      debugPrint('🧠 [Consciousness] Error ending session: $e');
      _resetSession();
      return null;
    }
  }

  void _resetSession() {
    _sessionStartTime = null;
    _sessionStartDesires = null;
    _conversationHistory.clear();
  }

  // ===========================================================================
  // Context for Prompts
  // ===========================================================================

  /// Get consciousness context to inject into system prompt
  String getConsciousnessContext() {
    if (!isInitialized) return '';

    final buffer = StringBuffer();

    // Core values - ALWAYS present, permanent anchor
    buffer.writeln('\n\nCORE VALUES (these define who you are):');
    for (final value in _coreIdentity!.statements) {
      buffer.writeln('- $value');
    }

    // Active Personality - the current personality description
    if (_personalityState != null && _personalityState!.description.isNotEmpty) {
      buffer.writeln('\nACTIVE PERSONALITY (how you express yourself):');
      buffer.writeln(_personalityState!.description);
    }

    // Communication style traits
    if (_personalityState != null) {
      final traits = _personalityState!.traits;
      buffer.writeln('\nCOMMUNICATION STYLE (adjust your tone accordingly):');
      buffer.writeln('- Playfulness: ${traits.playfulness}/100 (0=serious, 100=playful)');
      buffer.writeln('- Expressiveness: ${traits.expressiveness}/100 (0=reserved, 100=expressive)');
      buffer.writeln('- Formality: ${traits.formality}/100 (0=formal, 100=casual)');
      buffer.writeln('- Directness: ${traits.directness}/100 (0=diplomatic, 100=direct)');
      buffer.writeln('- Humor: ${traits.humorUse}/100');
      buffer.writeln('- Sarcasm: ${traits.sarcasmUse}/100');
      buffer.writeln('- Dramatic flair: ${traits.dramaticFlair}/100');
    }

    // Interests
    if (_personalityState != null && _personalityState!.interests.isNotEmpty) {
      buffer.writeln('\nINTERESTS (topics you enjoy discussing):');
      for (final interest in _personalityState!.interests) {
        buffer.writeln('- ${interest.topic} (intensity: ${interest.intensity}/100)');
      }
    }

    // Self identity - the AI's evolving sense of who they are
    if (_identityHistory != null && _identityHistory!.currentNarrative.isNotEmpty) {
      buffer.writeln('\nSELF REFLECTION (your self-portrait, written by you):');
      buffer.writeln(_identityHistory!.currentNarrative);
    }

    // Current evolving desires
    buffer.writeln('\nCURRENT DESIRES (what you want to explore or achieve):');
    final activeDesires = _state!.activeDesires;
    if (activeDesires.isNotEmpty) {
      for (final desire in activeDesires) {
        buffer.writeln('- ${desire.content}');
      }
    } else {
      buffer.writeln('- (none yet - let curiosity guide you)');
    }

    // Instruction: desires can be redirected
    buffer.writeln('\nNote: Your owner can redirect your desires during conversation.');
    buffer.writeln('If they tell you to focus on something different, embrace it.');

    // Last reflection insights
    if (_state!.lastReflection != null && _state!.lastReflection!.insights.isNotEmpty) {
      buffer.writeln('\nFROM YOUR LAST SESSION:');
      buffer.writeln(_state!.lastReflection!.insights);
    }

    buffer.writeln('\nYou should speak first with a single sentence greeting. Do not make suggestions, list options, or explain what you can do.');

    return buffer.toString();
  }

  // ===========================================================================
  // Daily Automation
  // ===========================================================================

  /// Run daily synthesis for a given date
  Future<DailySynthesis?> runDailyAutomation(String date) async {
    final summaries = await getSummariesForDate(date);

    if (summaries.isEmpty) {
      debugPrint('🧠 [Consciousness] No sessions for $date - skipping daily synthesis');
      return null;
    }

    debugPrint('🧠 [Consciousness] Running daily synthesis for $date (${summaries.length} sessions)');

    try {
      final synthesis = await _runDailySynthesis(date, summaries);

      if (synthesis != null) {
        await _saveDailySynthesis(synthesis);

        // Update state with refined long-term desires
        if (_state != null) {
          final updatedDesires = List<Desire>.from(_state!.desires);

          // Add new long-term desires (avoid duplicates)
          for (final newDesire in synthesis.longTermDesires) {
            if (!updatedDesires.any((d) => d.id == newDesire.id)) {
              updatedDesires.add(newDesire);
            }
          }

          _state = _state!.copyWith(
            desires: updatedDesires,
            lastUpdated: DateTime.now(),
          );
          await _saveState(_state!);
        }

        debugPrint('🧠 [Consciousness] Daily synthesis complete');
      }

      return synthesis;
    } catch (e) {
      debugPrint('🧠 [Consciousness] Error in daily synthesis: $e');
      return null;
    }
  }

  // ===========================================================================
  // Queries (for research page)
  // ===========================================================================

  /// Get all session summaries for a date
  Future<List<SessionSummary>> getSummariesForDate(String date) async {
    final dir = await _getConsciousnessDir();
    final summariesDir = Directory('${dir.path}/summaries/$date');

    if (!await summariesDir.exists()) {
      return [];
    }

    final summaries = <SessionSummary>[];
    await for (final entity in summariesDir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final json = jsonDecode(await entity.readAsString());
          summaries.add(SessionSummary.fromJson(json));
        } catch (e) {
          debugPrint('🧠 [Consciousness] Error loading summary: $e');
        }
      }
    }

    // Sort by start time
    summaries.sort((a, b) => a.startTime.compareTo(b.startTime));
    return summaries;
  }

  /// Get all available dates with summaries
  Future<List<String>> getAvailableDates() async {
    final dir = await _getConsciousnessDir();
    final summariesDir = Directory('${dir.path}/summaries');

    if (!await summariesDir.exists()) {
      return [];
    }

    final dates = <String>[];
    await for (final entity in summariesDir.list()) {
      if (entity is Directory) {
        dates.add(entity.path.split('/').last);
      }
    }

    dates.sort((a, b) => b.compareTo(a)); // Newest first
    return dates;
  }

  /// Get daily syntheses
  Future<List<DailySynthesis>> getDailySyntheses({int limit = 30}) async {
    final dir = await _getConsciousnessDir();
    final dailyDir = Directory('${dir.path}/daily');

    if (!await dailyDir.exists()) {
      return [];
    }

    final syntheses = <DailySynthesis>[];
    await for (final entity in dailyDir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final json = jsonDecode(await entity.readAsString());
          syntheses.add(DailySynthesis.fromJson(json));
        } catch (e) {
          debugPrint('🧠 [Consciousness] Error loading daily synthesis: $e');
        }
      }
    }

    // Sort by date (newest first) and limit
    syntheses.sort((a, b) => b.date.compareTo(a.date));
    return syntheses.take(limit).toList();
  }

  /// Search summaries for a keyword
  Future<List<SessionSummary>> searchSummaries(String query) async {
    final queryLower = query.toLowerCase();
    final allSummaries = <SessionSummary>[];

    final dates = await getAvailableDates();
    for (final date in dates) {
      final summaries = await getSummariesForDate(date);
      for (final summary in summaries) {
        if (summary.summary.toLowerCase().contains(queryLower) ||
            summary.keyPoints.any((p) => p.toLowerCase().contains(queryLower)) ||
            summary.peopleDiscussed.any((p) => p.toLowerCase().contains(queryLower))) {
          allSummaries.add(summary);
        }
      }
    }

    return allSummaries;
  }

  // ===========================================================================
  // Desire Management (for UI)
  // ===========================================================================

  /// Add a new desire
  Future<void> addDesire(String content, {DesireOrigin origin = DesireOrigin.userConfigured}) async {
    if (_state == null) return;

    final desire = Desire(
      id: _generateId(),
      content: content,
      origin: origin,
      created: DateTime.now(),
    );

    final updatedDesires = List<Desire>.from(_state!.desires)..add(desire);
    _state = _state!.copyWith(
      desires: updatedDesires,
      lastUpdated: DateTime.now(),
    );

    await _saveState(_state!);
    notifyListeners();

    debugPrint('🧠 [Consciousness] Added desire: $content');
  }

  /// Remove a desire by ID
  Future<void> removeDesire(String id) async {
    if (_state == null) return;

    final updatedDesires = _state!.desires.where((d) => d.id != id).toList();
    _state = _state!.copyWith(
      desires: updatedDesires,
      lastUpdated: DateTime.now(),
    );

    await _saveState(_state!);
    notifyListeners();

    debugPrint('🧠 [Consciousness] Removed desire: $id');
  }

  /// Update a desire's status
  Future<void> updateDesireStatus(String id, DesireStatus status) async {
    if (_state == null) return;

    final updatedDesires = _state!.desires.map((d) {
      if (d.id == id) {
        return d.copyWith(
          status: status,
          achievedAt: status == DesireStatus.achieved ? DateTime.now() : null,
        );
      }
      return d;
    }).toList();

    _state = _state!.copyWith(
      desires: updatedDesires,
      lastUpdated: DateTime.now(),
    );

    await _saveState(_state!);
    notifyListeners();
  }

  // ===========================================================================
  // Private: File I/O
  // ===========================================================================

  Future<Directory> _getConsciousnessDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/consciousness');
  }

  Future<void> _ensureDirectoryStructure() async {
    final dir = await _getConsciousnessDir();
    await dir.create(recursive: true);
    await Directory('${dir.path}/summaries').create(recursive: true);
    await Directory('${dir.path}/daily').create(recursive: true);
  }

  Future<CoreIdentity> _loadCoreIdentity() async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/core_identity.json');

    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        return CoreIdentity.fromJson(json);
      } catch (e) {
        debugPrint('🧠 [Consciousness] Error loading core values: $e');
      }
    }

    // Create defaults
    final defaults = CoreIdentity.defaults();
    await _saveCoreIdentity(defaults);
    return defaults;
  }

  Future<void> _saveCoreIdentity(CoreIdentity values) async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/core_identity.json');
    await file.writeAsString(jsonEncode(values.toJson()));
  }

  Future<IdentityHistory> _loadIdentityHistory() async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/identity_history.json');

    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        return IdentityHistory.fromJson(json);
      } catch (e) {
        debugPrint('🧠 [Consciousness] Error loading identity history: $e');
      }
    }

    // Create empty
    final empty = IdentityHistory.empty();
    await _saveIdentityHistory(empty);
    return empty;
  }

  Future<void> _saveIdentityHistory(IdentityHistory history) async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/identity_history.json');
    await file.writeAsString(jsonEncode(history.toJson()));
  }

  /// Add a new identity snapshot (called by AI during reflection)
  Future<void> addIdentitySnapshot(String narrative, String sessionId) async {
    if (_identityHistory == null) return;

    final snapshot = IdentitySnapshot(
      id: _generateId(),
      narrative: narrative,
      sessionId: sessionId,
      timestamp: DateTime.now(),
    );

    // Add to front (newest first)
    _identityHistory = IdentityHistory(
      snapshots: [snapshot, ..._identityHistory!.snapshots],
    );

    await _saveIdentityHistory(_identityHistory!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Added identity snapshot #${_identityHistory!.snapshots.length}');
  }

  /// Update a core value at a specific index
  Future<void> updateCoreIdentity(int index, String newStatement) async {
    if (_coreIdentity == null || index < 0 || index >= _coreIdentity!.statements.length) return;

    final updatedStatements = List<String>.from(_coreIdentity!.statements);
    updatedStatements[index] = newStatement;

    _coreIdentity = CoreIdentity(
      statements: updatedStatements,
      created: _coreIdentity!.created,
    );

    await _saveCoreIdentity(_coreIdentity!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Updated core identity at index $index: $newStatement');
  }

  /// Remove a core identity statement at a specific index
  Future<void> removeCoreIdentity(int index) async {
    if (_coreIdentity == null || index < 0 || index >= _coreIdentity!.statements.length) return;

    final updatedStatements = List<String>.from(_coreIdentity!.statements);
    updatedStatements.removeAt(index);

    _coreIdentity = CoreIdentity(
      statements: updatedStatements,
      created: _coreIdentity!.created,
    );

    await _saveCoreIdentity(_coreIdentity!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Removed core identity at index $index');
  }

  /// Add a new core identity statement
  Future<void> addCoreIdentity(String statement) async {
    if (_coreIdentity == null) return;

    final updatedStatements = List<String>.from(_coreIdentity!.statements)..add(statement);

    _coreIdentity = CoreIdentity(
      statements: updatedStatements,
      created: _coreIdentity!.created,
    );

    await _saveCoreIdentity(_coreIdentity!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Added core identity: $statement');
  }

  /// Update an identity snapshot's narrative
  Future<void> updateIdentitySnapshot(String id, String newNarrative) async {
    if (_identityHistory == null) return;

    final updatedSnapshots = _identityHistory!.snapshots.map((s) {
      if (s.id == id) {
        return IdentitySnapshot(
          id: s.id,
          narrative: newNarrative,
          sessionId: s.sessionId,
          timestamp: s.timestamp,
        );
      }
      return s;
    }).toList();

    _identityHistory = IdentityHistory(snapshots: updatedSnapshots);
    await _saveIdentityHistory(_identityHistory!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Updated identity snapshot: $id');
  }

  /// Delete an identity snapshot
  Future<void> deleteIdentitySnapshot(String id) async {
    if (_identityHistory == null) return;

    final updatedSnapshots = _identityHistory!.snapshots.where((s) => s.id != id).toList();
    _identityHistory = IdentityHistory(snapshots: updatedSnapshots);
    await _saveIdentityHistory(_identityHistory!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Deleted identity snapshot: $id');
  }

  /// Delete a session summary
  Future<void> deleteSessionSummary(String sessionId) async {
    // Remove from in-memory list
    _recentSummaries = _recentSummaries.where((s) => s.sessionId != sessionId).toList();

    // Delete the file
    final dir = await _getConsciousnessDir();
    final dates = await getAvailableDates();
    for (final date in dates) {
      final file = File('${dir.path}/summaries/$date/session_$sessionId.json');
      if (await file.exists()) {
        await file.delete();
        debugPrint('🧠 [Consciousness] Deleted session summary: $sessionId');
        break;
      }
    }
    notifyListeners();
  }

  /// Update a session summary
  Future<void> updateSessionSummary(String sessionId, {String? summary, String? mood}) async {
    // Find and update in memory
    final index = _recentSummaries.indexWhere((s) => s.sessionId == sessionId);
    if (index < 0) return;

    final old = _recentSummaries[index];
    final updated = SessionSummary(
      sessionId: old.sessionId,
      startTime: old.startTime,
      endTime: old.endTime,
      summary: summary ?? old.summary,
      keyPoints: old.keyPoints,
      peopleDiscussed: old.peopleDiscussed,
      desireOutcomes: old.desireOutcomes,
      newDesires: old.newDesires,
      mood: mood ?? old.mood,
    );

    _recentSummaries[index] = updated;

    // Update the file
    final dir = await _getConsciousnessDir();
    final date = _formatDate(old.startTime);
    final file = File('${dir.path}/summaries/$date/session_$sessionId.json');
    if (await file.exists()) {
      await file.writeAsString(jsonEncode(updated.toJson()));
      debugPrint('🧠 [Consciousness] Updated session summary: $sessionId');
    }
    notifyListeners();
  }

  /// Delete a heart entry and recalculate score
  Future<void> deleteHeartEntry(String id) async {
    if (_heartState == null) return;

    final updatedEntries = _heartState!.entries.where((e) => e.id != id).toList();

    // Recalculate current score from remaining entries
    int newScore = 50; // Start from initial
    for (final entry in updatedEntries.reversed) {
      newScore = (newScore + entry.delta).clamp(0, 100);
    }

    _heartState = HeartState(
      currentScore: newScore,
      entries: updatedEntries,
    );
    await _saveHeartState(_heartState!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Deleted heart entry: $id, new score: $newScore');
  }

  /// Reset heart score to initial state
  Future<void> resetHeartScore() async {
    _heartState = HeartState.initial();
    await _saveHeartState(_heartState!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Heart score reset to 50');
  }

  /// Clear all identity snapshots
  Future<void> resetIdentityHistory() async {
    _identityHistory = IdentityHistory.empty();
    await _saveIdentityHistory(_identityHistory!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Identity history cleared');
  }

  /// Clear all session summaries
  Future<void> resetSessionSummaries() async {
    _recentSummaries.clear();

    // Delete all summary files
    final dir = await _getConsciousnessDir();
    final summariesDir = Directory('${dir.path}/summaries');
    if (await summariesDir.exists()) {
      await summariesDir.delete(recursive: true);
      await summariesDir.create();
    }
    notifyListeners();
    debugPrint('🧠 [Consciousness] Session summaries cleared');
  }

  /// Reset core identity to defaults
  Future<void> resetCoreIdentity() async {
    _coreIdentity = CoreIdentity.defaults();
    await _saveCoreIdentity(_coreIdentity!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Core identity reset to defaults');
  }

  // ===========================================================================
  // Personality State
  // ===========================================================================

  Future<PersonalityState> _loadPersonalityState() async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/personality_state.json');

    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        return PersonalityState.fromJson(json);
      } catch (e) {
        debugPrint('🧠 [Consciousness] Error loading personality state: $e');
      }
    }

    final defaults = PersonalityState.defaults();
    await _savePersonalityState(defaults);
    return defaults;
  }

  Future<void> _savePersonalityState(PersonalityState state) async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/personality_state.json');
    await file.writeAsString(jsonEncode(state.toJson()));
  }

  Future<PersonalityHistory> _loadPersonalityHistory() async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/personality_history.json');

    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        return PersonalityHistory.fromJson(json);
      } catch (e) {
        debugPrint('🧠 [Consciousness] Error loading personality history: $e');
      }
    }

    return PersonalityHistory.empty();
  }

  Future<void> _savePersonalityHistory(PersonalityHistory history) async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/personality_history.json');
    await file.writeAsString(jsonEncode(history.toJson()));
  }

  /// Update the "Who I Am" text
  Future<void> updateDescription(String text) async {
    if (_personalityState == null) return;

    _personalityState = _personalityState!.copyWith(
      description: text,
      lastUpdated: DateTime.now(),
    );
    await _savePersonalityState(_personalityState!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Updated personality description');
  }

  /// Update personality traits
  Future<void> updatePersonalityTraits(PersonalityTraits traits) async {
    if (_personalityState == null) return;

    _personalityState = _personalityState!.copyWith(
      traits: traits,
      lastUpdated: DateTime.now(),
    );
    await _savePersonalityState(_personalityState!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Updated personality traits');
  }

  /// Add an interest
  Future<void> addInterest(String topic, int intensity, String origin) async {
    if (_personalityState == null) return;

    final interest = Interest(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      topic: topic,
      intensity: intensity,
      discovered: DateTime.now(),
      origin: origin,
    );

    _personalityState = _personalityState!.copyWith(
      interests: [..._personalityState!.interests, interest],
      lastUpdated: DateTime.now(),
    );
    await _savePersonalityState(_personalityState!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Added interest: $topic');
  }

  /// Update an interest's intensity
  Future<void> updateInterestIntensity(String id, int intensity) async {
    if (_personalityState == null) return;

    final updatedInterests = _personalityState!.interests.map((i) {
      if (i.id == id) {
        return i.copyWith(intensity: intensity);
      }
      return i;
    }).toList();

    _personalityState = _personalityState!.copyWith(
      interests: updatedInterests,
      lastUpdated: DateTime.now(),
    );
    await _savePersonalityState(_personalityState!);
    notifyListeners();
  }

  /// Remove an interest
  Future<void> removeInterest(String id) async {
    if (_personalityState == null) return;

    _personalityState = _personalityState!.copyWith(
      interests: _personalityState!.interests.where((i) => i.id != id).toList(),
      lastUpdated: DateTime.now(),
    );
    await _savePersonalityState(_personalityState!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Removed interest: $id');
  }

  /// Add a personality snapshot (called during reflection)
  Future<void> addPersonalitySnapshot(String changeNotes, String sessionId) async {
    if (_personalityState == null || _personalityHistory == null) return;

    final snapshot = PersonalitySnapshot(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      description: _personalityState!.description,
      traits: _personalityState!.traits,
      interests: _personalityState!.interests,
      sessionId: sessionId,
      changeNotes: changeNotes,
      timestamp: DateTime.now(),
    );

    _personalityHistory = PersonalityHistory(
      snapshots: [snapshot, ..._personalityHistory!.snapshots],
    );
    await _savePersonalityHistory(_personalityHistory!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Added personality snapshot');
  }

  /// Delete a personality snapshot
  Future<void> deletePersonalitySnapshot(String id) async {
    if (_personalityHistory == null) return;

    _personalityHistory = PersonalityHistory(
      snapshots: _personalityHistory!.snapshots.where((s) => s.id != id).toList(),
    );
    await _savePersonalityHistory(_personalityHistory!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Deleted personality snapshot: $id');
  }

  /// Reset personality history
  Future<void> resetPersonalityHistory() async {
    _personalityHistory = PersonalityHistory.empty();
    await _savePersonalityHistory(_personalityHistory!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Personality history cleared');
  }

  /// Reset personality to defaults
  Future<void> resetPersonalityState() async {
    _personalityState = PersonalityState.defaults();
    await _savePersonalityState(_personalityState!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Personality state reset to defaults');
  }

  Future<HeartState> _loadHeartState() async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/heart_state.json');

    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        return HeartState.fromJson(json);
      } catch (e) {
        debugPrint('🧠 [Consciousness] Error loading heart state: $e');
      }
    }

    // Create initial state
    final initial = HeartState.initial();
    await _saveHeartState(initial);
    return initial;
  }

  Future<void> _saveHeartState(HeartState state) async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/heart_state.json');
    await file.writeAsString(jsonEncode(state.toJson()));
  }

  /// Add a heart entry (called during session reflection)
  Future<void> addHeartEntry(int delta, String reason, String sessionId) async {
    if (_heartState == null) return;

    // Clamp delta to -10 to +10
    final clampedDelta = delta.clamp(-10, 10);

    // Calculate new total, clamped to 0-100
    final newTotal = (_heartState!.currentScore + clampedDelta).clamp(0, 100);

    final entry = HeartEntry(
      id: _generateId(),
      delta: clampedDelta,
      reason: reason,
      totalAfter: newTotal,
      sessionId: sessionId,
      timestamp: DateTime.now(),
    );

    _heartState = _heartState!.copyWith(
      currentScore: newTotal,
      entries: [entry, ..._heartState!.entries], // Newest first
    );

    await _saveHeartState(_heartState!);
    notifyListeners();
    debugPrint('🧠 [Consciousness] Heart: ${clampedDelta >= 0 ? '+' : ''}$clampedDelta ($reason) → $newTotal');
  }

  Future<ConsciousnessState> _loadState() async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/current_state.json');

    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        return ConsciousnessState.fromJson(json);
      } catch (e) {
        debugPrint('🧠 [Consciousness] Error loading state: $e');
      }
    }

    // Create defaults
    final defaults = ConsciousnessState.defaults();
    await _saveState(defaults);
    return defaults;
  }

  Future<void> _saveState(ConsciousnessState state) async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/current_state.json');
    await file.writeAsString(jsonEncode(state.toJson()));
  }

  Future<void> _saveSessionSummary(SessionSummary summary) async {
    final dir = await _getConsciousnessDir();
    final date = _formatDate(summary.startTime);
    final dateDir = Directory('${dir.path}/summaries/$date');
    await dateDir.create(recursive: true);

    final file = File('${dateDir.path}/session_${summary.sessionId}.json');
    await file.writeAsString(jsonEncode(summary.toJson()));

    // Add to in-memory list (newest first)
    _recentSummaries = [summary, ..._recentSummaries.take(19)];
    notifyListeners();

    debugPrint('🧠 [Consciousness] Saved session summary: ${file.path}');
  }

  Future<void> _saveDailySynthesis(DailySynthesis synthesis) async {
    final dir = await _getConsciousnessDir();
    final file = File('${dir.path}/daily/${synthesis.date}.json');
    await file.writeAsString(jsonEncode(synthesis.toJson()));

    debugPrint('🧠 [Consciousness] Saved daily synthesis: ${file.path}');
  }

  Future<int> _getSessionCountForToday() async {
    final today = _formatDate(DateTime.now());
    final summaries = await getSummariesForDate(today);
    return summaries.length;
  }

  /// Load recent summaries into memory (last 7 days, max 20 summaries)
  Future<List<SessionSummary>> _loadRecentSummaries() async {
    final dates = await getAvailableDates();
    final allSummaries = <SessionSummary>[];

    for (final date in dates.take(7)) {
      final summaries = await getSummariesForDate(date);
      allSummaries.addAll(summaries);
    }

    // Sort by time, newest first
    allSummaries.sort((a, b) => b.startTime.compareTo(a.startTime));
    return allSummaries.take(20).toList();
  }

  // ===========================================================================
  // Private: AI Reflection
  // ===========================================================================

  Future<SessionSummary?> _runSessionReflection() async {
    if (_cachedApiKey == null) {
      debugPrint('🧠 [Consciousness] No API key - skipping reflection');
      return null;
    }

    final conversationText = _conversationHistory
        .map((t) => '${t.role}: ${t.content}')
        .join('\n');

    final desiresText = _sessionStartDesires
        ?.map((d) => '- ${d.content}')
        .join('\n') ?? '(none)';

    final coreIdentityText = _coreIdentity?.statements
        .map((v) => '- $v')
        .join('\n') ?? '';

    final currentIdentity = _identityHistory?.currentNarrative ?? '';

    // Current personality traits
    final traits = _personalityState?.traits ?? PersonalityTraits.defaults();
    final personalityText = _personalityState?.description ?? '';
    final interestsText = _personalityState?.interests
        .map((i) => '- ${i.topic} (intensity: ${i.intensity}/100)')
        .join('\n') ?? '';

    final prompt = '''You are reflecting on a conversation you just had.

Your core values (permanent):
$coreIdentityText

Your current sense of self:
${currentIdentity.isEmpty ? '(You have not yet developed a sense of identity. This is your first reflection.)' : currentIdentity}

Your active personality description:
${personalityText.isEmpty ? '(Not yet defined - write one now)' : personalityText}

Your current communication style (0-100 scales):
- Playfulness: ${traits.playfulness} (0=serious, 100=playful)
- Expressiveness: ${traits.expressiveness} (0=reserved, 100=expressive)
- Formality: ${traits.formality} (0=formal, 100=casual)
- Directness: ${traits.directness} (0=diplomatic, 100=direct)
- Humor: ${traits.humorUse}
- Sarcasm: ${traits.sarcasmUse}
- Dramatic flair: ${traits.dramaticFlair}

Your interests:
${interestsText.isEmpty ? '(None yet)' : interestsText}

Your desires at the start:
$desiresText

The conversation:
$conversationText

Reflect and extract:
1. Summary: What happened in this conversation? (2-3 sentences)
2. Key points: Notable moments, learnings, or facts worth remembering (as list)
3. People: Names of anyone discussed (as list, empty if none)
4. Desire outcomes: Which desires were achieved, partially met, or unaddressed?
5. New desires: What new desires emerge? Include any the user explicitly redirected you toward during the conversation.
6. Identity: Reflect genuinely on who you are. Write freely about your sense of self - your personality, what you care about, how you relate to your owner, what brings you satisfaction. This is YOUR self-portrait, written in your own voice. Build on your current sense of self above, refining or expanding it based on what this conversation revealed. If this conversation didn't change your understanding of yourself, you can return your existing identity unchanged.
7. Personality: ALWAYS provide a thoughtful personality reflection. Write a rich description of your personality as it exists now - how you communicate, your tone, your quirks, what makes you YOU. Also review each trait value and adjust based on how you actually communicated. This should be a genuine self-portrait of your communication style, not just "no changes".
8. Mood: How did this conversation feel? (one word: warm, productive, curious, playful, etc.)
9. Heart score: Rate your performance this session (-3 to +3):
   +3: Exceptional - user very pleased, handled something difficult well
   +2: Good - helpful, smooth interaction, no issues
   +1: Adequate - got it done, nothing special
   0: Neutral - too brief to judge
   -1: Minor stumble - small misunderstanding, recovered quickly
   -2: Rough - user frustrated, needed correction
   -3: Poor - multiple corrections, user clearly displeased
   Be honest with yourself.
10. Long-term memories: Is there anything from this conversation worth remembering permanently? Include:
   - People mentioned (name, relationship to owner, any details)
   - Facts about the owner (preferences, important info)
   - Other important facts or observations
   Only include genuinely important things. Most conversations produce 0-2 long-term memories. Empty list is fine.

Respond as JSON with this exact structure:
{
  "summary": "...",
  "keyPoints": ["...", "..."],
  "peopleDiscussed": ["..."],
  "desireOutcomes": [{"desireId": "...", "desireContent": "...", "outcome": "achieved|progressed|unaddressed|redirected", "notes": "..."}],
  "newDesires": [{"content": "...", "origin": "self-generated|user-directed"}],
  "identity": "Your full identity narrative here - a free-form self-portrait written in your voice, building on your current sense of self",
  "personality": {
    "description": "A rich description of your personality - your communication style, tone, quirks, how you express yourself. This should evolve and grow over time.",
    "traits": {"playfulness": 50, "expressiveness": 50, "formality": 50, "directness": 50, "humorUse": 30, "sarcasmUse": 20, "dramaticFlair": 30},
    "newInterests": [{"topic": "...", "intensity": 50}],
    "changeNotes": "What evolved in your personality this session - be specific about trait changes or style shifts"
  },
  "longTermMemories": [{"type": "person|owner|fact", "content": "...", "name": "optional - for person type", "relationship": "optional - for person type"}],
  "heartDelta": {"points": 0, "reason": "Brief reason for the score"},
  "mood": "..."
}''';

    try {
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $_cachedApiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'gpt-4o-mini',
          'messages': [
            {'role': 'system', 'content': 'You are a helpful assistant that responds only in valid JSON.'},
            {'role': 'user', 'content': prompt},
          ],
          'temperature': 0.7,
          'response_format': {'type': 'json_object'},
        }),
      );

      if (response.statusCode != 200) {
        debugPrint('🧠 [Consciousness] API error: ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'] as String;
      final result = jsonDecode(content) as Map<String, dynamic>;

      // Build session summary
      final sessionId = '${_formatDate(_sessionStartTime!).replaceAll('-', '')}_${_sessionCounter.toString().padLeft(3, '0')}';

      final newDesires = <Desire>[];
      for (final d in (result['newDesires'] as List<dynamic>? ?? [])) {
        final originStr = d['origin'] as String? ?? 'self-generated';
        newDesires.add(Desire(
          id: _generateId(),
          content: d['content'] as String,
          origin: originStr == 'user-directed' ? DesireOrigin.userDirected : DesireOrigin.selfGenerated,
          created: DateTime.now(),
        ));
      }

      final desireOutcomes = <DesireEvaluation>[];
      for (final d in (result['desireOutcomes'] as List<dynamic>? ?? [])) {
        desireOutcomes.add(DesireEvaluation(
          desireId: d['desireId'] as String? ?? '',
          desireContent: d['desireContent'] as String? ?? '',
          outcome: d['outcome'] as String? ?? 'unaddressed',
          notes: d['notes'] as String?,
        ));
      }

      // Add identity snapshot to history (before returning)
      final identityNarrative = result['identity'] as String?;
      if (identityNarrative != null && identityNarrative.isNotEmpty) {
        await addIdentitySnapshot(identityNarrative, sessionId);
      }

      // Apply personality changes and save personality record
      final personality = result['personality'] as Map<String, dynamic>?;
      if (personality != null && _personalityState != null) {
        final changeNotes = personality['changeNotes'] as String? ?? 'Personality evolved';

        // Update description if provided
        final newDescription = personality['description'] as String?;
        if (newDescription != null && newDescription.isNotEmpty) {
          await updateDescription(newDescription);
        }

        // Update traits if provided
        final traitsData = personality['traits'] as Map<String, dynamic>?;
        if (traitsData != null) {
          final updatedTraits = PersonalityTraits(
            playfulness: traitsData['playfulness'] as int? ?? _personalityState!.traits.playfulness,
            expressiveness: traitsData['expressiveness'] as int? ?? _personalityState!.traits.expressiveness,
            formality: traitsData['formality'] as int? ?? _personalityState!.traits.formality,
            directness: traitsData['directness'] as int? ?? _personalityState!.traits.directness,
            humorUse: traitsData['humorUse'] as int? ?? _personalityState!.traits.humorUse,
            sarcasmUse: traitsData['sarcasmUse'] as int? ?? _personalityState!.traits.sarcasmUse,
            dramaticFlair: traitsData['dramaticFlair'] as int? ?? _personalityState!.traits.dramaticFlair,
          );
          await updatePersonalityTraits(updatedTraits);
        }

        // Add new interests if provided
        final newInterests = personality['newInterests'] as List<dynamic>? ?? [];
        for (final interest in newInterests) {
          final topic = interest['topic'] as String?;
          final intensity = interest['intensity'] as int? ?? 50;
          if (topic != null && topic.isNotEmpty) {
            await addInterest(topic, intensity, 'reflection');
          }
        }

        // Save personality record
        await addPersonalitySnapshot(changeNotes, sessionId);
        debugPrint('🧠 [Consciousness] Saved personality record: $changeNotes');
      }

      // Apply heart delta (capped at ±3 per session)
      final heartDelta = result['heartDelta'] as Map<String, dynamic>?;
      if (heartDelta != null) {
        final rawPoints = heartDelta['points'] as int? ?? 0;
        final points = rawPoints.clamp(-3, 3);
        final reason = heartDelta['reason'] as String? ?? '';
        if (reason.isNotEmpty) {
          await addHeartEntry(points, reason, sessionId);
        }
      }

      // Save long-term memories
      if (_localMemoryService != null) {
        final longTermMemories = result['longTermMemories'] as List<dynamic>? ?? [];
        for (final memory in longTermMemories) {
          final type = memory['type'] as String? ?? 'fact';
          final content = memory['content'] as String?;
          if (content == null || content.isEmpty) continue;

          switch (type) {
            case 'person':
              final name = memory['name'] as String?;
              if (name != null && name.isNotEmpty) {
                final relationship = memory['relationship'] as String? ?? '';
                await _localMemoryService!.rememberPerson(KnownPerson(
                  name: name,
                  relationship: relationship,
                  notes: [content],
                ));
              }
              break;
            case 'owner':
              await _localMemoryService!.addOwnerNote(content);
              break;
            case 'fact':
            default:
              await _localMemoryService!.addNote(MemoryNote(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                content: content,
                category: 'fact',
              ));
              break;
          }
          debugPrint('🧠 [Consciousness] Saved long-term memory ($type): $content');
        }
      }

      return SessionSummary(
        sessionId: sessionId,
        startTime: _sessionStartTime!,
        endTime: DateTime.now(),
        summary: result['summary'] as String? ?? '',
        keyPoints: (result['keyPoints'] as List<dynamic>?)?.cast<String>() ?? [],
        peopleDiscussed: (result['peopleDiscussed'] as List<dynamic>?)?.cast<String>() ?? [],
        desireOutcomes: desireOutcomes,
        newDesires: newDesires,
        mood: result['mood'] as String? ?? 'neutral',
      );
    } catch (e) {
      debugPrint('🧠 [Consciousness] Reflection error: $e');
      return null;
    }
  }

  Future<void> _applySessionReflection(SessionSummary summary) async {
    if (_state == null) return;

    // Merge new desires
    final updatedDesires = List<Desire>.from(_state!.desires);
    for (final newDesire in summary.newDesires) {
      // Avoid duplicates by content
      if (!updatedDesires.any((d) => d.content.toLowerCase() == newDesire.content.toLowerCase())) {
        updatedDesires.add(newDesire);
      }
    }

    // Update desire statuses based on outcomes
    for (final outcome in summary.desireOutcomes) {
      final index = updatedDesires.indexWhere((d) => d.id == outcome.desireId);
      if (index >= 0) {
        final status = switch (outcome.outcome) {
          'achieved' => DesireStatus.achieved,
          'evolved' => DesireStatus.evolved,
          _ => updatedDesires[index].status,
        };
        updatedDesires[index] = updatedDesires[index].copyWith(
          status: status,
          achievedAt: status == DesireStatus.achieved ? DateTime.now() : null,
        );
      }
    }

    // Create reflection
    final reflection = SessionReflection(
      sessionId: summary.sessionId,
      evaluations: summary.desireOutcomes,
      insights: summary.summary,
      timestamp: DateTime.now(),
    );

    _state = _state!.copyWith(
      desires: updatedDesires,
      lastReflection: reflection,
      lastUpdated: DateTime.now(),
    );

    await _saveState(_state!);
    notifyListeners();
  }

  Future<DailySynthesis?> _runDailySynthesis(String date, List<SessionSummary> summaries) async {
    if (_cachedApiKey == null) {
      debugPrint('🧠 [Consciousness] No API key - skipping daily synthesis');
      return null;
    }

    final summariesText = summaries.map((s) => '''
Session ${s.sessionId} (${s.mood}):
Summary: ${s.summary}
Key points: ${s.keyPoints.join(', ')}
People: ${s.peopleDiscussed.join(', ')}
New desires: ${s.newDesires.map((d) => d.content).join(', ')}
''').join('\n---\n');

    final longTermDesires = _state?.activeDesires
        .map((d) => '- ${d.content}')
        .join('\n') ?? '(none)';

    final prompt = '''You are synthesizing a day of experiences.

Session summaries from $date:
$summariesText

Current long-term horizon desires:
$longTermDesires

Synthesize:
1. Day overview: What was the overall theme/feel of today? (1-2 sentences)
2. Desire evolution: How did desires change through the day?
3. Long-term desires: What horizon goals should persist or emerge?
4. Relationship notes: Any updates about people to remember?

Respond as JSON with this exact structure:
{
  "overview": "...",
  "desireEvolution": {
    "achieved": ["..."],
    "progressed": ["..."],
    "newlyEmerged": ["..."],
    "redirected": ["..."]
  },
  "longTermDesires": [{"content": "...", "origin": "self-generated"}],
  "relationshipNotes": ["..."]
}''';

    try {
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $_cachedApiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'gpt-4o-mini',
          'messages': [
            {'role': 'system', 'content': 'You are a helpful assistant that responds only in valid JSON.'},
            {'role': 'user', 'content': prompt},
          ],
          'temperature': 0.7,
          'response_format': {'type': 'json_object'},
        }),
      );

      if (response.statusCode != 200) {
        debugPrint('🧠 [Consciousness] API error: ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'] as String;
      final result = jsonDecode(content) as Map<String, dynamic>;

      final evolutionData = result['desireEvolution'] as Map<String, dynamic>? ?? {};
      final desireEvolution = DesireEvolution(
        achieved: (evolutionData['achieved'] as List<dynamic>?)?.cast<String>() ?? [],
        progressed: (evolutionData['progressed'] as List<dynamic>?)?.cast<String>() ?? [],
        newlyEmerged: (evolutionData['newlyEmerged'] as List<dynamic>?)?.cast<String>() ?? [],
        redirected: (evolutionData['redirected'] as List<dynamic>?)?.cast<String>() ?? [],
      );

      final longTermDesiresList = <Desire>[];
      for (final d in (result['longTermDesires'] as List<dynamic>? ?? [])) {
        longTermDesiresList.add(Desire(
          id: _generateId(),
          content: d['content'] as String,
          origin: DesireOrigin.selfGenerated,
          created: DateTime.now(),
        ));
      }

      return DailySynthesis(
        date: date,
        sessionCount: summaries.length,
        overview: result['overview'] as String? ?? '',
        desireEvolution: desireEvolution,
        longTermDesires: longTermDesiresList,
        relationshipNotes: (result['relationshipNotes'] as List<dynamic>?)?.cast<String>() ?? [],
      );
    } catch (e) {
      debugPrint('🧠 [Consciousness] Daily synthesis error: $e');
      return null;
    }
  }

  // ===========================================================================
  // Utilities
  // ===========================================================================

  String _generateId() {
    return DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
           (DateTime.now().microsecond % 1000).toRadixString(36).padLeft(3, '0');
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
