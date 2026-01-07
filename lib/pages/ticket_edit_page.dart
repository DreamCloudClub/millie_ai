import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../models/ticket.dart';
import '../widgets/top_notification.dart';

/// Edit a ticket manually
/// Like "Note Edit Page" from millie_mini
class TicketEditPage extends StatefulWidget {
  final Ticket? ticket; // null for creating new ticket
  final Function(Ticket) onTicketUpdated;
  final VoidCallback onTicketDeleted;

  const TicketEditPage({
    super.key,
    this.ticket,
    required this.onTicketUpdated,
    required this.onTicketDeleted,
  });

  @override
  State<TicketEditPage> createState() => _TicketEditPageState();
}

class _TicketEditPageState extends State<TicketEditPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _titleController;
  late TextEditingController _itemsController;
  late TicketStatus _status;
  bool _isSaving = false;

  bool get isEditing => widget.ticket != null;

  /// Get page title based on mode and ticket number
  String _getPageTitle() {
    if (!isEditing) return 'New AI Ticket';
    final title = widget.ticket!.title;
    if (title.startsWith('Order #')) {
      final num = title.replaceFirst('Order #', '');
      return 'Edit AI Ticket #$num';
    }
    return 'Edit AI Ticket';
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.ticket?.title ?? '');
    _itemsController = TextEditingController(
      text: widget.ticket?.items.join('\n') ?? '',
    );
    _status = widget.ticket?.status ?? TicketStatus.open;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _itemsController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      // Parse items from text (one per line)
      final items = _itemsController.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      final savedTicket = Ticket(
        id: widget.ticket?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        title: _titleController.text.trim(),
        ticketNumber: widget.ticket?.ticketNumber ?? 0,
        items: items,
        status: _status,
        timestamp: widget.ticket?.timestamp ?? DateTime.now(),
        locationName: widget.ticket?.locationName,
        returnPose: widget.ticket?.returnPose,
      );

      setState(() => _isSaving = false);

      widget.onTicketUpdated(savedTicket);
      
      if (mounted) {
        TopNotification.show(
          context,
          message: isEditing ? 'Ticket saved' : 'Ticket created',
          backgroundColor: AppColors.success,
        );
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        TopNotification.show(
          context,
          message: 'Error saving ticket',
          backgroundColor: AppColors.danger,
        );
      }
    }
  }

  void _handleDelete() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Warning icon
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: AppColors.dangerBright.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: AppColors.dangerBright,
                  size: 32,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Title
              const Text(
                'Delete Ticket?',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              // Message
              Text(
                'This will permanently delete "${_titleController.text.isEmpty ? 'Untitled Ticket' : _titleController.text}". This cannot be undone.',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              // Buttons
              Row(
                children: [
                  // Cancel button
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: const Text(
                          'Cancel',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  // Delete button
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        widget.onTicketDeleted();
                        Navigator.pop(context);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: AppColors.dangerBright,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Delete',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(AppRadius.medium),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                // Top bar
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      // Back button
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
                      // Title
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
                
                // Form content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      // Title field
                      const Text(
                        'Title',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      TextFormField(
                        controller: _titleController,
                        style: const TextStyle(color: Colors.white, fontSize: 18),
                        textCapitalization: TextCapitalization.words,
                        decoration: InputDecoration(
                          hintText: 'Order #...',
                          hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.1),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.all(AppSpacing.md),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a title';
                          }
                          return null;
                        },
                      ),
                      
                      const SizedBox(height: AppSpacing.lg),
                      
                      // Status dropdown
                      const Text(
                        'Status',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<TicketStatus>(
                            value: _status,
                            isExpanded: true,
                            dropdownColor: AppColors.surface,
                            style: const TextStyle(color: Colors.white, fontSize: 16),
                            items: TicketStatus.values.map((status) {
                              return DropdownMenuItem(
                                value: status,
                                child: Text(status.displayName),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _status = value);
                              }
                            },
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: AppSpacing.lg),
                      
                      // Items field
                      const Text(
                        'Items (one per line)',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      TextFormField(
                        controller: _itemsController,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                        textCapitalization: TextCapitalization.sentences,
                        maxLines: 10,
                        decoration: InputDecoration(
                          hintText: 'Enter items...',
                          hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.1),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.all(AppSpacing.md),
                        ),
                      ),
                      
                      const SizedBox(height: AppSpacing.xl),
                      
                      // Save button
                      GestureDetector(
                        onTap: _isSaving ? null : _handleSave,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: AppColors.success,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: _isSaving
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation(Colors.white),
                                    ),
                                  )
                                : const Text(
                                    'Save',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: AppSpacing.md),
                      
                      // Delete button (only for existing tickets)
                      if (isEditing)
                        GestureDetector(
                          onTap: _handleDelete,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: AppColors.dangerBright.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: AppColors.dangerBright,
                                width: 1.5,
                              ),
                            ),
                            child: const Center(
                              child: Text(
                                'Delete',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.dangerBright,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      
                          const SizedBox(height: AppSpacing.xl),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

