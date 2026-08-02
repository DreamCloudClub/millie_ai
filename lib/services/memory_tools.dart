import 'package:flutter/foundation.dart';
import 'workflow_tools.dart';
import 'local_memory_service.dart';

/// Memory Tools for AI function calling
/// Allows the agent to remember and recall information about:
/// - Owner notes
/// - People it meets (name, relationship, notes)
/// - General notes and observations
class MemoryTools {
  final LocalMemoryService memoryService;

  MemoryTools(this.memoryService);

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

  Future<ToolResult> _addOwnerNote(Map<String, dynamic> args) async {
    final note = args['note'] as String?;
    if (note == null || note.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Note content is required',
      );
    }

    await memoryService.addOwnerNote(note);

    return ToolResult(
      success: true,
      message: 'Saved note about owner: $note',
    );
  }

  // ===========================================================================
  // REMEMBER A PERSON
  // ===========================================================================

  Future<ToolResult> _rememberPerson(Map<String, dynamic> args) async {
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

    final person = KnownPerson(
      name: name,
      relationship: relationship,
      interests: interests,
      notes: notes,
    );

    await memoryService.rememberPerson(person);

    return ToolResult(
      success: true,
      message: 'Remembered $name${relationship.isNotEmpty ? " ($relationship)" : ""}',
    );
  }

  // ===========================================================================
  // ADD A NOTE
  // ===========================================================================

  Future<ToolResult> _addMemoryNote(Map<String, dynamic> args) async {
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

    await memoryService.addNote(note);

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
    final memories = memoryService.memories;

    final buffer = StringBuffer();

    // If query is "owner" or empty, return owner notes
    if (query.isEmpty || query == 'owner') {
      if (memories.owner.isEmpty) {
        buffer.writeln('No owner notes saved yet.');
      } else {
        buffer.writeln('Owner notes:');
        for (final note in memories.owner.notes) {
          buffer.writeln('  - $note');
        }
      }
    }

    // Search people
    if (query.isNotEmpty && query != 'owner') {
      final matchingPeople = memories.people.where(
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
      final matchingNotes = memoryService.searchNotes(query);

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
    final memories = memoryService.memories;

    if (memories.owner.isEmpty) {
      return ToolResult(
        success: true,
        message: 'No owner notes saved yet.',
      );
    }

    final buffer = StringBuffer();
    buffer.writeln('Owner notes:');
    for (final note in memories.owner.notes) {
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
    return memoryService.getMemoryContext();
  }
}
