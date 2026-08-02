import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../models/note.dart';
import '../services/notes_service.dart';
import '../widgets/simple_control_bar.dart';
import '../widgets/warning_dialog.dart';
import 'note_view_page.dart';
import 'note_edit_page.dart';

/// Notes page with list of user notes
class NotesPage extends StatefulWidget {
  final VoidCallback onNavigateToFace;
  final VoidCallback onPause;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final VoidCallback onExit;
  final String statusText;
  final bool isPaused;

  const NotesPage({
    super.key,
    required this.onNavigateToFace,
    required this.onPause,
    required this.onPlay,
    required this.onRefresh,
    required this.onExit,
    required this.statusText,
    this.isPaused = true,
  });

  @override
  State<NotesPage> createState() => NotesPageState();
}

class NotesPageState extends State<NotesPage> with AutomaticKeepAliveClientMixin {
  List<Note> _notes = [];
  bool _isLoading = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';

  @override
  bool get wantKeepAlive => true;

  void refreshNotes() {
    debugPrint('NotesPage: Refreshing notes list');
    _loadNotes();
  }

  /// Open a specific note by ID (called from AI voice command)
  Future<void> openNoteById(String noteId) async {
    debugPrint('NotesPage: Opening note by ID: $noteId');

    // First make sure notes are loaded
    if (_notes.isEmpty) {
      await _loadNotes();
    }

    // Find the note
    final note = _notes.firstWhere(
      (n) => n.id == noteId,
      orElse: () => Note(id: '', title: '', content: '', createdAt: DateTime.now(), updatedAt: DateTime.now()),
    );

    if (note.id.isNotEmpty) {
      _openNote(note);
    } else {
      // Note not in local list, try to fetch it directly
      final fetchedNote = await NotesService.getNote(noteId);
      if (fetchedNote != null) {
        _openNote(fetchedNote);
      } else {
        debugPrint('NotesPage: Note not found: $noteId');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadNotes();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
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

  List<Note> get _filteredNotes {
    if (_searchQuery.isEmpty) return _notes;
    return _notes.where((note) {
      final titleMatch = note.title.toLowerCase().contains(_searchQuery);
      final contentMatch = note.content.toLowerCase().contains(_searchQuery);
      return titleMatch || contentMatch;
    }).toList();
  }

  Future<void> _loadNotes() async {
    setState(() => _isLoading = true);

    try {
      final notes = await NotesService.getNotes();
      setState(() {
        _notes = notes;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading notes: $e');
      setState(() => _isLoading = false);
    }
  }

  void _openNote(Note note) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => NoteViewPage(
          note: note,
          onNoteUpdated: (updatedNote) {
            setState(() {
              final index = _notes.indexWhere((n) => n.id == updatedNote.id);
              if (index != -1) _notes[index] = updatedNote;
            });
          },
          onNoteDeleted: () {
            setState(() {
              _notes.removeWhere((n) => n.id == note.id);
            });
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

  void _deleteNote(Note note) async {
    final confirmed = await WarningDialog.show(
      context,
      title: 'Delete Note?',
      message: 'This will permanently delete "${note.title.isEmpty ? 'Untitled Note' : note.title}".',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      final success = await NotesService.deleteNote(note.id);
      if (success) {
        setState(() {
          _notes.removeWhere((n) => n.id == note.id);
        });
      }
    }
  }

  void _createNote() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => NoteEditPage(
          onNoteUpdated: (newNote) {
            setState(() => _notes.insert(0, newNote));
          },
          onNoteDeleted: () {},
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
    super.build(context);

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
                      'AI Notebook',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  // Create button (green)
                  GestureDetector(
                    onTap: _createNote,
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
                      decoration: BoxDecoration(
                        color: Colors.grey.shade700,
                        shape: BoxShape.circle,
                      ),
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
                          hintText: 'Search notes...',
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

            // Notes list
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
                    child: _isLoading
                        ? const Center(child: CircularProgressIndicator(color: Colors.white))
                        : _notes.isEmpty
                            ? _buildEmptyState()
                            : _filteredNotes.isEmpty && _searchQuery.isNotEmpty
                                ? _buildNoResultsState()
                                : ListView.builder(
                                    padding: const EdgeInsets.all(AppSpacing.md),
                                    itemCount: _filteredNotes.length,
                                    itemBuilder: (context, index) {
                                      final note = _filteredNotes[index];
                                      return _NoteCard(
                                        note: note,
                                        onOpen: () => _openNote(note),
                                        onDelete: () => _deleteNote(note),
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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.note_alt_outlined, size: 64, color: Colors.white.withOpacity(0.3)),
          const SizedBox(height: AppSpacing.md),
          Text('No notes yet', style: TextStyle(fontSize: 18, color: Colors.white.withOpacity(0.5))),
          const SizedBox(height: AppSpacing.sm),
          Text('Tap + to create your first note',
              style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.3))),
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
          Text('No matching notes', style: TextStyle(fontSize: 16, color: Colors.white.withOpacity(0.5))),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  const _NoteCard({
    required this.note,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
                  child: const Icon(Icons.note, color: Colors.white, size: 20),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    note.title.isEmpty ? 'Untitled Note' : note.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ElevatedButton(
                  onPressed: onOpen,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('Open', style: TextStyle(color: Colors.white)),
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
            if (note.content.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Container(height: 1, color: Colors.white.withOpacity(0.1)),
              const SizedBox(height: AppSpacing.md),
              Text(
                note.excerpt,
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
