import 'package:flutter/foundation.dart';
import '../utils/rosbridge.dart';
import 'workflow_tools.dart';

/// Memory Tools for AI function calling
/// Allows the agent to remember and recall information about:
/// - Owner notes
/// - People it meets (name, relationship, notes)
/// - General notes and observations
class MemoryTools {
  final RosBridge rosBridge;

  // Local cache from listener updates
  MemoryData _memories = MemoryData();

  // Listener reference for cleanup
  late final void Function(MemoryData) _memoryListener;

  MemoryTools(this.rosBridge) {
    _setupListeners();
  }

  void _setupListeners() {
    _memoryListener = (memories) {
      _memories = memories;
      debugPrint('🧠 [MemoryTools] Loaded: ${memories.owner.notes.length} owner notes, ${memories.people.length} people, ${memories.notes.length} notes');
    };

    rosBridge.addMemoryListener(_memoryListener);
    rosBridge.requestMemories();
  }

  void dispose() {
    rosBridge.removeMemoryListener(_memoryListener);
  }

  /// Clear any local state (called when conversation is cancelled/reset)
  void clear() {
    // No transient state to clear for memory tools
  }

  // ===========================================================================
  // TOOL DEFINITIONS
  // ===========================================================================

  static List<Map<String, dynamic>> get toolDefinitions => [
    // ADD OWNER NOTE
    {
      'type': 'function',
      'function': {
        'name': 'add_owner_note',
        'description': 'Save a note about your owner/primary user. Use when you learn something about them you want to remember.',
        'parameters': {
          'type': 'object',
          'properties': {
            'note': {
              'type': 'string',
              'description': 'The note to save about the owner (e.g., "Prefers casual conversation", "Loves hiking", "Name is John")',
            },
          },
          'required': ['note'],
        },
      },
    },
    // REMEMBER A PERSON
    {
      'type': 'function',
      'function': {
        'name': 'remember_person',
        'description': 'Save information about a person you meet. Use when you learn someone\'s name, relationship to owner, or interesting facts about them.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'The person\'s name',
            },
            'relationship': {
              'type': 'string',
              'description': 'Their relationship to the owner (e.g., "friend", "coworker", "family", "visitor")',
            },
            'interests': {
              'type': 'string',
              'description': 'Their interests or topics they like',
            },
            'notes': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Things to remember about this person',
            },
          },
          'required': ['name'],
        },
      },
    },
    // ADD A NOTE
    {
      'type': 'function',
      'function': {
        'name': 'add_memory_note',
        'description': 'Save a note or observation for later. Use for important facts, preferences learned, or things to remember.',
        'parameters': {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description': 'The note content to remember',
            },
            'category': {
              'type': 'string',
              'enum': ['observation', 'preference', 'fact', 'event', 'general'],
              'description': 'Category of this note',
            },
          },
          'required': ['content'],
        },
      },
    },
    // RECALL MEMORIES
    {
      'type': 'function',
      'function': {
        'name': 'recall_memories',
        'description': 'Recall what you know about a person or topic. Use to check what you remember before asking questions you might already know the answer to.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'What to recall - a person\'s name, "owner", or a topic',
            },
          },
          'required': [],
        },
      },
    },
    // GET OWNER INFO
    {
      'type': 'function',
      'function': {
        'name': 'get_owner_info',
        'description': 'Retrieve saved notes about your owner. Returns any notes you\'ve previously saved with add_owner_note.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
  ];

  // ===========================================================================
  // TOOL EXECUTION
  // ===========================================================================

  Future<ToolResult> executeTool(ToolCall toolCall) async {
    debugPrint('🧠 [MemoryTools] Executing: ${toolCall.name}');

    switch (toolCall.name) {
      case 'add_owner_note':
        return _addOwnerNote(toolCall.arguments);

      case 'remember_person':
        return _rememberPerson(toolCall.arguments);

      case 'add_memory_note':
        return _addMemoryNote(toolCall.arguments);

      case 'recall_memories':
        return _recallMemories(toolCall.arguments);

      case 'get_owner_info':
        return _getOwnerInfo();

      default:
        return ToolResult(
          success: false,
          message: 'Unknown memory tool: ${toolCall.name}',
        );
    }
  }

  // ===========================================================================
  // ADD OWNER NOTE
  // ===========================================================================

  ToolResult _addOwnerNote(Map<String, dynamic> args) {
    final note = args['note'] as String?;
    if (note == null || note.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Note content is required',
      );
    }

    // Add to owner notes
    final updatedNotes = [..._memories.owner.notes, note];
    final updatedOwner = _memories.owner.copyWith(notes: updatedNotes);
    final updatedMemories = _memories.copyWith(owner: updatedOwner);
    _memories = updatedMemories;
    rosBridge.publishSaveMemories(updatedMemories);

    debugPrint('📝 [MemoryTools] Saved owner note: $note');

    return ToolResult(
      success: true,
      message: 'Saved note about owner: $note',
    );
  }

  // ===========================================================================
  // REMEMBER A PERSON
  // ===========================================================================

  ToolResult _rememberPerson(Map<String, dynamic> args) {
    final name = args['name'] as String?;
    if (name == null || name.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Person name is required',
      );
    }

    final relationship = args['relationship'] as String? ?? '';
    final interests = args['interests'] as String?;
    final notesArg = args['notes'];

    List<String> notes = [];
    if (notesArg is List) {
      notes = notesArg.map((n) => n.toString()).toList();
    } else if (notesArg is String) {
      notes = [notesArg];
    }

    // Check if person already exists
    final existingIndex = _memories.people.indexWhere(
      (p) => p.name.toLowerCase() == name.toLowerCase(),
    );

    KnownPerson person;
    List<KnownPerson> updatedPeople;

    if (existingIndex >= 0) {
      // Update existing person
      final existing = _memories.people[existingIndex];
      person = existing.copyWith(
        relationship: relationship.isNotEmpty ? relationship : existing.relationship,
        interests: interests ?? existing.interests,
        notes: [...existing.notes, ...notes],
        lastSeen: DateTime.now(),
      );
      updatedPeople = List.from(_memories.people);
      updatedPeople[existingIndex] = person;
    } else {
      // Add new person
      person = KnownPerson(
        name: name,
        relationship: relationship,
        interests: interests,
        notes: notes,
        lastSeen: DateTime.now(),
      );
      updatedPeople = [..._memories.people, person];
    }

    final updatedMemories = _memories.copyWith(people: updatedPeople);
    _memories = updatedMemories;
    rosBridge.publishSaveMemories(updatedMemories);

    debugPrint('📝 [MemoryTools] Remembered person: $name (${relationship.isNotEmpty ? relationship : "no relationship specified"})');

    return ToolResult(
      success: true,
      message: 'Remembered $name${relationship.isNotEmpty ? " ($relationship)" : ""}',
    );
  }

  // ===========================================================================
  // ADD A NOTE
  // ===========================================================================

  ToolResult _addMemoryNote(Map<String, dynamic> args) {
    final content = args['content'] as String?;
    if (content == null || content.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Note content is required',
      );
    }

    final category = args['category'] as String? ?? 'general';

    final note = MemoryNote(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      category: category,
    );

    final updatedNotes = [..._memories.notes, note];
    final updatedMemories = _memories.copyWith(notes: updatedNotes);
    _memories = updatedMemories;
    rosBridge.publishSaveMemories(updatedMemories);

    debugPrint('📝 [MemoryTools] Added note ($category): $content');

    return ToolResult(
      success: true,
      message: 'Noted: $content',
    );
  }

  // ===========================================================================
  // RECALL MEMORIES
  // ===========================================================================

  ToolResult _recallMemories(Map<String, dynamic> args) {
    final query = (args['query'] as String? ?? '').toLowerCase();

    final buffer = StringBuffer();

    // If query is "owner" or empty, return owner notes
    if (query.isEmpty || query == 'owner') {
      if (_memories.owner.isEmpty) {
        buffer.writeln('No owner notes saved yet.');
      } else {
        buffer.writeln('Owner notes:');
        for (final note in _memories.owner.notes) {
          buffer.writeln('  - $note');
        }
      }
    }

    // Search people
    if (query.isNotEmpty && query != 'owner') {
      final matchingPeople = _memories.people.where(
        (p) => p.name.toLowerCase().contains(query) ||
               p.relationship.toLowerCase().contains(query),
      ).toList();

      if (matchingPeople.isNotEmpty) {
        for (final person in matchingPeople) {
          buffer.writeln('${person.name}${person.relationship.isNotEmpty ? " (${person.relationship})" : ""}');
          if (person.interests != null) {
            buffer.writeln('  Interests: ${person.interests}');
          }
          if (person.notes.isNotEmpty) {
            buffer.writeln('  Notes: ${person.notes.join("; ")}');
          }
        }
      }
    }

    // Search notes
    if (query.isNotEmpty) {
      final matchingNotes = _memories.notes.where(
        (n) => n.content.toLowerCase().contains(query) ||
               n.category.toLowerCase().contains(query),
      ).toList();

      if (matchingNotes.isNotEmpty) {
        buffer.writeln('Related notes:');
        for (final note in matchingNotes.take(5)) {
          buffer.writeln('  - ${note.content}');
        }
      }
    }

    final result = buffer.toString().trim();
    if (result.isEmpty) {
      return ToolResult(
        success: true,
        message: 'No memories found for "$query"',
      );
    }

    return ToolResult(
      success: true,
      message: result,
    );
  }

  // ===========================================================================
  // GET OWNER INFO
  // ===========================================================================

  ToolResult _getOwnerInfo() {
    if (_memories.owner.isEmpty) {
      return ToolResult(
        success: true,
        message: 'No owner notes saved yet.',
      );
    }

    final buffer = StringBuffer();
    buffer.writeln('Owner notes:');
    for (final note in _memories.owner.notes) {
      buffer.writeln('  - $note');
    }

    return ToolResult(
      success: true,
      message: buffer.toString().trim(),
    );
  }

  // ===========================================================================
  // CONTEXT FOR SYSTEM PROMPT
  // ===========================================================================

  String getMemoryContext() {
    if (_memories.isEmpty) {
      return '';  // No memory context when empty - owner info is in UserProfile
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
