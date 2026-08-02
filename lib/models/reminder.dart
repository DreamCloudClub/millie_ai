import 'package:flutter/foundation.dart';

enum ReminderRecurrence {
  none,
  daily,
  weekly,
  monthly,
}

extension ReminderRecurrenceExtension on ReminderRecurrence {
  String get displayName {
    switch (this) {
      case ReminderRecurrence.none:
        return 'None';
      case ReminderRecurrence.daily:
        return 'Daily';
      case ReminderRecurrence.weekly:
        return 'Weekly';
      case ReminderRecurrence.monthly:
        return 'Monthly';
    }
  }

  String get value {
    switch (this) {
      case ReminderRecurrence.none:
        return 'none';
      case ReminderRecurrence.daily:
        return 'daily';
      case ReminderRecurrence.weekly:
        return 'weekly';
      case ReminderRecurrence.monthly:
        return 'monthly';
    }
  }

  static ReminderRecurrence fromString(String value) {
    switch (value) {
      case 'daily':
        return ReminderRecurrence.daily;
      case 'weekly':
        return ReminderRecurrence.weekly;
      case 'monthly':
        return ReminderRecurrence.monthly;
      default:
        return ReminderRecurrence.none;
    }
  }
}

@immutable
class Reminder {
  final String id;
  final String title;
  final DateTime scheduledAt;
  final DateTime? eventTime;
  final int? advanceNoticeMinutes;
  final ReminderRecurrence recurrence;
  final DateTime? recurrenceEndDate;
  final DateTime? completedAt;
  final bool reminderSent;
  final DateTime? lastTriggeredAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? metadata;

  const Reminder({
    required this.id,
    required this.title,
    required this.scheduledAt,
    this.eventTime,
    this.advanceNoticeMinutes,
    this.recurrence = ReminderRecurrence.none,
    this.recurrenceEndDate,
    this.completedAt,
    this.reminderSent = false,
    this.lastTriggeredAt,
    required this.createdAt,
    required this.updatedAt,
    this.metadata,
  });

  bool get isCompleted => completedAt != null;
  bool get isOverdue => !isCompleted && scheduledAt.isBefore(DateTime.now());

  bool get isDueToday {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final scheduledDate = DateTime(scheduledAt.year, scheduledAt.month, scheduledAt.day);
    return scheduledDate == today;
  }

  bool get isDueTomorrow {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final scheduledDate = DateTime(scheduledAt.year, scheduledAt.month, scheduledAt.day);
    return scheduledDate == tomorrow;
  }

  DateTime get actualEventTime => eventTime ?? scheduledAt;

  Reminder copyWith({
    String? id,
    String? title,
    DateTime? scheduledAt,
    DateTime? eventTime,
    int? advanceNoticeMinutes,
    ReminderRecurrence? recurrence,
    DateTime? recurrenceEndDate,
    DateTime? completedAt,
    bool? reminderSent,
    DateTime? lastTriggeredAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? metadata,
  }) {
    return Reminder(
      id: id ?? this.id,
      title: title ?? this.title,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      eventTime: eventTime ?? this.eventTime,
      advanceNoticeMinutes: advanceNoticeMinutes ?? this.advanceNoticeMinutes,
      recurrence: recurrence ?? this.recurrence,
      recurrenceEndDate: recurrenceEndDate ?? this.recurrenceEndDate,
      completedAt: completedAt ?? this.completedAt,
      reminderSent: reminderSent ?? this.reminderSent,
      lastTriggeredAt: lastTriggeredAt ?? this.lastTriggeredAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'scheduled_at': scheduledAt.toIso8601String(),
      'event_time': eventTime?.toIso8601String(),
      'advance_notice_minutes': advanceNoticeMinutes,
      'recurrence': recurrence.value,
      'recurrence_end_date': recurrenceEndDate?.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
      'reminder_sent': reminderSent,
      'last_triggered_at': lastTriggeredAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'metadata': metadata,
    };
  }

  factory Reminder.fromJson(Map<String, dynamic> json) {
    return Reminder(
      id: json['id'] as String,
      title: json['title'] as String,
      scheduledAt: DateTime.parse(json['scheduled_at'] as String),
      eventTime: json['event_time'] != null
          ? DateTime.parse(json['event_time'] as String)
          : null,
      advanceNoticeMinutes: json['advance_notice_minutes'] as int?,
      recurrence: ReminderRecurrenceExtension.fromString(
        json['recurrence'] as String? ?? 'none',
      ),
      recurrenceEndDate: json['recurrence_end_date'] != null
          ? DateTime.parse(json['recurrence_end_date'] as String)
          : null,
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
      reminderSent: json['reminder_sent'] as bool? ?? false,
      lastTriggeredAt: json['last_triggered_at'] != null
          ? DateTime.parse(json['last_triggered_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }
}
