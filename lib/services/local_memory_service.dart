import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Local memory storage service
/// Replaces RosBridge-based memory storage with local file storage
class LocalMemoryService extends ChangeNotifier {
  MemoryData _memories = MemoryData();
  bool _initialized = false;

  MemoryData get memories => _memories;
  bool get isInitialized => _initialized;

  /// Initialize - load from disk
  Future<void> initialize() async {
    _memories = await _loadMemories();
    _initialized = true;
    notifyListeners();
    debugPrint('🧠 [LocalMemory] Initialized: ${_memories.owner.notes.length} owner notes, ${_memories.people.length} people, ${_memories.notes.length} notes');
  }

  // ===========================================================================
  // Owner Notes
  // ===========================================================================

  Future<void> addOwnerNote(String note) async {
    final updatedNotes = [..._memories.owner.notes, note];
    final updatedOwner = _memories.owner.copyWith(notes: updatedNotes);
    _memories = _memories.copyWith(owner: updatedOwner);
    await _saveMemories();
    notifyListeners();
    debugPrint('📝 [LocalMemory] Added owner note: $note');
  }

  Future<void> removeOwnerNote(int index) async {
    if (index < 0 || index >= _memories.owner.notes.length) return;
    final updatedNotes = List<String>.from(_memories.owner.notes)..removeAt(index);
    final updatedOwner = _memories.owner.copyWith(notes: updatedNotes);
    _memories = _memories.copyWith(owner: updatedOwner);
    await _saveMemories();
    notifyListeners();
  }

  Future<void> updateOwnerNote(int index, String newNote) async {
    if (index < 0 || index >= _memories.owner.notes.length) return;
    final updatedNotes = List<String>.from(_memories.owner.notes);
    updatedNotes[index] = newNote;
    final updatedOwner = _memories.owner.copyWith(notes: updatedNotes);
    _memories = _memories.copyWith(owner: updatedOwner);
    await _saveMemories();
    notifyListeners();
    debugPrint('📝 [LocalMemory] Updated owner note at $index: $newNote');
  }

  // ===========================================================================
  // People
  // ===========================================================================

  Future<void> rememberPerson(KnownPerson person) async {
    // Check if person already exists
    final existingIndex = _memories.people.indexWhere(
      (p) => p.name.toLowerCase() == person.name.toLowerCase(),
    );

    List<KnownPerson> updatedPeople;
    if (existingIndex >= 0) {
      // Update existing person
      final existing = _memories.people[existingIndex];
      final merged = KnownPerson(
        name: person.name,
        relationship: person.relationship.isNotEmpty ? person.relationship : existing.relationship,
        interests: person.interests ?? existing.interests,
        notes: [...existing.notes, ...person.notes],
        lastSeen: DateTime.now(),
      );
      updatedPeople = List.from(_memories.people);
      updatedPeople[existingIndex] = merged;
    } else {
      // Add new person
      updatedPeople = [..._memories.people, person.copyWith(lastSeen: DateTime.now())];
    }

    _memories = _memories.copyWith(people: updatedPeople);
    await _saveMemories();
    notifyListeners();
    debugPrint('📝 [LocalMemory] Remembered person: ${person.name}');
  }

  Future<void> removePerson(String name) async {
    final updatedPeople = _memories.people.where(
      (p) => p.name.toLowerCase() != name.toLowerCase(),
    ).toList();
    _memories = _memories.copyWith(people: updatedPeople);
    await _saveMemories();
    notifyListeners();
  }

