import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../utils/rosbridge.dart';
import '../models/ticket.dart';
import '../services/location_service.dart';
import 'ticket_edit_page.dart';

/// View a single ticket (read-only display)
/// Like "AI Notepad" from millie_mini
class TicketViewPage extends StatefulWidget {
  final RosBridge rosBridge;
  final Ticket ticket;
  final Function(Ticket) onTicketUpdated;
  final VoidCallback onTicketDeleted;
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;

  const TicketViewPage({
    super.key,
    required this.rosBridge,
    required this.ticket,
    required this.onTicketUpdated,
    required this.onTicketDeleted,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
  });

  @override
  State<TicketViewPage> createState() => _TicketViewPageState();
}

class _TicketViewPageState extends State<TicketViewPage> {
  late Ticket _currentTicket;
  List<Waypoint> _waypoints = [];
  List<SavedSequence> _sequences = [];
  String? _lastDeliveryTask;
  
  // Multi-listener references
  late final void Function(List<Waypoint>) _waypointListener;
  late final void Function(List<SavedSequence>) _sequenceListener;

  @override
  void initState() {
    super.initState();
    _currentTicket = widget.ticket;
    _setupListeners();
  }
  
  void _setupListeners() {
    _waypointListener = (waypoints) {
      if (mounted) setState(() => _waypoints = waypoints);
    };
    _sequenceListener = (sequences) {
      if (mounted) setState(() => _sequences = sequences);
    };
    
    widget.rosBridge.addWaypointListener(_waypointListener);
    widget.rosBridge.addSequenceListener(_sequenceListener);
    
    widget.rosBridge.requestWaypoints();
    widget.rosBridge.requestSequences();
  }
  
  @override
  void dispose() {
    widget.rosBridge.removeWaypointListener(_waypointListener);
    widget.rosBridge.removeSequenceListener(_sequenceListener);
    super.dispose();
  }

  /// Extract ticket number from title for page header
  String _getPageTitle() {
    final title = _currentTicket.title;
    // If title is "Ticket #X", show "AI Ticket #X"
    if (title.startsWith('Ticket #')) {
      final num = title.replaceFirst('Ticket #', '');
      return 'AI Ticket #$num';
    }
    // Otherwise just show "AI Ticket"
    return 'AI Ticket';
  }

