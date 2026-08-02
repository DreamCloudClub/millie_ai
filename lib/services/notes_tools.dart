import 'package:flutter/foundation.dart';
import '../models/note.dart';
import '../models/reminder.dart';
import 'notes_service.dart';
import 'reminder_service.dart';
import 'workflow_tools.dart';

/// Notes & Schedule Tools for AI function calling
/// Allows the AI to create and manage notes and reminders/alerts
class NotesTools {
  final ReminderService reminderService;

  // Callback when notes list should be refreshed
  VoidCallback? onNotesListChanged;

  // Callback when schedule list should be refreshed
  VoidCallback? onScheduleListChanged;

  // Callback to open a specific note (navigates to note view page)
  void Function(String noteId)? onOpenNote;

  NotesTools({required this.reminderService});

  void dispose() {
    // No listeners to clean up
  }

  void clear() {
    // No transient state to clear
  }

  // ===========================================================================
  // TOOL DEFINITIONS
  // ===========================================================================

  static List<Map<String, dynamic>> get toolDefinitions => [
    // ===== NOTES TOOLS =====
    {
      'type': 'function',
      'function': {
        'name': 'create_note',
        'description': 'Create a new note. Use when user says "save this", "make a note", "write down", "remember this". After creating, confirm briefly with the title.',
        'parameters': {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': 'The title of the note (e.g., "Shopping List", "Meeting Notes")',
            },
            'content': {
              'type': 'string',
              'description': 'The content of the note. Format nicely with line breaks as needed.',
            },
          },
          'required': ['title', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_notes',
        'description': 'Get a list of all saved notes. Use when user asks "what notes do I have" or wants to find a specific note.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_notes',
        'description': 'Search for notes by title or content. Use to find a specific note.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search term to look for in note titles and content',
            },
          },
          'required': ['query'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'open_note',
        'description': 'Open a note on screen for the user to view. Use when user says "open my note", "show me that note", "pull up the note". Does NOT read the content aloud - just displays it visually. Can search by title.',
        'parameters': {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': 'The title or partial title to search for (e.g., "shopping list", "meeting notes")',
            },
          },
          'required': ['title'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_note',
        'description': 'Read a note aloud to the user. ONLY use when user explicitly asks you to READ the note to them (e.g., "read it to me", "what does it say"). For just showing/opening, use open_note instead.',
        'parameters': {
          'type': 'object',
          'properties': {
            'note_id': {
              'type': 'string',
              'description': 'The ID of the note to read aloud',
            },
          },
          'required': ['note_id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'delete_note',
        'description': 'Delete a note permanently. Only use when explicitly requested.',
        'parameters': {
          'type': 'object',
          'properties': {
            'note_id': {
              'type': 'string',
              'description': 'The ID of the note to delete',
            },
          },
          'required': ['note_id'],
        },
      },
    },
    // ===== SCHEDULE/ALERT TOOLS =====
    {
      'type': 'function',
      'function': {
        'name': 'create_alert',
        'description': 'Create a new alert/reminder. Use when user says "remind me", "set an alert", "schedule". Parse natural language times like "tomorrow at 3pm", "in 2 hours".',
        'parameters': {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': 'What the alert is about (e.g., "Call mom", "Take medicine")',
            },
            'date': {
              'type': 'string',
              'description': 'The date in YYYY-MM-DD format (e.g., "2024-12-25")',
            },
            'time': {
              'type': 'string',
              'description': 'The time in HH:MM 24-hour format (e.g., "14:30" for 2:30 PM)',
            },
            'recurrence': {
              'type': 'string',
              'enum': ['none', 'daily', 'weekly', 'monthly'],
              'description': 'How often to repeat: none, daily, weekly, or monthly',
            },
            'notes': {
              'type': 'string',
              'description': 'Optional additional notes',
            },
          },
          'required': ['title', 'date', 'time'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_alerts',
        'description': 'Get upcoming alerts. Use when user asks "what\'s on my schedule" or "what reminders do I have".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'delete_alert',
        'description': 'Delete an alert. First use list_alerts to get the ID.',
        'parameters': {
          'type': 'object',
          'properties': {
            'alert_id': {
              'type': 'string',
              'description': 'The ID of the alert to delete',
            },
          },
          'required': ['alert_id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'update_alert',
        'description': 'Update an existing alert. First use list_alerts to get the ID.',
        'parameters': {
          'type': 'object',
          'properties': {
            'alert_id': {
              'type': 'string',
              'description': 'The ID of the alert to update',
            },
            'title': {
              'type': 'string',
              'description': 'New title (optional)',
            },
            'date': {
              'type': 'string',
              'description': 'New date in YYYY-MM-DD format (optional)',
            },
            'time': {
              'type': 'string',
              'description': 'New time in HH:MM 24-hour format (optional)',
            },
            'recurrence': {
              'type': 'string',
              'enum': ['none', 'daily', 'weekly', 'monthly'],
              'description': 'New recurrence (optional)',
            },
            'notes': {
              'type': 'string',
              'description': 'New notes (optional)',
            },
          },
          'required': ['alert_id'],
        },
      },
    },
  ];

  // ===========================================================================
  // TOOL EXECUTION
  // ===========================================================================

  Future<ToolResult> executeTool(ToolCall toolCall) async {
    debugPrint('📝 [NotesTools] Executing: ${toolCall.name}');

    switch (toolCall.name) {
      // Notes
      case 'create_note':
        return await _createNote(toolCall.arguments);
      case 'list_notes':
        return await _listNotes();
      case 'search_notes':
        return await _searchNotes(toolCall.arguments);
      case 'open_note':
        return await _openNote(toolCall.arguments);
      case 'get_note':
        return await _getNote(toolCall.arguments);
      case 'delete_note':
        return await _deleteNote(toolCall.arguments);

      // Alerts
      case 'create_alert':
        return await _createAlert(toolCall.arguments);
      case 'list_alerts':
        return _listAlerts();
      case 'delete_alert':
        return await _deleteAlert(toolCall.arguments);
      case 'update_alert':
        return await _updateAlert(toolCall.arguments);

      default:
        return ToolResult(
          success: false,
          message: 'Unknown notes tool: ${toolCall.name}',
        );
    }
  }

  // ===========================================================================
  // NOTES METHODS
  // ===========================================================================

  Future<ToolResult> _createNote(Map<String, dynamic> args) async {
    final title = args['title'] as String? ?? 'Untitled Note';
    final content = args['content'] as String? ?? '';

    try {
      final note = await NotesService.createNote(
        title: title,
        content: content,
      );

      if (note != null) {
        onNotesListChanged?.call();
        return ToolResult(
          success: true,
          message: 'Created note "$title".',
        );
      } else {
        return ToolResult(
          success: false,
          message: 'Failed to create note.',
        );
      }
    } catch (e) {
      debugPrint('NotesTools: Error creating note: $e');
      return ToolResult(
        success: false,
        message: 'Error creating note: $e',
      );
    }
  }

  Future<ToolResult> _listNotes() async {
    try {
      final notes = await NotesService.getNotes();

      if (notes.isEmpty) {
        return ToolResult(
          success: true,
          message: 'You don\'t have any notes yet.',
        );
      }

      final noteList = notes.take(10).map((n) => '- ${n.title} (ID: ${n.id})').join('\n');
      return ToolResult(
        success: true,
        message: 'You have ${notes.length} note(s):\n$noteList',
      );
    } catch (e) {
      return ToolResult(
        success: false,
        message: 'Error listing notes: $e',
      );
    }
  }

  Future<ToolResult> _searchNotes(Map<String, dynamic> args) async {
    final query = args['query'] as String? ?? '';

    if (query.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Please provide a search term.',
      );
    }

    try {
      final notes = await NotesService.searchNotes(query);

      if (notes.isEmpty) {
        return ToolResult(
          success: true,
          message: 'No notes found matching "$query".',
        );
      }

      final noteList = notes.take(5).map((n) => '- ${n.title} (ID: ${n.id})').join('\n');
      return ToolResult(
        success: true,
        message: 'Found ${notes.length} note(s) matching "$query":\n$noteList',
      );
    } catch (e) {
      return ToolResult(
        success: false,
        message: 'Error searching notes: $e',
      );
    }
  }

  Future<ToolResult> _openNote(Map<String, dynamic> args) async {
    final title = args['title'] as String?;

    if (title == null || title.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Note title is required.',
      );
    }

    try {
      // Search for the note by title
      final notes = await NotesService.searchNotes(title);

      if (notes.isEmpty) {
        return ToolResult(
          success: false,
          message: 'No note found matching "$title".',
        );
      }

      // Use the first matching note
      final note = notes.first;

      // Call the callback to open the note visually
      if (onOpenNote != null) {
        onOpenNote!(note.id);
        return ToolResult(
          success: true,
          message: 'Opened "${note.title}".',
        );
      } else {
        return ToolResult(
          success: false,
          message: 'Cannot open note - display not available.',
        );
      }
    } catch (e) {
      return ToolResult(
        success: false,
        message: 'Error opening note: $e',
      );
    }
  }

  Future<ToolResult> _getNote(Map<String, dynamic> args) async {
    final noteId = args['note_id'] as String?;

    if (noteId == null || noteId.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Note ID is required.',
      );
    }

    try {
      final note = await NotesService.getNote(noteId);

      if (note == null) {
        return ToolResult(
          success: false,
          message: 'Note not found.',
        );
      }

      return ToolResult(
        success: true,
        message: 'Note "${note.title}":\n${note.content}',
      );
    } catch (e) {
      return ToolResult(
        success: false,
        message: 'Error getting note: $e',
      );
    }
  }