  KnownPerson? findPerson(String name) {
    try {
      return _memories.people.firstWhere(
        (p) => p.name.toLowerCase() == name.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // Notes
  // ===========================================================================

  Future<void> addNote(MemoryNote note) async {
    final updatedNotes = [..._memories.notes, note];
    _memories = _memories.copyWith(notes: updatedNotes);
    await _saveMemories();
    notifyListeners();
    debugPrint('📝 [LocalMemory] Added note: ${note.content}');
  }

  Future<void> removeNote(String id) async {
    final updatedNotes = _memories.notes.where((n) => n.id != id).toList();
    _memories = _memories.copyWith(notes: updatedNotes);
    await _saveMemories();
    notifyListeners();
  }

  Future<void> updateNote(String id, String newContent, {String? newCategory}) async {
    final updatedNotes = _memories.notes.map((n) {
      if (n.id == id) {
        return MemoryNote(
          id: n.id,
          content: newContent,
          category: newCategory ?? n.category,
        );
      }
      return n;
    }).toList();
    _memories = _memories.copyWith(notes: updatedNotes);
    await _saveMemories();
    notifyListeners();
    debugPrint('📝 [LocalMemory] Updated note: $id');
  }

  List<MemoryNote> searchNotes(String query) {
    final queryLower = query.toLowerCase();
    return _memories.notes.where(
      (n) => n.content.toLowerCase().contains(queryLower) ||
             n.category.toLowerCase().contains(queryLower),
    ).toList();
  }

  // ===========================================================================
  // Reset Operations
  // ===========================================================================

  /// Clear all notes (long-term memory)
  Future<void> resetNotes() async {
    _memories = _memories.copyWith(notes: []);
    await _saveMemories();
    notifyListeners();
    debugPrint('📝 [LocalMemory] Notes cleared');
  }

  /// Clear all relationships (owner notes + people)
  Future<void> resetRelationships() async {
    _memories = _memories.copyWith(
      owner: OwnerProfile(),
      people: [],
    );
    await _saveMemories();
    notifyListeners();
    debugPrint('📝 [LocalMemory] Relationships cleared');
  }

  // ===========================================================================
  // File I/O
  // ===========================================================================

  Future<Directory> _getMemoryDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/memories');
    await dir.create(recursive: true);
    return dir;
  }

  Future<MemoryData> _loadMemories() async {
    try {
      final dir = await _getMemoryDir();
      final file = File('${dir.path}/memories.json');

      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        return MemoryData.fromJson(json);
      }
    } catch (e) {
      debugPrint('🧠 [LocalMemory] Error loading: $e');
    }
    return MemoryData();
  }

  Future<void> _saveMemories() async {
    try {
      final dir = await _getMemoryDir();
      final file = File('${dir.path}/memories.json');
      await file.writeAsString(jsonEncode(_memories.toJson()));
    } catch (e) {
      debugPrint('🧠 [LocalMemory] Error saving: $e');
    }
  }

  // ===========================================================================
  // Context for System Prompt
  // ===========================================================================

  String getMemoryContext() {
    if (_memories.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    buffer.writeln('\n\nMEMORY:');

    // Owner notes
    if (!_memories.owner.isEmpty) {
      buffer.writeln('Owner notes:');
      for (final note in _memories.owner.notes) {
        buffer.writeln('  - $note');
      }
    }

    // Known people
    if (_memories.people.isNotEmpty) {
      buffer.writeln('People you know: ${_memories.people.map((p) => "${p.name}${p.relationship.isNotEmpty ? " (${p.relationship})" : ""}").join(", ")}.');
    }

    // Recent notes (limit to 5)
    if (_memories.notes.isNotEmpty) {
      final recentNotes = _memories.notes.reversed.take(5).toList();
      buffer.writeln('Recent notes: ${recentNotes.map((n) => n.content).join("; ")}');
    }

    return buffer.toString();
  }
}

// ===========================================================================
// Data Models (moved from rosbridge.dart)
// ===========================================================================

class KnownPerson {
  final String name;
  final String relationship;
  final List<String> notes;
  final String? interests;
  final DateTime? lastSeen;

  KnownPerson({
    required this.name,
    this.relationship = '',
    this.notes = const [],
    this.interests,
    this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'relationship': relationship,
    'notes': notes,
    'interests': interests,
    'last_seen': lastSeen?.toIso8601String(),
  };

  factory KnownPerson.fromJson(Map<String, dynamic> json) => KnownPerson(
    name: json['name'] as String? ?? '',
    relationship: json['relationship'] as String? ?? '',
    notes: (json['notes'] as List<dynamic>?)?.map((n) => n as String).toList() ?? [],
    interests: json['interests'] as String?,
    lastSeen: json['last_seen'] != null ? DateTime.tryParse(json['last_seen'] as String) : null,
  );

  KnownPerson copyWith({
    String? name,
    String? relationship,
    List<String>? notes,
    String? interests,
    DateTime? lastSeen,
  }) => KnownPerson(
    name: name ?? this.name,
    relationship: relationship ?? this.relationship,
    notes: notes ?? this.notes,
    interests: interests ?? this.interests,
    lastSeen: lastSeen ?? this.lastSeen,
  );
}

class MemoryNote {
  final String id;
  final String content;
  final String category;
  final DateTime createdAt;

  MemoryNote({
    required this.id,
    required this.content,
    this.category = 'general',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'category': category,
    'created_at': createdAt.toIso8601String(),
  };

  factory MemoryNote.fromJson(Map<String, dynamic> json) => MemoryNote(
    id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
    content: json['content'] as String? ?? '',
    category: json['category'] as String? ?? 'general',
    createdAt: json['created_at'] != null
        ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
        : DateTime.now(),
  );
}

class OwnerProfile {
  final List<String> notes;

  OwnerProfile({
    this.notes = const [],
  });

  bool get isEmpty => notes.isEmpty;

  Map<String, dynamic> toJson() => {
    'notes': notes,
  };

  factory OwnerProfile.fromJson(Map<String, dynamic> json) => OwnerProfile(
    notes: (json['notes'] as List<dynamic>?)?.map((n) => n as String).toList() ?? [],
  );

  OwnerProfile copyWith({
    List<String>? notes,
  }) => OwnerProfile(
    notes: notes ?? this.notes,
  );
}

class MemoryData {
  final OwnerProfile owner;
  final List<KnownPerson> people;
  final List<MemoryNote> notes;

  MemoryData({
    OwnerProfile? owner,
    this.people = const [],
    this.notes = const [],
  }) : owner = owner ?? OwnerProfile();

  bool get isEmpty => owner.isEmpty && people.isEmpty && notes.isEmpty;

  Map<String, dynamic> toJson() => {
    'owner': owner.toJson(),
    'people': people.map((p) => p.toJson()).toList(),
    'notes': notes.map((n) => n.toJson()).toList(),
  };

  factory MemoryData.fromJson(Map<String, dynamic> json) => MemoryData(
    owner: json['owner'] != null
        ? OwnerProfile.fromJson(json['owner'] as Map<String, dynamic>)
        : OwnerProfile(),
    people: (json['people'] as List<dynamic>?)
        ?.map((p) => KnownPerson.fromJson(p as Map<String, dynamic>))
        .toList() ?? [],
    notes: (json['notes'] as List<dynamic>?)
        ?.map((n) => MemoryNote.fromJson(n as Map<String, dynamic>))
        .toList() ?? [],
  );

  MemoryData copyWith({
    OwnerProfile? owner,
    List<KnownPerson>? people,
    List<MemoryNote>? notes,
  }) => MemoryData(
    owner: owner ?? this.owner,
    people: people ?? this.people,
    notes: notes ?? this.notes,
  );
}
