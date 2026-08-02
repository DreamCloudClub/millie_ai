import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/reminder.dart';

/// Service for managing reminders in local storage
class ReminderService extends ChangeNotifier {
  static const String _storageKey = 'reminders';
  static final _uuid = const Uuid();

  List<Reminder> _reminders = [];
  bool _isLoading = false;
  String? _error;

  List<Reminder> get reminders => _reminders;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Get reminders that are not completed (future reminders)
  List<Reminder> get activeReminders => _reminders
      .where((r) => !r.isCompleted)
      .toList()
    ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));

  /// Get past reminders (triggered within last 24 hours)
  List<Reminder> getPastReminders() {
    final now = DateTime.now();
    final oneDayAgo = now.subtract(const Duration(days: 1));

    return _reminders
        .where((r) =>
            r.lastTriggeredAt != null && r.lastTriggeredAt!.isAfter(oneDayAgo))
        .toList()
      ..sort((a, b) {
        final aTime = a.lastTriggeredAt!;
        final bTime = b.lastTriggeredAt!;
        return bTime.compareTo(aTime);
      });
  }

  /// Initialize service and load reminders
  Future<void> init() async {
    await loadReminders();
  }

  /// Load reminders from local storage
  Future<void> loadReminders() async {
    _isLoading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_storageKey);

      if (data != null && data.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(data);
        final loadedReminders = <Reminder>[];

        final today = DateTime.now();
        final todayStart = DateTime(today.year, today.month, today.day);
        final oneDayAgo = DateTime.now().subtract(const Duration(days: 1));

        for (final item in decoded) {
          try {
            final reminder = Reminder.fromJson(item as Map<String, dynamic>);
            final isRecurring = reminder.recurrence != ReminderRecurrence.none;
            final scheduledDate = DateTime(
              reminder.scheduledAt.year,
              reminder.scheduledAt.month,
              reminder.scheduledAt.day,
            );

            final hasRecentTrigger = reminder.lastTriggeredAt != null &&
                reminder.lastTriggeredAt!.isAfter(oneDayAgo);

            if (isRecurring ||
                scheduledDate.isAtSameMomentAs(todayStart) ||
                scheduledDate.isAfter(todayStart) ||
                hasRecentTrigger) {
              loadedReminders.add(reminder);
            }
          } catch (e) {
            debugPrint('Error parsing reminder: $e');
          }
        }

        _reminders = loadedReminders;
        debugPrint('ReminderService: Loaded ${_reminders.length} reminders');
      } else {
        _reminders = [];
      }

      _error = null;
    } catch (e) {
      debugPrint('ReminderService: Error loading reminders: $e');
      _error = 'Failed to load reminders';
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Save reminders to local storage
  Future<void> _saveReminders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _reminders.map((r) => r.toJson()).toList();
      await prefs.setString(_storageKey, jsonEncode(data));
      debugPrint('ReminderService: Saved ${_reminders.length} reminders');
    } catch (e) {
      debugPrint('ReminderService: Error saving reminders: $e');
    }
  }

  /// Create a new reminder
  Future<Reminder?> createReminder({
    required String title,
    required DateTime scheduledAt,
    DateTime? eventTime,
    int? advanceNoticeMinutes,
    ReminderRecurrence recurrence = ReminderRecurrence.none,
    DateTime? recurrenceEndDate,
    String? notes,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final now = DateTime.now();
      final reminderId = _uuid.v4();

      Map<String, dynamic>? metadata;
      if (notes != null && notes.isNotEmpty) {
        metadata = {'notes': notes};
      }

      final reminder = Reminder(
        id: reminderId,
        title: title,
        scheduledAt: scheduledAt,
        eventTime: eventTime,
        advanceNoticeMinutes: advanceNoticeMinutes,
        recurrence: recurrence,
        recurrenceEndDate: recurrenceEndDate,
        metadata: metadata,
        createdAt: now,
        updatedAt: now,
      );

      _reminders.add(reminder);
      _reminders.sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
      await _saveReminders();

      _error = null;
      _isLoading = false;
      notifyListeners();

      return reminder;
    } catch (e) {
      debugPrint('ReminderService: Error creating reminder: $e');
      _error = 'Failed to create reminder';
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  /// Update an existing reminder
  Future<bool> updateReminder({
    required String reminderId,
    String? title,
    DateTime? scheduledAt,
    DateTime? eventTime,
    int? advanceNoticeMinutes,
    ReminderRecurrence? recurrence,
    DateTime? recurrenceEndDate,
    DateTime? completedAt,
    bool? reminderSent,
    String? notes,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final index = _reminders.indexWhere((r) => r.id == reminderId);
      if (index == -1) {
        _error = 'Reminder not found';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final existing = _reminders[index];
      final existingMetadata = Map<String, dynamic>.from(existing.metadata ?? {});
      if (notes != null) {
        existingMetadata['notes'] = notes;
      }

      final updated = existing.copyWith(
        title: title,
        scheduledAt: scheduledAt,
        eventTime: eventTime,
        advanceNoticeMinutes: advanceNoticeMinutes,
        recurrence: recurrence,
        completedAt: completedAt,
        reminderSent: reminderSent,
        metadata: existingMetadata.isNotEmpty ? existingMetadata : null,
        updatedAt: DateTime.now(),
      );

      _reminders[index] = updated;
      _reminders.sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
      await _saveReminders();

      _error = null;
      _isLoading = false;
      notifyListeners();

      return true;
    } catch (e) {
      debugPrint('ReminderService: Error updating reminder: $e');
      _error = 'Failed to update reminder';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Delete a reminder
  Future<bool> deleteReminder(String reminderId) async {
    _isLoading = true;
    notifyListeners();

    try {
      _reminders.removeWhere((r) => r.id == reminderId);
      await _saveReminders();

      _error = null;
      _isLoading = false;
      notifyListeners();

      return true;
    } catch (e) {
      debugPrint('ReminderService: Error deleting reminder: $e');
      _error = 'Failed to delete reminder';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Get reminder by ID
  Reminder? getReminderById(String id) {
    try {
      return _reminders.firstWhere((r) => r.id == id);
    } catch (_) {
      return null;
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