  void _openEditPage() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => TicketEditPage(
          ticket: _currentTicket,
          onTicketUpdated: (updatedTicket) {
            setState(() {
              _currentTicket = updatedTicket;
            });
            widget.onTicketUpdated(updatedTicket);
          },
          onTicketDeleted: () {
            widget.onTicketDeleted();
            Navigator.pop(context);
          },
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar - just back button and page title
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  // Back button (orange)
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.dangerBright,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                  // Title (centered)
                  Expanded(
                    child: Text(
                      _getPageTitle(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  // Spacer to balance back button
                  const SizedBox(width: 44),
                ],
              ),
            ),
            
            // Ticket content in blue border container (card style)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _isOpen ? AppColors.accent : AppColors.dangerBright,
                      width: 1,
                    ),
                  ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      // Header row with icon, title, and action buttons
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Row(
                          children: [
                            // Ticket icon
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: AppColors.accent.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.receipt_long,
                                color: AppColors.accent,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            // Title (location name)
                            Expanded(
                          child: Text(
                                _currentTicket.locationName ?? _currentTicket.title,
                            style: const TextStyle(
                                  fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            // Action buttons
                            _buildActionButton(
                              label: 'Edit',
                              color: AppColors.accent,
                              onTap: _openEditPage,
                        ),
                            const SizedBox(width: AppSpacing.xs),
                            // Close/Open button - Close (orange) for open, Open (green) for closed
                            _buildActionButton(
                              label: _isOpen ? 'Close' : 'Open',
                              color: _isOpen ? AppColors.dangerBright : AppColors.success,
                              onTap: _isOpen ? _closeTicket : _reopenTicket,
                            ),
                            // Deliver button (green) - only for open tickets
                            if (_isOpen) ...[
                              const SizedBox(width: AppSpacing.xs),
                              _buildActionButton(
                                label: 'Deliver',
                                color: AppColors.success,
                                onTap: _showDeliverModal,
                                solid: true,
                              ),
                            ],
                            const SizedBox(width: AppSpacing.xs),
                            // Delete button (orange square)
                            GestureDetector(
                              onTap: _deleteTicket,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: AppColors.dangerBright,
                                  borderRadius: BorderRadius.circular(AppRadius.small),
                                ),
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.delete,
                                  color: Colors.white,
                                  size: 22,
                            ),
                          ),
                        ),
                          ],
                        ),
                      ),
                        
                        // Divider line
                        Container(
                          height: 1,
                          color: Colors.white.withOpacity(0.1),
                        ),
                        
                      // Ticket number + timestamp row
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Row(
                          children: [
                            Text(
                              'Ticket #${_currentTicket.ticketNumber}',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withOpacity(0.7),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.lg),
                            Text(
                              _formatDate(_currentTicket.timestamp),
                            style: TextStyle(
                              fontSize: 14,
                                color: Colors.white.withOpacity(0.5),
                              ),
                            ),
                          ],
                            ),
                          ),
                      
                      // Items list (scrollable)
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_currentTicket.items.isNotEmpty)
                          ..._currentTicket.items.map((item) => Padding(
                                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                      Text(
                                  '• ',
                                  style: TextStyle(
                                          fontSize: 20,
                                          color: Colors.white.withOpacity(0.7),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    item,
                                          style: const TextStyle(
                                            fontSize: 20,
                                            color: Colors.white,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                                ))
                              else
                          Text(
                            'No items',
                            style: TextStyle(
                                    fontSize: 18,
                              color: Colors.white.withOpacity(0.3),
                            ),
                          ),
                              const SizedBox(height: AppSpacing.md),
                      ],
                    ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            
            const SizedBox(height: AppSpacing.sm),
            
            // Bottom control bar (inline - ControlBar is for overlay use)
            Container(
              margin: const EdgeInsets.only(
                left: AppSpacing.lg,
                right: AppSpacing.lg,
                bottom: AppSpacing.lg,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
              ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildControlButton(
                    icon: Icons.refresh,
                    label: 'Refresh',
                    onTap: widget.onRefresh,
                    color: AppColors.success,
                  ),
                  _buildControlButton(
                    icon: Icons.pause,
                    label: 'Pause',
                    onTap: widget.onPause,
                    color: AppColors.accent,
                  ),
                  _buildControlButton(
                    icon: Icons.close,
                    label: 'Exit',
                    onTap: () {
                      Navigator.pop(context);  // Pop this view first
                      widget.onExit();  // Then exit to dashboard
                    },
                    color: AppColors.dangerBright,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(TicketStatus status) {
    switch (status) {
      case TicketStatus.open:
        return AppColors.accent;
      case TicketStatus.inProgress:
        return AppColors.warning;
      case TicketStatus.complete:
        return AppColors.success;
      case TicketStatus.cancelled:
        return AppColors.textMuted;
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return 'Today at ${_formatTime(date)}';
    } else if (difference.inDays == 1) {
      return 'Yesterday at ${_formatTime(date)}';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${date.month}/${date.day}/${date.year}';
    }
  }

  String _formatTime(DateTime date) {
    final hour = date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour);
    final period = date.hour >= 12 ? 'PM' : 'AM';
    return '$hour:${date.minute.toString().padLeft(2, '0')} $period';
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool solid = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: EdgeInsets.symmetric(
          horizontal: solid ? AppSpacing.xl : AppSpacing.lg,
        ),
        decoration: BoxDecoration(
          color: solid ? color : color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(AppRadius.small),
          border: solid ? null : Border.all(color: color, width: 1.5),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: solid ? Colors.white : color,
          ),
        ),
      ),
    );
  }

  bool get _isOpen => 
      _currentTicket.status == TicketStatus.open || 
      _currentTicket.status == TicketStatus.inProgress;

  void _closeTicket() {
    setState(() {
      _currentTicket = _currentTicket.copyWith(status: TicketStatus.complete);
    });
    widget.onTicketUpdated(_currentTicket);
    Navigator.pop(context);  // Return to tickets list
  }

  void _reopenTicket() {
    setState(() {
      _currentTicket = _currentTicket.copyWith(status: TicketStatus.open);
    });
    widget.onTicketUpdated(_currentTicket);
  }

  void _deleteTicket() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
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
                child: const Icon(
                  Icons.delete_forever,
                  color: AppColors.dangerBright,
                  size: 32,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Delete Ticket?',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'This action cannot be undone.',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
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
                      onPressed: () {
                        Navigator.pop(context);  // Close dialog
                        widget.onTicketDeleted();
                        Navigator.pop(context);  // Go back to list
                      },
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
    );
  }

  void _showDeliverModal() {
    // Default to ticket's creation location, but validate it exists in waypoints
    String? selectedLocation = _currentTicket.locationName;
    final waypointNames = _waypoints.map((w) => w.name).toSet();
    if (selectedLocation != null && !waypointNames.contains(selectedLocation)) {
      selectedLocation = null;  // Invalid, reset
    }
    if (selectedLocation == null && _waypoints.isNotEmpty) {
      selectedLocation = _waypoints.first.name;
    }
    
    // Use last delivery task, but validate it exists in sequences
    String? selectedTask = _lastDeliveryTask;
    final sequenceNames = _sequences.map((s) => s.name).toSet();
    if (selectedTask != null && !sequenceNames.contains(selectedTask)) {
      selectedTask = null;  // Invalid, reset
    }
    if (selectedTask == null && _sequences.isNotEmpty) {
      // Look for a task with "Deliver" in the name (case-insensitive)
      final deliveryTask = _sequences.where(
        (s) => s.name.toLowerCase().contains('deliver'),
      ).firstOrNull;
      selectedTask = deliveryTask?.name ?? _sequences.first.name;
    }
    
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Delivery icon
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: AppColors.success.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.local_shipping,
                    color: AppColors.success,
                    size: 32,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(
                  'Deliver Ticket',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Items: ${_currentTicket.items.join(", ")}',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withOpacity(0.6),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.lg),
                
                // Location dropdown
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.15)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.location_on, color: AppColors.accent, size: 20),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: selectedLocation,
                            isExpanded: true,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            icon: Icon(Icons.arrow_drop_down, color: Colors.white.withOpacity(0.5)),
                            hint: Text(
                              'Select Location',
                              style: TextStyle(color: Colors.white.withOpacity(0.5)),
                            ),
                            items: _waypoints.map((wp) => DropdownMenuItem(
                              value: wp.name,
                              child: Text(wp.name),
                            )).toList(),
                            onChanged: (value) {
                              setDialogState(() => selectedLocation = value);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                
                // Task dropdown  
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.15)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.assignment, color: AppColors.success, size: 20),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: selectedTask,
                            isExpanded: true,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            icon: Icon(Icons.arrow_drop_down, color: Colors.white.withOpacity(0.5)),
                            hint: Text(
                              'Select Task',
                              style: TextStyle(color: Colors.white.withOpacity(0.5)),
                            ),
                            items: _sequences.map((seq) => DropdownMenuItem(
                              value: seq.name,
                              child: Text(seq.name),
                            )).toList(),
                            onChanged: (value) {
                              setDialogState(() => selectedTask = value);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.white.withOpacity(0.3)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: (selectedLocation != null)
                            ? () {
                                Navigator.pop(context);
                                // Save selected task
                                if (selectedTask != null) {
                                  _lastDeliveryTask = selectedTask;
                                }
                                // Execute delivery
                                _executeDelivery(
                                  locationName: selectedLocation!,
                                  taskName: selectedTask,
                                );
                              }
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.success,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: AppColors.success.withOpacity(0.3),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Deliver', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  void _executeDelivery({
    required String locationName,
    String? taskName,
  }) {
    // Close the ticket
    _closeTicket();
    
    // Build workflow steps
    // Robot handles showing face and 3-second delay before navigation
    final List<Map<String, String>> steps = [];
    
    // Step 1: Navigate to delivery location (where order was taken)
    steps.add({'type': 'navigate', 'value': locationName});
    
    // Step 2: Run the selected Task (which includes action + navigation steps)
    if (taskName != null) {
      final sequence = _sequences.where((s) => s.name == taskName).firstOrNull;
      if (sequence != null) {
        // Get sets of known names for type detection
        final waypointNames = _waypoints.map((w) => w.name).toSet();
        debugPrint('🔍 Building workflow - waypoints: $waypointNames');
        debugPrint('🔍 Task steps: ${sequence.waypointNames}');
        
        // Process each step in the task, detecting its type
        for (final stepName in sequence.waypointNames) {
          if (waypointNames.contains(stepName)) {
            // It's a waypoint - navigate
            debugPrint('🔍 Step "$stepName" -> navigate');
            steps.add({'type': 'navigate', 'value': stepName});
          } else {
            // Assume it's an action (AI conversation)
            debugPrint('🔍 Step "$stepName" -> action');
            steps.add({'type': 'action', 'value': stepName});
          }
        }
      } else {
        debugPrint('⚠️ Task "$taskName" not found in sequences!');
      }
    }
    
    debugPrint('📋 Final workflow steps: $steps');
    
    // Publish workflow with ticket context (for template variables like {ticket.items})
    widget.rosBridge.publishWorkflow(steps, ticket: _currentTicket);
    
    // Track navigation target for location service
    LocationService.instance.setNavigatingTo(locationName);
    
    // Pop ALL routes back to the root so workflow can take over on face page
    // The robot will send "Show Face" which home_page will handle
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