  Future<ToolResult> _deleteNote(Map<String, dynamic> args) async {
    final noteId = args['note_id'] as String?;

    if (noteId == null || noteId.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Note ID is required.',
      );
    }

    try {
      final note = await NotesService.getNote(noteId);
      final title = note?.title ?? 'the note';

      final success = await NotesService.deleteNote(noteId);

      if (success) {
        onNotesListChanged?.call();
        return ToolResult(
          success: true,
          message: 'Deleted "$title".',
        );
      } else {
        return ToolResult(
          success: false,
          message: 'Failed to delete note.',
        );
      }
    } catch (e) {
      return ToolResult(
        success: false,
        message: 'Error deleting note: $e',
      );
    }
  }

  // ===========================================================================
  // ALERT METHODS
  // ===========================================================================

  Future<ToolResult> _createAlert(Map<String, dynamic> args) async {
    final title = args['title'] as String?;
    final dateStr = args['date'] as String?;
    final timeStr = args['time'] as String?;
    final recurrenceStr = args['recurrence'] as String? ?? 'none';
    final notes = args['notes'] as String?;

    if (title == null || title.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Please provide a title for the alert.',
      );
    }

    if (dateStr == null || timeStr == null) {
      return ToolResult(
        success: false,
        message: 'Please provide both date and time for the alert.',
      );
    }

    try {
      // Parse date and time
      final dateParts = dateStr.split('-');
      final timeParts = timeStr.split(':');

      if (dateParts.length != 3 || timeParts.length < 2) {
        return ToolResult(
          success: false,
          message: 'Invalid date/time format. Use YYYY-MM-DD for date and HH:MM for time.',
        );
      }

      final scheduledAt = DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
      );

      // Parse recurrence
      ReminderRecurrence recurrence;
      switch (recurrenceStr.toLowerCase()) {
        case 'daily':
          recurrence = ReminderRecurrence.daily;
          break;
        case 'weekly':
          recurrence = ReminderRecurrence.weekly;
          break;
        case 'monthly':
          recurrence = ReminderRecurrence.monthly;
          break;
        default:
          recurrence = ReminderRecurrence.none;
      }

      final reminder = await reminderService.createReminder(
        title: title,
        scheduledAt: scheduledAt,
        recurrence: recurrence,
        notes: notes,
      );

      if (reminder != null) {
        onScheduleListChanged?.call();

        // Format confirmation
        final timeFormatted = _formatTime(scheduledAt);
        final dateFormatted = _formatDate(scheduledAt);
        String msg = 'Alert set for $dateFormatted at $timeFormatted: "$title"';
        if (recurrence != ReminderRecurrence.none) {
          msg += ' (repeats ${recurrence.displayName.toLowerCase()})';
        }

        return ToolResult(
          success: true,
          message: msg,
        );
      } else {
        return ToolResult(
          success: false,
          message: 'Failed to create alert.',
        );
      }
    } catch (e) {
      debugPrint('NotesTools: Error creating alert: $e');
      return ToolResult(
        success: false,
        message: 'Error creating alert: $e',
      );
    }
  }

  ToolResult _listAlerts() {
    try {
      final alerts = reminderService.activeReminders;

      if (alerts.isEmpty) {
        return ToolResult(
          success: true,
          message: 'You don\'t have any upcoming alerts.',
        );
      }

      final alertList = alerts.take(10).map((a) {
        final dateStr = _formatDate(a.scheduledAt);
        final timeStr = _formatTime(a.scheduledAt);
        return '- ${a.title} on $dateStr at $timeStr (ID: ${a.id})';
      }).join('\n');

      return ToolResult(
        success: true,
        message: 'You have ${alerts.length} upcoming alert(s):\n$alertList',
      );
    } catch (e) {
      return ToolResult(
        success: false,
        message: 'Error listing alerts: $e',
      );
    }
  }

  Future<ToolResult> _deleteAlert(Map<String, dynamic> args) async {
    final alertId = args['alert_id'] as String?;

    if (alertId == null || alertId.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Alert ID is required.',
      );
    }

    try {
      final existing = reminderService.getReminderById(alertId);
      final title = existing?.title ?? 'the alert';

      final success = await reminderService.deleteReminder(alertId);

      if (success) {
        onScheduleListChanged?.call();
        return ToolResult(
          success: true,
          message: 'Deleted "$title".',
        );
      } else {
        return ToolResult(
          success: false,
          message: 'Failed to delete alert.',
        );
      }
    } catch (e) {
      return ToolResult(
        success: false,
        message: 'Error deleting alert: $e',
      );
    }
  }

  Future<ToolResult> _updateAlert(Map<String, dynamic> args) async {
    final alertId = args['alert_id'] as String?;

    if (alertId == null || alertId.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Alert ID is required.',
      );
    }

    try {
      final existing = reminderService.getReminderById(alertId);
      if (existing == null) {
        return ToolResult(
          success: false,
          message: 'Alert not found.',
        );
      }

      // Parse optional updates
      final title = args['title'] as String?;
      final dateStr = args['date'] as String?;
      final timeStr = args['time'] as String?;
      final recurrenceStr = args['recurrence'] as String?;
      final notes = args['notes'] as String?;

      DateTime? scheduledAt;
      if (dateStr != null && timeStr != null) {
        final dateParts = dateStr.split('-');
        final timeParts = timeStr.split(':');
        scheduledAt = DateTime(
          int.parse(dateParts[0]),
          int.parse(dateParts[1]),
          int.parse(dateParts[2]),
          int.parse(timeParts[0]),
          int.parse(timeParts[1]),
        );
      } else if (dateStr != null) {
        final dateParts = dateStr.split('-');
        scheduledAt = DateTime(
          int.parse(dateParts[0]),
          int.parse(dateParts[1]),
          int.parse(dateParts[2]),
          existing.scheduledAt.hour,
          existing.scheduledAt.minute,
        );
      } else if (timeStr != null) {
        final timeParts = timeStr.split(':');
        scheduledAt = DateTime(
          existing.scheduledAt.year,
          existing.scheduledAt.month,
          existing.scheduledAt.day,
          int.parse(timeParts[0]),
          int.parse(timeParts[1]),
        );
      }

      ReminderRecurrence? recurrence;
      if (recurrenceStr != null) {
        switch (recurrenceStr.toLowerCase()) {
          case 'daily':
            recurrence = ReminderRecurrence.daily;
            break;
          case 'weekly':
            recurrence = ReminderRecurrence.weekly;
            break;
          case 'monthly':
            recurrence = ReminderRecurrence.monthly;
            break;
          case 'none':
            recurrence = ReminderRecurrence.none;
            break;
        }
      }

      final success = await reminderService.updateReminder(
        reminderId: alertId,
        title: title,
        scheduledAt: scheduledAt,
        recurrence: recurrence,
        notes: notes,
      );

      if (success) {
        onScheduleListChanged?.call();
        return ToolResult(
          success: true,
          message: 'Updated the alert.',
        );
      } else {
        return ToolResult(
          success: false,
          message: 'Failed to update alert.',
        );
      }
    } catch (e) {
      return ToolResult(
        success: false,
        message: 'Error updating alert: $e',
      );
    }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  String _formatTime(DateTime dt) {
    final hour = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$displayHour:$minute $period';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final targetDate = DateTime(dt.year, dt.month, dt.day);

    if (targetDate == today) {
      return 'today';
    } else if (targetDate == tomorrow) {
      return 'tomorrow';
    } else {
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                     'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${months[dt.month - 1]} ${dt.day}';
    }
  }

  // ===========================================================================
  // CONTEXT FOR SYSTEM PROMPT
  // ===========================================================================

  String getNotesContext() {
    final buffer = StringBuffer();
    buffer.writeln('\n\nNOTES & SCHEDULE:');
    buffer.writeln('You can create notes and set alerts/reminders for the user.');
    buffer.writeln('- "save this" / "make a note" → create_note');
    buffer.writeln('- "remind me" / "set an alert" → create_alert (use YYYY-MM-DD date, HH:MM time)');
    buffer.writeln('- "what notes do I have" → list_notes');
    buffer.writeln('- "what\'s on my schedule" → list_alerts');

    // Add current date/time context
    final now = DateTime.now();
    final currentDate = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    buffer.writeln('Current date: ${weekdays[now.weekday - 1]}, $currentDate');

    return buffer.toString();
  }
}
