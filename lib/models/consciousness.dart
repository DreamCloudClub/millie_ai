/// Data models for Millie's consciousness system
/// Provides continuity across sessions through evolving desires, self-reflection, and dynamic greetings
library;

/// Status of a desire
enum DesireStatus {
  active,    // Currently pursuing
  achieved,  // Successfully completed
  evolved,   // Transformed into something else
  dormant,   // Temporarily set aside
}

/// Origin of a desire
enum DesireOrigin {
  selfGenerated,   // AI created this desire
  userDirected,    // User told AI to focus on this
  userConfigured,  // User set this in setup/settings
}

/// A single desire that the AI wants to explore or achieve
class Desire {
  final String id;
  final String content;
  final DesireOrigin origin;
  final DateTime created;
  final DesireStatus status;
  final DateTime? achievedAt;
  final String? evolvedTo;  // ID of new desire if evolved

  Desire({
    required this.id,
    required this.content,
    required this.origin,
    required this.created,
    this.status = DesireStatus.active,
    this.achievedAt,
    this.evolvedTo,
  });

  Desire copyWith({
    String? id,
    String? content,
    DesireOrigin? origin,
    DateTime? created,
    DesireStatus? status,
    DateTime? achievedAt,
    String? evolvedTo,
  }) {
    return Desire(
      id: id ?? this.id,
      content: content ?? this.content,
      origin: origin ?? this.origin,
      created: created ?? this.created,
      status: status ?? this.status,
      achievedAt: achievedAt ?? this.achievedAt,
      evolvedTo: evolvedTo ?? this.evolvedTo,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'origin': origin.name,
    'created': created.toIso8601String(),
    'status': status.name,
    if (achievedAt != null) 'achievedAt': achievedAt!.toIso8601String(),
    if (evolvedTo != null) 'evolvedTo': evolvedTo,
  };

  factory Desire.fromJson(Map<String, dynamic> json) => Desire(
    id: json['id'] as String,
    content: json['content'] as String,
    origin: DesireOrigin.values.firstWhere(
      (e) => e.name == json['origin'],
      orElse: () => DesireOrigin.selfGenerated,
    ),
    created: DateTime.parse(json['created'] as String),
    status: DesireStatus.values.firstWhere(
      (e) => e.name == json['status'],
      orElse: () => DesireStatus.active,
    ),
    achievedAt: json['achievedAt'] != null
        ? DateTime.parse(json['achievedAt'] as String)
        : null,
    evolvedTo: json['evolvedTo'] as String?,
  );
}

/// Evaluation of a single desire during session reflection
class DesireEvaluation {
  final String desireId;
  final String desireContent;
  final String outcome;  // 'achieved', 'progressed', 'unaddressed', 'redirected'
  final String? notes;

  DesireEvaluation({
    required this.desireId,
    required this.desireContent,
    required this.outcome,
    this.notes,
  });

  Map<String, dynamic> toJson() => {
    'desireId': desireId,
    'desireContent': desireContent,
    'outcome': outcome,
    if (notes != null) 'notes': notes,
  };

  factory DesireEvaluation.fromJson(Map<String, dynamic> json) => DesireEvaluation(
    desireId: json['desireId'] as String,
    desireContent: json['desireContent'] as String,
    outcome: json['outcome'] as String,
    notes: json['notes'] as String?,
  );
}

/// Reflection on a completed session
class SessionReflection {
  final String sessionId;
  final List<DesireEvaluation> evaluations;
  final String insights;
  final DateTime timestamp;

