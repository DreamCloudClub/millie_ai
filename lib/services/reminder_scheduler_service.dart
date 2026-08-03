import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/reminder.dart';
import 'reminder_service.dart';
import 'conversation_service.dart';

/// Service that polls for due reminders and triggers voice alerts
class ReminderSchedulerService {
  static ReminderSchedulerService? _instance;
  static ReminderSchedulerService get instance {
    _instance ??= ReminderSchedulerService._();
    return _instance!;
  }

  ReminderSchedulerService._();

  Timer? _pollTimer;
  ReminderService? _reminderService;
  ConversationService? _conversationService;
  bool _isOnFacePage = false;
  String _username = 'there';

  /// Callback when an alert is triggered (for UI notification)
  VoidCallback? onAlertTriggered;

  /// Initialize with required services
  void init({
    required ReminderService reminderService,
    required ConversationService conversationService,
  }) {
    _reminderService = reminderService;
    _conversationService = conversationService;
    debugPrint('🔔 [ReminderScheduler] Initialized');
  }

  /// Set whether user is on the face page (voice alerts only work on face page)
  void setOnFacePage(bool isOnFacePage) {
    _isOnFacePage = isOnFacePage;
    debugPrint('🔔 [ReminderScheduler] On face page: $isOnFacePage');
  }

  /// Set the username for personalized alerts
  void setUsername(String username) {
    _username = username;
  }

  /// Start polling for due reminders
  void startPolling() {
    stopPolling();
    debugPrint('🔔 [ReminderScheduler] Starting polling (every 30s)');

    // Check immediately
    _checkDueReminders();

    // Then poll every 30 seconds
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkDueReminders();
    });
  }

  /// Stop polling
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Check for due reminders and trigger alerts
  Future<void> _checkDueReminders() async {
    if (_reminderService == null || _conversationService == null) {
      debugPrint('🔔 [ReminderScheduler] Services not initialized');
      return;
    }

    final now = DateTime.now();
    final tenMinutesAgo = now.subtract(const Duration(minutes: 10));

    // Find reminders that are due but not yet triggered
    final dueReminders = _reminderService!.reminders.where((reminder) {
      // Skip if already sent
      if (reminder.reminderSent) return false;

      // Skip if completed
      if (reminder.isCompleted) return false;

      // Check if scheduled time has passed
      if (reminder.scheduledAt.isAfter(now)) return false;

      // Skip if too old (more than 10 minutes ago)
      if (reminder.scheduledAt.isBefore(tenMinutesAgo)) return false;

      return true;
    }).toList();

    if (dueReminders.isEmpty) return;

    debugPrint('🔔 [ReminderScheduler] Found ${dueReminders.length} due reminder(s)');

    // Process each due reminder
    for (final reminder in dueReminders) {
      await _triggerReminder(reminder);
    }
  }

  /// Trigger a single reminder
  Future<void> _triggerReminder(Reminder reminder) async {
    debugPrint('🔔 [ReminderScheduler] Triggering: ${reminder.title}');

    // Mark as sent immediately to prevent re-triggering
    await _reminderService!.updateReminder(
      reminderId: reminder.id,
      reminderSent: true,
    );

    // Build the announcement message
    final message = _buildAnnouncementMessage(reminder);
    final context = _buildAlertContext(reminder);

    // If on face page, deliver via voice
    if (_isOnFacePage) {
      debugPrint('🔔 [ReminderScheduler] Delivering voice alert');
      await _conversationService!.deliverAlert(
        alertMessage: message,
        alertContext: context,
      );
      onAlertTriggered?.call();
    } else {
      // TODO: Show notification when not on face page
      debugPrint('🔔 [ReminderScheduler] Not on face page - would show notification');
    }

    // Handle recurring reminders - schedule next occurrence
    if (reminder.recurrence != ReminderRecurrence.none) {
      await _scheduleNextOccurrence(reminder);
    }
  }

  /// Build the spoken announcement message
  String _buildAnnouncementMessage(Reminder reminder) {
    final timeStr = _formatTime(reminder.scheduledAt);
    final title = reminder.title;

    String message = "Reminder: $title. It's $timeStr";

    // Add notes if present
    final notes = reminder.metadata?['notes'] as String?;
    if (notes != null && notes.isNotEmpty) {
      message += ". $notes";
    }

    return message;
  }

  /// Build context string for the AI
  String _buildAlertContext(Reminder reminder) {
    final buffer = StringBuffer();
    buffer.writeln('Reminder: ${reminder.title}');
    buffer.writeln('Scheduled for: ${_formatTime(reminder.scheduledAt)}');

    if (reminder.eventTime != null) {
      buffer.writeln('Event time: ${_formatTime(reminder.eventTime!)}');
    }

    final notes = reminder.metadata?['notes'] as String?;
    if (notes != null && notes.isNotEmpty) {
      buffer.writeln('Notes: $notes');
    }

    if (reminder.recurrence != ReminderRecurrence.none) {
      buffer.writeln('Recurrence: ${reminder.recurrence.displayName}');
    }

    return buffer.toString();
  }

  /// Format time for speech
  String _formatTime(DateTime time) {
    final hour = time.hour;
    final minute = time.minute;

    String hourStr;
    String period;

    if (hour == 0) {
      hourStr = '12';
      period = 'AM';
    } else if (hour < 12) {
      hourStr = hour.toString();
      period = 'AM';
    } else if (hour == 12) {
      hourStr = '12';
      period = 'PM';
    } else {
      hourStr = (hour - 12).toString();
      period = 'PM';
    }

    if (minute == 0) {
      return "$hourStr $period";
    } else {
      final minuteStr = minute.toString().padLeft(2, '0');
      return "$hourStr:$minuteStr $period";
    }
  }

  /// Schedule the next occurrence for a recurring reminder
  Future<void> _scheduleNextOccurrence(Reminder reminder) async {
    DateTime nextTime;

    switch (reminder.recurrence) {
      case ReminderRecurrence.daily:
        nextTime = reminder.scheduledAt.add(const Duration(days: 1));
        break;
      case ReminderRecurrence.weekly:
        nextTime = reminder.scheduledAt.add(const Duration(days: 7));
        break;
      case ReminderRecurrence.monthly:
        nextTime = DateTime(
          reminder.scheduledAt.year,
          reminder.scheduledAt.month + 1,
          reminder.scheduledAt.day,
          reminder.scheduledAt.hour,
          reminder.scheduledAt.minute,
        );
        break;
      case ReminderRecurrence.none:
        return;
    }

    // Check if past end date
    if (reminder.recurrenceEndDate != null &&
        nextTime.isAfter(reminder.recurrenceEndDate!)) {
      debugPrint('🔔 [ReminderScheduler] Recurring reminder ended');
      return;
    }

    // Update the reminder with next occurrence
    await _reminderService!.updateReminder(
      reminderId: reminder.id,
      scheduledAt: nextTime,
      reminderSent: false,
    );

    debugPrint('🔔 [ReminderScheduler] Next occurrence scheduled: $nextTime');
  }

  /// Dispose resources
  void dispose() {
    stopPolling();
    _instance = null;
  }
}
