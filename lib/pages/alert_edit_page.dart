import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../models/reminder.dart';
import '../services/reminder_service.dart';
import '../widgets/simple_control_bar.dart';

/// Full page for editing/creating an alert
class AlertEditPage extends StatefulWidget {
  final Reminder? reminder;
  final ReminderService reminderService;
  final VoidCallback onSaved;
  final VoidCallback onDeleted;
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;
  final bool isPaused;
  final String statusText;

  const AlertEditPage({
    super.key,
    this.reminder,
    required this.reminderService,
    required this.onSaved,
    required this.onDeleted,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
    this.isPaused = true,
    this.statusText = 'Ready',
  });

  @override
  State<AlertEditPage> createState() => _AlertEditPageState();
}

class _AlertEditPageState extends State<AlertEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  ReminderRecurrence _recurrence = ReminderRecurrence.none;
  bool _isLoading = false;

  bool get isEditing => widget.reminder != null;

  @override
  void initState() {
    super.initState();
    if (isEditing) {
      _titleController.text = widget.reminder!.title;
      _selectedDate = DateTime(
        widget.reminder!.scheduledAt.year,
        widget.reminder!.scheduledAt.month,
        widget.reminder!.scheduledAt.day,
      );
      _selectedTime = TimeOfDay.fromDateTime(widget.reminder!.scheduledAt);
      _recurrence = widget.reminder!.recurrence;
      final notes = widget.reminder!.metadata?['notes'] as String?;
      if (notes != null) {
        _notesController.text = notes;
      }
    } else {
      final now = DateTime.now();
      _selectedDate = DateTime(now.year, now.month, now.day);
      _selectedTime = TimeOfDay.fromDateTime(now.add(const Duration(hours: 1)));
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime date) {
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
                    'July', 'August', 'September', 'October', 'November', 'December'];
    return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(primary: Colors.blue),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _selectTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? TimeOfDay.now(),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(primary: Colors.blue),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _selectedTime = picked);
    }
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedDate == null || _selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a date and time'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final scheduledAt = DateTime(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        _selectedTime!.hour,
        _selectedTime!.minute,
      );

      bool success;
      if (isEditing) {
        success = await widget.reminderService.updateReminder(
          reminderId: widget.reminder!.id,
          title: _titleController.text.trim(),
          scheduledAt: scheduledAt,
          recurrence: _recurrence,
          notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
        );
      } else {
        final reminder = await widget.reminderService.createReminder(
          title: _titleController.text.trim(),
          scheduledAt: scheduledAt,
          recurrence: _recurrence,
          notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
        );
        success = reminder != null;
      }

      setState(() => _isLoading = false);

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isEditing ? 'Alert saved' : 'Alert created'),
            backgroundColor: Colors.green,
          ),
        );
        widget.onSaved();
        Navigator.pop(context);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save alert'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleDelete() async {
    if (!isEditing) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: AppColors.dangerBright.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  color: AppColors.dangerBright,
                  size: 32,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Delete Alert?',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'This will permanently delete this alert.',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.7),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(color: Colors.white.withOpacity(0.3)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.dangerBright,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Delete'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ) ?? false;

    if (confirmed && mounted) {
      setState(() => _isLoading = true);

      try {
        final success = await widget.reminderService.deleteReminder(widget.reminder!.id);
        setState(() => _isLoading = false);

        if (success && mounted) {
          widget.onDeleted();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Alert deleted'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      } catch (e) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.dangerBright,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.arrow_back, color: Colors.white, size: 24),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Text(
                    isEditing ? 'Edit Alert' : 'New Alert',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

            // Form content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.15)),
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Subject field
                        TextFormField(
                          controller: _titleController,
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                          decoration: InputDecoration(
                            labelText: 'Subject',
                            labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Colors.blue),
                            ),
                            errorBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Colors.red),
                            ),
                            focusedErrorBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Colors.red),
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Subject is required';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: AppSpacing.md),

                        // Date picker
                        InkWell(
                          onTap: _selectDate,
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Date',
                              labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                              ),
                              suffixIcon: Icon(Icons.calendar_today, color: Colors.white.withOpacity(0.7)),
                            ),
                            child: Text(
                              _selectedDate != null
                                  ? _formatDate(_selectedDate!)
                                  : 'Select date',
                              style: const TextStyle(color: Colors.white, fontSize: 16),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),

                        // Time picker
                        InkWell(
                          onTap: _selectTime,
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Time',
                              labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                              ),
                              suffixIcon: Icon(Icons.access_time, color: Colors.white.withOpacity(0.7)),
                            ),
                            child: Text(
                              _selectedTime != null
                                  ? _selectedTime!.format(context)
                                  : 'Select time',
                              style: const TextStyle(color: Colors.white, fontSize: 16),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),

                        // Recurrence dropdown
                        DropdownButtonFormField<ReminderRecurrence>(
                          value: _recurrence,
                          dropdownColor: const Color(0xFF2A2A2A),
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                          decoration: InputDecoration(
                            labelText: 'Recurrence',
                            labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                            ),
                          ),
                          iconEnabledColor: Colors.white.withOpacity(0.7),
                          items: ReminderRecurrence.values.map((recurrence) {
                            return DropdownMenuItem(
                              value: recurrence,
                              child: Text(
                                recurrence.displayName,
                                style: const TextStyle(color: Colors.white),
                              ),
                            );
                          }).toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _recurrence = value);
                            }
                          },
                        ),
                        const SizedBox(height: AppSpacing.md),

                        // Notes field
                        TextFormField(
                          controller: _notesController,
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                          maxLines: 4,
                          decoration: InputDecoration(
                            labelText: 'Notes (optional)',
                            alignLabelWithHint: true,
                            labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Colors.blue),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xl),

                        // Save button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _handleSave,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Save Alert',
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                  ),
                          ),
                        ),

                        // Delete button (only when editing)
                        if (isEditing) ...[
                          const SizedBox(height: AppSpacing.md),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _handleDelete,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.dangerBright,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Delete Alert',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Status text
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(
                widget.statusText,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
            ),

            // Control bar
            SimpleControlBar(
              onPause: widget.onPause,
              onPlay: widget.onPlay,
              onRefresh: widget.onRefresh,
              onExit: widget.onExit,
              isPaused: widget.isPaused,
            ),
          ],
        ),
      ),
    );
  }
}
