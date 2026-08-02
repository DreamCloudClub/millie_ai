import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../models/note.dart';
import '../widgets/simple_control_bar.dart';
import 'note_edit_page.dart';

/// Full page for viewing a note (read-only)
class NoteViewPage extends StatefulWidget {
  final Note note;
  final Function(Note) onNoteUpdated;
  final VoidCallback onNoteDeleted;
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;
  final bool isPaused;
  final String statusText;

  const NoteViewPage({
    super.key,
    required this.note,
    required this.onNoteUpdated,
    required this.onNoteDeleted,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
    this.isPaused = true,
    this.statusText = 'Ready',
  });

  @override
  State<NoteViewPage> createState() => _NoteViewPageState();
}

class _NoteViewPageState extends State<NoteViewPage> {
  late Note _currentNote;

  @override
  void initState() {
    super.initState();
    _currentNote = widget.note;
  }

  void _openEditPage() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => NoteEditPage(
          note: _currentNote,
          onNoteUpdated: (updatedNote) {
            setState(() {
              _currentNote = updatedNote;
            });
            widget.onNoteUpdated(updatedNote);
          },
          onNoteDeleted: () {
            widget.onNoteDeleted();
            Navigator.pop(context);
          },
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
                      child: const Icon(Icons.arrow_back, color: Colors.white, size: 24),
                    ),
                  ),
                  // Title (centered)
                  const Expanded(
                    child: Text(
                      'AI Notepad',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  // Edit button (green)
                  GestureDetector(
                    onTap: _openEditPage,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.edit, color: Colors.white, size: 24),
                    ),
                  ),
                ],
              ),
            ),

            // Note content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.blue, width: 1),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title (centered)
                        Center(
                          child: Text(
                            _currentNote.title.isEmpty ? 'Untitled Note' : _currentNote.title,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        // Date (centered)
                        Center(
                          child: Text(
                            _formatDate(_currentNote.updatedAt),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withOpacity(0.5),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        // Divider
                        Container(height: 1, color: Colors.white.withOpacity(0.1)),
                        const SizedBox(height: AppSpacing.md),
                        // Content
                        Text(
                          _currentNote.content.isEmpty ? 'No content' : _currentNote.content,
                          style: TextStyle(
                            fontSize: 16,
                            color: _currentNote.content.isEmpty
                                ? Colors.white.withOpacity(0.3)
                                : Colors.white.withOpacity(0.9),
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.sm),

            // Status text
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
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
}