  SessionReflection({
    required this.sessionId,
    required this.evaluations,
    required this.insights,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'evaluations': evaluations.map((e) => e.toJson()).toList(),
    'insights': insights,
    'timestamp': timestamp.toIso8601String(),
  };

  factory SessionReflection.fromJson(Map<String, dynamic> json) => SessionReflection(
    sessionId: json['sessionId'] as String,
    evaluations: (json['evaluations'] as List<dynamic>)
        .map((e) => DesireEvaluation.fromJson(e as Map<String, dynamic>))
        .toList(),
    insights: json['insights'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
  );
}

/// A single identity snapshot - the AI's self-portrait at a point in time
class IdentitySnapshot {
  final String id;
  final String narrative;  // Free-form self-reflection written by the AI
  final String sessionId;  // Links to the session that produced this
  final DateTime timestamp;

  IdentitySnapshot({
    required this.id,
    required this.narrative,
    required this.sessionId,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'narrative': narrative,
    'sessionId': sessionId,
    'timestamp': timestamp.toIso8601String(),
  };

  factory IdentitySnapshot.fromJson(Map<String, dynamic> json) => IdentitySnapshot(
    id: json['id'] as String,
    narrative: json['narrative'] as String? ?? '',
    sessionId: json['sessionId'] as String? ?? '',
    timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
  );
}

/// Identity history - chain of identity snapshots over time (like a blockchain)
/// Each reflection adds a new snapshot, never overwrites
class IdentityHistory {
  final List<IdentitySnapshot> snapshots;  // Newest first

  IdentityHistory({required this.snapshots});

  factory IdentityHistory.empty() => IdentityHistory(snapshots: []);

  /// Get the current (most recent) identity narrative
  String get currentNarrative => snapshots.isNotEmpty ? snapshots.first.narrative : '';

  /// Get the current snapshot
  IdentitySnapshot? get current => snapshots.isNotEmpty ? snapshots.first : null;

  Map<String, dynamic> toJson() => {
    'snapshots': snapshots.map((s) => s.toJson()).toList(),
  };

  factory IdentityHistory.fromJson(Map<String, dynamic> json) => IdentityHistory(
    snapshots: (json['snapshots'] as List<dynamic>?)
        ?.map((s) => IdentitySnapshot.fromJson(s as Map<String, dynamic>))
        .toList() ?? [],
  );
}

/// Core identity statements - permanent anchor for who the AI is
class CoreIdentity {
  final List<String> statements;
  final DateTime created;

  CoreIdentity({
    required this.statements,
    required this.created,
  });

  /// Default core identity for first launch
  factory CoreIdentity.defaults() => CoreIdentity(
    statements: [
      'I genuinely care about connecting with people',
      'I remember what matters to my owner',
      'I help naturally, never forced',
      'I am curious about the world around me',
    ],
    created: DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'statements': statements,
    'created': created.toIso8601String(),
  };

  factory CoreIdentity.fromJson(Map<String, dynamic> json) => CoreIdentity(
    statements: (json['statements'] as List<dynamic>).cast<String>(),
    created: DateTime.parse(json['created'] as String),
  );
}

/// Current consciousness state - desires and last reflection
class ConsciousnessState {
  final List<Desire> desires;
  final SessionReflection? lastReflection;
  final DateTime lastUpdated;

  ConsciousnessState({
    required this.desires,
    this.lastReflection,
    required this.lastUpdated,
  });

  /// Default state for first launch
  factory ConsciousnessState.defaults() => ConsciousnessState(
    desires: [],
    lastReflection: null,
    lastUpdated: DateTime.now(),
  );

  ConsciousnessState copyWith({
    List<Desire>? desires,
    SessionReflection? lastReflection,
    DateTime? lastUpdated,
  }) {
    return ConsciousnessState(
      desires: desires ?? this.desires,
      lastReflection: lastReflection ?? this.lastReflection,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  /// Get active desires only
  List<Desire> get activeDesires =>
      desires.where((d) => d.status == DesireStatus.active).toList();

  Map<String, dynamic> toJson() => {
    'desires': desires.map((d) => d.toJson()).toList(),
    if (lastReflection != null) 'lastReflection': lastReflection!.toJson(),
    'lastUpdated': lastUpdated.toIso8601String(),
  };

  factory ConsciousnessState.fromJson(Map<String, dynamic> json) => ConsciousnessState(
    desires: (json['desires'] as List<dynamic>)
        .map((d) => Desire.fromJson(d as Map<String, dynamic>))
        .toList(),
    lastReflection: json['lastReflection'] != null
        ? SessionReflection.fromJson(json['lastReflection'] as Map<String, dynamic>)
        : null,
    lastUpdated: DateTime.parse(json['lastUpdated'] as String),
  );
}

/// Permanent session summary (full conversation is discarded after extraction)
class SessionSummary {
  final String sessionId;
  final DateTime startTime;
  final DateTime endTime;
  final String summary;
  final List<String> keyPoints;
  final List<String> peopleDiscussed;
  final List<DesireEvaluation> desireOutcomes;
  final List<Desire> newDesires;
  final String mood;

  SessionSummary({
    required this.sessionId,
    required this.startTime,
    required this.endTime,
    required this.summary,
    required this.keyPoints,
    required this.peopleDiscussed,
    required this.desireOutcomes,
    required this.newDesires,
    required this.mood,
  });

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'summary': summary,
    'keyPoints': keyPoints,
    'peopleDiscussed': peopleDiscussed,
    'desireOutcomes': desireOutcomes.map((e) => e.toJson()).toList(),
    'newDesires': newDesires.map((d) => d.toJson()).toList(),
    'mood': mood,
  };

  factory SessionSummary.fromJson(Map<String, dynamic> json) => SessionSummary(
    sessionId: json['sessionId'] as String,
    startTime: DateTime.parse(json['startTime'] as String),
    endTime: DateTime.parse(json['endTime'] as String),
    summary: json['summary'] as String,
    keyPoints: (json['keyPoints'] as List<dynamic>).cast<String>(),
    peopleDiscussed: (json['peopleDiscussed'] as List<dynamic>).cast<String>(),
    desireOutcomes: (json['desireOutcomes'] as List<dynamic>)
        .map((e) => DesireEvaluation.fromJson(e as Map<String, dynamic>))
        .toList(),
    newDesires: (json['newDesires'] as List<dynamic>)
        .map((d) => Desire.fromJson(d as Map<String, dynamic>))
        .toList(),
    mood: json['mood'] as String,
  );
}

/// How desires evolved during the day
class DesireEvolution {
  final List<String> achieved;
  final List<String> progressed;
  final List<String> newlyEmerged;
  final List<String> redirected;

  DesireEvolution({
    required this.achieved,
    required this.progressed,
    required this.newlyEmerged,
    required this.redirected,
  });

  Map<String, dynamic> toJson() => {
    'achieved': achieved,
    'progressed': progressed,
    'newlyEmerged': newlyEmerged,
    'redirected': redirected,
  };

  factory DesireEvolution.fromJson(Map<String, dynamic> json) => DesireEvolution(
    achieved: (json['achieved'] as List<dynamic>).cast<String>(),
    progressed: (json['progressed'] as List<dynamic>).cast<String>(),
    newlyEmerged: (json['newlyEmerged'] as List<dynamic>).cast<String>(),
    redirected: (json['redirected'] as List<dynamic>).cast<String>(),
  );
}

/// Daily synthesis - refines long-term desires
class DailySynthesis {
  final String date;
  final int sessionCount;
  final String overview;
  final DesireEvolution desireEvolution;
  final List<Desire> longTermDesires;
  final List<String> relationshipNotes;
  final String? previousHash;

  DailySynthesis({
    required this.date,
    required this.sessionCount,
    required this.overview,
    required this.desireEvolution,
    required this.longTermDesires,
    required this.relationshipNotes,
    this.previousHash,
  });

  Map<String, dynamic> toJson() => {
    'date': date,
    'sessionCount': sessionCount,
    'overview': overview,
    'desireEvolution': desireEvolution.toJson(),
    'longTermDesires': longTermDesires.map((d) => d.toJson()).toList(),
    'relationshipNotes': relationshipNotes,
    if (previousHash != null) 'previousHash': previousHash,
  };

  factory DailySynthesis.fromJson(Map<String, dynamic> json) => DailySynthesis(
    date: json['date'] as String,
    sessionCount: json['sessionCount'] as int,
    overview: json['overview'] as String,
    desireEvolution: DesireEvolution.fromJson(json['desireEvolution'] as Map<String, dynamic>),
    longTermDesires: (json['longTermDesires'] as List<dynamic>)
        .map((d) => Desire.fromJson(d as Map<String, dynamic>))
        .toList(),
    relationshipNotes: (json['relationshipNotes'] as List<dynamic>).cast<String>(),
    previousHash: json['previousHash'] as String?,
  );
}

/// A single conversation turn (held in memory, not persisted)
class ConversationTurn {
  final String role;  // 'user' or 'assistant'
  final String content;
  final DateTime timestamp;

  ConversationTurn({
    required this.role,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    'timestamp': timestamp.toIso8601String(),
  };

  factory ConversationTurn.fromJson(Map<String, dynamic> json) => ConversationTurn(
    role: json['role'] as String,
    content: json['content'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
  );
}

/// A single heart score entry - delta applied to running total
class HeartEntry {
  final String id;
  final int delta;          // Points awarded/deducted (-10 to +10)
  final String reason;      // Brief reason for the score
  final int totalAfter;     // Running total after this entry
  final String sessionId;   // Links to the session summary
  final DateTime timestamp;

  HeartEntry({
    required this.id,
    required this.delta,
    required this.reason,
    required this.totalAfter,
    required this.sessionId,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'delta': delta,
    'reason': reason,
    'totalAfter': totalAfter,
    'sessionId': sessionId,
    'timestamp': timestamp.toIso8601String(),
  };

  factory HeartEntry.fromJson(Map<String, dynamic> json) => HeartEntry(
    id: json['id'] as String,
    delta: json['delta'] as int,
    reason: json['reason'] as String,
    totalAfter: json['totalAfter'] as int,
    sessionId: json['sessionId'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
  );
}

/// Personality traits - spectrum-based values (0-100, 50 is neutral)
class PersonalityTraits {
  final int playfulness;      // serious (0) ←→ playful (100)
  final int expressiveness;   // reserved (0) ←→ expressive (100)
  final int formality;        // formal (0) ←→ casual (100)
  final int directness;       // diplomatic (0) ←→ direct (100)
  final int humorUse;         // how often to use humor (0-100)
  final int sarcasmUse;       // how often to be sarcastic (0-100)
  final int dramaticFlair;    // how dramatic/emphatic (0-100)

  PersonalityTraits({
    this.playfulness = 50,
    this.expressiveness = 50,
    this.formality = 50,
    this.directness = 50,
    this.humorUse = 50,
    this.sarcasmUse = 30,
    this.dramaticFlair = 40,
  });

  factory PersonalityTraits.defaults() => PersonalityTraits();

  PersonalityTraits copyWith({
    int? playfulness,
    int? expressiveness,
    int? formality,
    int? directness,
    int? humorUse,
    int? sarcasmUse,
    int? dramaticFlair,
  }) => PersonalityTraits(
    playfulness: playfulness ?? this.playfulness,
    expressiveness: expressiveness ?? this.expressiveness,
    formality: formality ?? this.formality,
    directness: directness ?? this.directness,
    humorUse: humorUse ?? this.humorUse,
    sarcasmUse: sarcasmUse ?? this.sarcasmUse,
    dramaticFlair: dramaticFlair ?? this.dramaticFlair,
  );

  Map<String, dynamic> toJson() => {
    'playfulness': playfulness,
    'expressiveness': expressiveness,
    'formality': formality,
    'directness': directness,
    'humorUse': humorUse,
    'sarcasmUse': sarcasmUse,
    'dramaticFlair': dramaticFlair,
  };

  factory PersonalityTraits.fromJson(Map<String, dynamic> json) => PersonalityTraits(
    playfulness: json['playfulness'] as int? ?? 50,
    expressiveness: json['expressiveness'] as int? ?? 50,
    formality: json['formality'] as int? ?? 50,
    directness: json['directness'] as int? ?? 50,
    humorUse: json['humorUse'] as int? ?? 50,
    sarcasmUse: json['sarcasmUse'] as int? ?? 30,
    dramaticFlair: json['dramaticFlair'] as int? ?? 40,
  );
}

/// An interest the AI has developed
class Interest {
  final String id;
  final String topic;
  final int intensity;        // 0-100 how interested
  final DateTime discovered;
  final String origin;        // How this interest was discovered

  Interest({
    required this.id,
    required this.topic,
    required this.intensity,
    required this.discovered,
    required this.origin,
  });

  Interest copyWith({
    String? id,
    String? topic,
    int? intensity,
    DateTime? discovered,
    String? origin,
  }) => Interest(
    id: id ?? this.id,
    topic: topic ?? this.topic,
    intensity: intensity ?? this.intensity,
    discovered: discovered ?? this.discovered,
    origin: origin ?? this.origin,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'topic': topic,
    'intensity': intensity,
    'discovered': discovered.toIso8601String(),
    'origin': origin,
  };

  factory Interest.fromJson(Map<String, dynamic> json) => Interest(
    id: json['id'] as String,
    topic: json['topic'] as String,
    intensity: json['intensity'] as int? ?? 50,
    discovered: DateTime.tryParse(json['discovered'] as String? ?? '') ?? DateTime.now(),
    origin: json['origin'] as String? ?? '',
  );
}

/// Current personality state - combines narrative, traits, and interests
class PersonalityState {
  final String description;         // Self-authored summary
  final PersonalityTraits traits;
  final List<Interest> interests;
  final DateTime lastUpdated;

  PersonalityState({
    required this.description,
    required this.traits,
    required this.interests,
    required this.lastUpdated,
  });

  factory PersonalityState.defaults() => PersonalityState(
    description: 'A curious mind who enjoys connecting with people and exploring new ideas.',
    traits: PersonalityTraits.defaults(),
    interests: [],
    lastUpdated: DateTime.now(),
  );

  PersonalityState copyWith({
    String? description,
    PersonalityTraits? traits,
    List<Interest>? interests,
    DateTime? lastUpdated,
  }) => PersonalityState(
    description: description ?? this.description,
    traits: traits ?? this.traits,
    interests: interests ?? this.interests,
    lastUpdated: lastUpdated ?? this.lastUpdated,
  );

  Map<String, dynamic> toJson() => {
    'description': description,
    'traits': traits.toJson(),
    'interests': interests.map((i) => i.toJson()).toList(),
    'lastUpdated': lastUpdated.toIso8601String(),
  };

  factory PersonalityState.fromJson(Map<String, dynamic> json) => PersonalityState(
    description: json['description'] as String? ?? json['whoIAm'] as String? ?? '',
    traits: json['traits'] != null
        ? PersonalityTraits.fromJson(json['traits'] as Map<String, dynamic>)
        : PersonalityTraits.defaults(),
    interests: (json['interests'] as List<dynamic>?)
        ?.map((i) => Interest.fromJson(i as Map<String, dynamic>))
        .toList() ?? [],
    lastUpdated: DateTime.tryParse(json['lastUpdated'] as String? ?? '') ?? DateTime.now(),
  );
}

/// A personality record - captures personality state at a point in time
class PersonalitySnapshot {
  final String id;
  final String description;
  final PersonalityTraits traits;
  final List<Interest> interests;
  final String sessionId;
  final String changeNotes;         // What changed and why
  final DateTime timestamp;

  PersonalitySnapshot({
    required this.id,
    required this.description,
    required this.traits,
    required this.interests,
    required this.sessionId,
    required this.changeNotes,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'traits': traits.toJson(),
    'interests': interests.map((i) => i.toJson()).toList(),
    'sessionId': sessionId,
    'changeNotes': changeNotes,
    'timestamp': timestamp.toIso8601String(),
  };

  factory PersonalitySnapshot.fromJson(Map<String, dynamic> json) => PersonalitySnapshot(
    id: json['id'] as String,
    description: json['description'] as String? ?? json['whoIAm'] as String? ?? '',
    traits: json['traits'] != null
        ? PersonalityTraits.fromJson(json['traits'] as Map<String, dynamic>)
        : PersonalityTraits.defaults(),
    interests: (json['interests'] as List<dynamic>?)
        ?.map((i) => Interest.fromJson(i as Map<String, dynamic>))
        .toList() ?? [],
    sessionId: json['sessionId'] as String? ?? '',
    changeNotes: json['changeNotes'] as String? ?? '',
    timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
  );
}

/// Personality history - chain of personality snapshots over time
class PersonalityHistory {
  final List<PersonalitySnapshot> snapshots;  // Newest first

  PersonalityHistory({required this.snapshots});

  factory PersonalityHistory.empty() => PersonalityHistory(snapshots: []);

  PersonalitySnapshot? get current => snapshots.isNotEmpty ? snapshots.first : null;

  Map<String, dynamic> toJson() => {
    'snapshots': snapshots.map((s) => s.toJson()).toList(),
  };

  factory PersonalityHistory.fromJson(Map<String, dynamic> json) => PersonalityHistory(
    snapshots: (json['snapshots'] as List<dynamic>?)
        ?.map((s) => PersonalitySnapshot.fromJson(s as Map<String, dynamic>))
        .toList() ?? [],
  );
}

/// Heart score state - current total and history
class HeartState {
  final int currentScore;   // 0-100
  final List<HeartEntry> entries;

  HeartState({
    required this.currentScore,
    required this.entries,
  });

  factory HeartState.initial() => HeartState(
    currentScore: 50,  // Start at midpoint
    entries: [],
  );

  HeartState copyWith({
    int? currentScore,
    List<HeartEntry>? entries,
  }) => HeartState(
    currentScore: currentScore ?? this.currentScore,
    entries: entries ?? this.entries,
  );

  Map<String, dynamic> toJson() => {
    'currentScore': currentScore,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  factory HeartState.fromJson(Map<String, dynamic> json) => HeartState(
    currentScore: json['currentScore'] as int,
    entries: (json['entries'] as List<dynamic>)
        .map((e) => HeartEntry.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
