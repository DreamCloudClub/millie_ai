import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../models/reminder.dart';
import '../services/reminder_service.dart';
import '../widgets/simple_control_bar.dart';
import '../widgets/warning_dialog.dart';
import 'alert_edit_page.dart';

/// Schedule filter toggle
enum ScheduleFilter { future, past }

/// Schedule/Alerts page with list of reminders
class SchedulePage extends StatefulWidget {
  final ReminderService reminderService;
  final VoidCallback onNavigateToFace;
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;
  final String statusText;
  final bool isPaused;

  const SchedulePage({
    super.key,
    required this.reminderService,
    required this.onNavigateToFace,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
    required this.statusText,
    this.isPaused = true,
  });

  @override
  State<SchedulePage> createState() => SchedulePageState();
}

class SchedulePageState extends State<SchedulePage> with AutomaticKeepAliveClientMixin {
  ReminderService get _reminderService => widget.reminderService;
  ScheduleFilter _filter = ScheduleFilter.future;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _reminderService.addListener(_onReminderServiceUpdate);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _reminderService.removeListener(_onReminderServiceUpdate);
    super.dispose();
  }

  void _onReminderServiceUpdate() {
    if (mounted) setState(() {});
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
  }

  List<Reminder> _filterReminders(List<Reminder> reminders) {
    if (_searchQuery.isEmpty) return reminders;
    return reminders.where((reminder) {
      final titleMatch = reminder.title.toLowerCase().contains(_searchQuery);
      final notesMatch = reminder.metadata?['notes']?.toString().toLowerCase().contains(_searchQuery) ?? false;
      return titleMatch || notesMatch;
    }).toList();
  }

  void refreshSchedule() {
    debugPrint('SchedulePage: Refreshing schedule list');
    _reminderService.loadReminders();
  }

  void _createAlert() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => AlertEditPage(
          reminderService: _reminderService,
          onSaved: () {},
          onDeleted: () {},
          onPause: widget.onPause,
          onPlay: widget.onPlay,
          onRefresh: widget.onRefresh,
          onExit: widget.onExit,
          isPaused: widget.isPaused,
          statusText: widget.statusText,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  void _editAlert(Reminder reminder) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => AlertEditPage(
          reminder: reminder,
          reminderService: _reminderService,
          onSaved: () {},
          onDeleted: () {},
          onPause: widget.onPause,
          onPlay: widget.onPlay,
          onRefresh: widget.onRefresh,
          onExit: widget.onExit,
          isPaused: widget.isPaused,
          statusText: widget.statusText,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  void _deleteAlert(Reminder reminder) async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Delete Alert?',
      message: 'This will permanently delete "${reminder.title}".',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      await _reminderService.deleteReminder(reminder.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final futureReminders = _reminderService.activeReminders;
    final pastReminders = _reminderService.getPastReminders();
    final baseReminders = _filter == ScheduleFilter.past ? pastReminders : futureReminders;
    final reminders = _filterReminders(baseReminders);

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
                    onTap: widget.onNavigateToFace,
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
                  const Expanded(
                    child: Text(
                      'AI Schedule',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                  GestureDetector(
                    onTap: _createAlert,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.add, color: Colors.white, size: 24),
                    ),
                  ),
                ],
              ),
            ),

            // Search bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _clearSearch,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: Colors.grey.shade700, shape: BoxShape.circle),
                      child: const Icon(Icons.close, color: Colors.white, size: 20),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search alerts...',
                          hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: const Icon(Icons.search, color: Colors.black, size: 24),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Filter toggle
            _buildFilterToggle(),
            const SizedBox(height: AppSpacing.sm),

            // Reminders list
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.15), width: 1),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(15),
                    child: _reminderService.isLoading
                        ? const Center(child: CircularProgressIndicator(color: Colors.white))
                        : baseReminders.isEmpty
                            ? _buildEmptyState()
                            : reminders.isEmpty && _searchQuery.isNotEmpty
                                ? _buildNoResultsState()
                                : ListView.builder(
                                    padding: const EdgeInsets.all(AppSpacing.md),
                                    itemCount: reminders.length,
                                    itemBuilder: (context, index) {
                                      final reminder = reminders[index];
                                      return _ScheduleCard(
                                        reminder: reminder,
                                        onTap: () => _editAlert(reminder),
                                        onDelete: () => _deleteAlert(reminder),
                                        showTriggeredTime: _filter == ScheduleFilter.past,
                                      );
                                    },
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
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
            ),

            // Bottom control bar
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

  Widget _buildFilterToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _filter = ScheduleFilter.past),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: _filter == ScheduleFilter.past ? Colors.blue : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      'Past',
                      style: TextStyle(
                        color: _filter == ScheduleFilter.past ? Colors.white : Colors.white.withOpacity(0.6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _filter = ScheduleFilter.future),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: _filter == ScheduleFilter.future ? Colors.blue : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      'Upcoming',
                      style: TextStyle(
                        color: _filter == ScheduleFilter.future ? Colors.white : Colors.white.withOpacity(0.6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final isPast = _filter == ScheduleFilter.past;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isPast ? Icons.history : Icons.notifications_outlined,
            size: 64,
            color: Colors.white.withOpacity(0.3),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            isPast ? 'No Past Alerts' : 'No Upcoming Alerts',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white.withOpacity(0.7)),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            isPast ? 'Past alerts will appear here' : 'Tap + to create an alert',
            style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildNoResultsState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: Colors.white.withOpacity(0.3)),
          const SizedBox(height: AppSpacing.md),
          Text('No matching alerts', style: TextStyle(fontSize: 16, color: Colors.white.withOpacity(0.5))),
        ],
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  final Reminder reminder;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final bool showTriggeredTime;

  const _ScheduleCard({
    required this.reminder,
    required this.onTap,
    required this.onDelete,
    this.showTriggeredTime = false,
  });

  String _formatTime(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final targetDate = DateTime(dt.year, dt.month, dt.day);

    if (targetDate == today) return 'Today';
    if (targetDate == tomorrow) return 'Tomorrow';
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[dt.month - 1]} ${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    final displayTime = showTriggeredTime && reminder.lastTriggeredAt != null
        ? reminder.lastTriggeredAt!
        : reminder.scheduledAt;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.notifications_active, color: Colors.white, size: 20),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    reminder.title.isEmpty ? 'Untitled Alert' : reminder.title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ElevatedButton(
                  onPressed: onTap,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('Edit', style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: AppSpacing.sm),
                GestureDetector(
                  onTap: onDelete,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.dangerBright.withOpacity(0.7),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.delete, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Container(height: 1, color: Colors.white.withOpacity(0.1)),
            const SizedBox(height: AppSpacing.md),
            Text(
              '${_formatDate(displayTime)} at ${_formatTime(displayTime)}',
              style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.5)),
            ),
            if (reminder.recurrence != ReminderRecurrence.none) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Repeats ${reminder.recurrence.displayName.toLowerCase()}',
                style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.7)),
              ),
            ],
            if (reminder.metadata?['notes'] != null &&
                (reminder.metadata!['notes'] as String).isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Notes: ${reminder.metadata!['notes']}',
                style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.7)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
