import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/pdf_models.dart';
import '../services/pdf_bridge.dart';
import '../services/session_store.dart';
import '../theme/app_theme.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = SessionStore();
  final _uuid = const Uuid();

  var _loading = true;
  var _importing = false;
  var _sessions = <PdfDocumentSession>[];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() => _loading = true);
    final sessions = await _store.loadRecentSessions();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loading = false;
    });
  }

  Future<void> _importPdf() async {
    if (_importing) return;
    setState(() => _importing = true);

    try {
      final picked = await PdfBridge.pickPdf();
      if (picked == null) return;

      final id = _uuid.v4();
      final name = picked.name;
      final copy = await _store.copyImport(
        sourcePath: picked.path,
        id: id,
        originalName: name,
      );
      final info = await PdfBridge.openPdf(copy.path);
      final session = PdfDocumentSession(
        id: id,
        name: name,
        sourcePath: copy.path,
        pageCount: info.pageCount,
        pageSizes: info.pageSizes,
        updatedAt: DateTime.now(),
        annotations: const [],
      );

      await _store.saveSession(session);
      await _openEditor(session);
    } catch (error) {
      _showError('Could not import this PDF. $error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _openEditor(PdfDocumentSession session) async {
    if (!await File(session.sourcePath).exists()) {
      _showError('The saved PDF file is missing.');
      await _loadSessions();
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditorScreen(initialSession: session)),
    );
    await _loadSessions();
  }

  Future<void> _deleteSession(PdfDocumentSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete PDF?'),
        content: Text('Remove "${session.name}" from recent files.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _store.deleteSession(session);
    await _loadSessions();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 520;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Warm PDF'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _importing ? null : _importPdf,
              icon: _importing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file_rounded),
              label: Text(_importing ? 'Importing' : 'Import'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : 28,
                compact ? 8 : 18,
                compact ? 16 : 28,
                24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Edit, sign, and export PDFs',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Select real PDF text when available, keep quick edits local, and export a clean copy.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: AppTheme.mutedInk),
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _sessions.isEmpty
                        ? _EmptyHome(onImport: _importPdf)
                        : _RecentList(
                            sessions: _sessions,
                            onOpen: _openEditor,
                            onDelete: _deleteSession,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.picture_as_pdf_rounded,
                  color: AppTheme.accent,
                  size: 46,
                ),
                const SizedBox(height: 16),
                Text(
                  'No PDFs yet',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Import a document to select text, add a signature, draw, highlight, and export.',
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppTheme.mutedInk),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Import PDF'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentList extends StatelessWidget {
  const _RecentList({
    required this.sessions,
    required this.onOpen,
    required this.onDelete,
  });

  final List<PdfDocumentSession> sessions;
  final ValueChanged<PdfDocumentSession> onOpen;
  final ValueChanged<PdfDocumentSession> onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 760 ? 2 : 1;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final cardHeight = 128.0 + (textScale - 1).clamp(0.0, 1.5) * 48;
        return GridView.builder(
          itemCount: sessions.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            mainAxisExtent: cardHeight,
          ),
          itemBuilder: (context, index) {
            final session = sessions[index];
            return Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onOpen(session),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 64,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFE5D3C1)),
                        ),
                        child: const Icon(
                          Icons.picture_as_pdf_rounded,
                          color: AppTheme.accent,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              session.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${session.pageCount} page${session.pageCount == 1 ? '' : 's'} - ${session.annotations.length} edit${session.annotations.length == 1 ? '' : 's'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              p.basename(session.sourcePath),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 38,
                            child: IconButton(
                              tooltip: 'Edit',
                              onPressed: () => onOpen(session),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ),
                          SizedBox.square(
                            dimension: 38,
                            child: IconButton(
                              tooltip: 'Delete',
                              onPressed: () => onDelete(session),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
