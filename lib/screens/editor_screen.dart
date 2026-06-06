import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:uuid/uuid.dart';

import '../models/pdf_models.dart';
import '../services/pdf_bridge.dart';
import '../services/session_store.dart';
import '../theme/app_theme.dart';

enum _LeaveAction { cancel, discard, save }

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.initialSession});

  final PdfDocumentSession initialSession;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _store = SessionStore();
  final _uuid = const Uuid();

  late PdfDocumentSession _session;
  Uint8List? _pageBytes;
  Size? _renderedPageSize;
  String? _renderError;
  var _pageIndex = 0;
  var _tool = EditorTool.selectText;
  var _loadingPage = true;
  var _exporting = false;
  var _extractingText = false;
  var _dirty = false;
  var _status = 'Loading PDF';
  var _textBlocks = <int, List<PdfTextBlock>>{};
  var _redoStack = <PdfAnnotation>[];

  List<PdfAnnotation> get _annotations => _session.annotations;

  @override
  void initState() {
    super.initState();
    _session = widget.initialSession;
    unawaited(_openDocument());
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _openDocument() async {
    setState(() {
      _loadingPage = true;
      _status = 'Opening PDF';
    });

    try {
      await _renderPage();
      await _loadTextBlocks(_pageIndex);
    } catch (error) {
      _showError('Could not open this PDF. $error');
      if (mounted) setState(() => _loadingPage = false);
    }
  }

  Future<void> _renderPage() async {
    setState(() {
      _loadingPage = true;
      _status = 'Rendering page ${_pageIndex + 1}';
      _renderError = null;
    });

    pdfx.PdfDocument? document;
    pdfx.PdfPage? page;
    try {
      document = await pdfx.PdfDocument.openFile(_session.sourcePath);
      page = await document.getPage(_pageIndex + 1);
      final pageSize = Size(page.width, page.height);
      final scale = _renderScaleFor(pageSize);
      final image = await page.render(
        width: pageSize.width * scale,
        height: pageSize.height * scale,
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#fffaf2',
        forPrint: true,
      );
      if (!mounted) return;
      setState(() {
        _pageBytes = image?.bytes;
        _renderedPageSize = pageSize;
        _loadingPage = false;
        _status = '';
      });
    } catch (error) {
      _showError('Could not render this page. $error');
      if (mounted) {
        setState(() {
          _pageBytes = null;
          _renderError = 'Could not render page ${_pageIndex + 1}.';
          _loadingPage = false;
          _status = '';
        });
      }
    } finally {
      if (page != null && !page.isClosed) {
        try {
          await page.close();
        } catch (_) {
          // The renderer may close the page on Android; closing is best-effort.
        }
      }
      if (document != null && !document.isClosed) {
        try {
          await document.close();
        } catch (_) {
          // Best-effort cleanup; rendering failures should not leave the UI stuck.
        }
      }
    }
  }

  double _renderScaleFor(Size pageSize) {
    const maxRenderedSide = 2200.0;
    final longestSide = math.max(pageSize.width, pageSize.height);
    if (longestSide <= 0) return 1.0;
    return (maxRenderedSide / longestSide).clamp(1.0, 2.0).toDouble();
  }

  Future<void> _loadTextBlocks(int pageIndex) async {
    if (_textBlocks.containsKey(pageIndex)) return;
    setState(() {
      _extractingText = true;
      _status = 'Finding editable text';
    });

    try {
      final blocks = await PdfBridge.extractTextBlocks(
        path: _session.sourcePath,
        pageIndex: pageIndex,
      );
      final styledBlocks = await _applyRenderedTextStyles(blocks);
      final visibleBlocks = _filterReplacedTextBlocks(pageIndex, styledBlocks);
      if (!mounted) return;
      setState(() {
        _textBlocks = {..._textBlocks, pageIndex: visibleBlocks};
        _extractingText = false;
        _status = '';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _textBlocks = {..._textBlocks, pageIndex: const []};
        _extractingText = false;
        _status = '';
      });
      _showError('No selectable text layer was found on this page.');
    }
  }

  Future<List<PdfTextBlock>> _applyRenderedTextStyles(
    List<PdfTextBlock> blocks,
  ) async {
    final bytes = _pageBytes;
    if (bytes == null || blocks.isEmpty) return blocks;

    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        image.dispose();
        return blocks;
      }

      final styled = blocks
          .map(
            (block) => block.copyWith(
              color:
                  _sampleRenderedTextColor(
                    data: data,
                    imageSize: Size(
                      image.width.toDouble(),
                      image.height.toDouble(),
                    ),
                    bounds: block.bounds,
                  ) ??
                  block.color,
            ),
          )
          .toList();
      image.dispose();
      return styled;
    } catch (_) {
      return blocks;
    }
  }

  Color? _sampleRenderedTextColor({
    required ByteData data,
    required Size imageSize,
    required Rect bounds,
  }) {
    if (imageSize.width <= 1 || imageSize.height <= 1) return null;

    final bg = _sampleRenderedBackground(
      data: data,
      imageSize: imageSize,
      bounds: bounds,
    );
    final rect = Rect.fromLTRB(
      (bounds.left * imageSize.width).floorToDouble(),
      (bounds.top * imageSize.height).floorToDouble(),
      (bounds.right * imageSize.width).ceilToDouble(),
      (bounds.bottom * imageSize.height).ceilToDouble(),
    ).inflate(2);

    final left = rect.left.clamp(0, imageSize.width - 1).toInt();
    final top = rect.top.clamp(0, imageSize.height - 1).toInt();
    final right = rect.right.clamp(left + 1, imageSize.width).toInt();
    final bottom = rect.bottom.clamp(top + 1, imageSize.height).toInt();

    var red = 0.0;
    var green = 0.0;
    var blue = 0.0;
    var weight = 0.0;

    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final color = _rawPixel(data, imageSize.width.toInt(), x, y);
        final distance = _colorDistance(color, bg);
        if (distance < 18) continue;

        final localWeight = math.min(distance, 180).toDouble();
        red += color.r * 255 * localWeight;
        green += color.g * 255 * localWeight;
        blue += color.b * 255 * localWeight;
        weight += localWeight;
      }
    }

    if (weight <= 0) return null;
    return Color.fromARGB(
      255,
      (red / weight).round().clamp(0, 255).toInt(),
      (green / weight).round().clamp(0, 255).toInt(),
      (blue / weight).round().clamp(0, 255).toInt(),
    );
  }

  Color _sampleRenderedBackground({
    required ByteData data,
    required Size imageSize,
    required Rect bounds,
  }) {
    final samples = _backgroundSamplePoints(bounds);
    var red = 0;
    var green = 0;
    var blue = 0;
    var count = 0;

    for (final point in samples) {
      final x = (point.dx * (imageSize.width - 1))
          .round()
          .clamp(0, imageSize.width.toInt() - 1)
          .toInt();
      final y = (point.dy * (imageSize.height - 1))
          .round()
          .clamp(0, imageSize.height.toInt() - 1)
          .toInt();
      final color = _rawPixel(data, imageSize.width.toInt(), x, y);
      red += (color.r * 255).round();
      green += (color.g * 255).round();
      blue += (color.b * 255).round();
      count++;
    }

    if (count == 0) return Colors.white;
    return Color.fromARGB(255, red ~/ count, green ~/ count, blue ~/ count);
  }

  Color _rawPixel(ByteData data, int width, int x, int y) {
    final offset = (y * width + x) * 4;
    return Color.fromARGB(
      255,
      data.getUint8(offset),
      data.getUint8(offset + 1),
      data.getUint8(offset + 2),
    );
  }

  double _colorDistance(Color a, Color b) {
    final dr = a.r * 255 - b.r * 255;
    final dg = a.g * 255 - b.g * 255;
    final db = a.b * 255 - b.b * 255;
    return math.sqrt(dr * dr + dg * dg + db * db);
  }

  Future<void> _goToPage(int pageIndex) async {
    if (pageIndex == _pageIndex ||
        pageIndex < 0 ||
        pageIndex >= _session.pageCount) {
      return;
    }

    setState(() => _pageIndex = pageIndex);
    await _renderPage();
    await _loadTextBlocks(pageIndex);
  }

  Future<void> _addAnnotation(PdfAnnotation annotation) async {
    setState(() {
      _redoStack = [];
      _session = _session.copyWith(
        annotations: [..._annotations, annotation],
        updatedAt: DateTime.now(),
      );
      _removeReplacedTextBlock(annotation);
      _dirty = true;
    });
  }

  void _removeReplacedTextBlock(PdfAnnotation annotation) {
    if (annotation.type != AnnotationType.textReplacement) return;
    final pageBlocks = _textBlocks[annotation.pageIndex];
    if (pageBlocks == null || pageBlocks.isEmpty) return;

    _textBlocks = {
      ..._textBlocks,
      annotation.pageIndex: _filterReplacedTextBlocks(
        annotation.pageIndex,
        pageBlocks,
      ),
    };
  }

  List<PdfTextBlock> _filterReplacedTextBlocks(
    int pageIndex,
    List<PdfTextBlock> blocks,
  ) {
    final replacements = _annotations.where(
      (annotation) =>
          annotation.pageIndex == pageIndex &&
          annotation.type == AnnotationType.textReplacement &&
          (annotation.originalText?.trim().isNotEmpty ?? false),
    );

    return blocks.where((block) {
      return !replacements.any((annotation) {
        final sameText = block.text.trim() == annotation.originalText!.trim();
        final overlap = _rectOverlapRatio(block.bounds, annotation.bounds);
        return overlap > 0.55 || (sameText && overlap > 0.25);
      });
    }).toList();
  }

  Future<void> _updateAnnotation(PdfAnnotation annotation) async {
    final index = _annotations.indexWhere((item) => item.id == annotation.id);
    if (index < 0) return;

    final next = [..._annotations];
    next[index] = annotation;
    setState(() {
      _session = _session.copyWith(
        annotations: next,
        updatedAt: DateTime.now(),
      );
      _dirty = true;
    });
  }

  Future<void> _undo() async {
    if (_annotations.isEmpty) return;
    final next = [..._annotations];
    final removed = next.removeLast();
    setState(() {
      _redoStack = [..._redoStack, removed];
      _session = _session.copyWith(
        annotations: next,
        updatedAt: DateTime.now(),
      );
      _dirty = true;
    });
    if (removed.type == AnnotationType.textReplacement) {
      await _reloadTextBlocks(removed.pageIndex);
    }
  }

  Future<void> _redo() async {
    if (_redoStack.isEmpty) return;
    final nextRedo = [..._redoStack];
    final restored = nextRedo.removeLast();
    setState(() {
      _redoStack = nextRedo;
      _session = _session.copyWith(
        annotations: [..._annotations, restored],
        updatedAt: DateTime.now(),
      );
      _removeReplacedTextBlock(restored);
      _dirty = true;
    });
  }

  Future<void> _reloadTextBlocks(int pageIndex) async {
    setState(() {
      final next = {..._textBlocks};
      next.remove(pageIndex);
      _textBlocks = next;
    });
    if (pageIndex == _pageIndex) {
      await _loadTextBlocks(pageIndex);
    }
  }

  Future<bool> _saveSession() async {
    try {
      final saved = _session.copyWith(updatedAt: DateTime.now());
      await _store.saveSession(saved);
      if (!mounted) return true;
      setState(() {
        _session = saved;
        _dirty = false;
      });
      _showMessage('Saved.');
      return true;
    } catch (error) {
      _showError('Save failed. $error');
      return false;
    }
  }

  Future<bool> _requireSavedForExport() async {
    if (!_dirty) return true;
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save before export?'),
        content: const Text('Your changes must be saved before exporting.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (shouldSave != true) return false;
    return _saveSession();
  }

  Future<bool> _confirmLeaveWithUnsavedChanges() async {
    if (!_dirty) return true;
    final action = await showDialog<_LeaveAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save changes?'),
        content: const Text('You have unsaved edits in this PDF.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_LeaveAction.cancel),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_LeaveAction.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_LeaveAction.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (action == _LeaveAction.save) return _saveSession();
    return action == _LeaveAction.discard;
  }

  Future<void> _exportPdf() async {
    if (_exporting) return;
    if (!await _requireSavedForExport()) return;
    setState(() {
      _exporting = true;
      _status = 'Exporting PDF';
    });

    try {
      final outputPath = await _store.nextExportPath(_session.name);
      final exportPath = await PdfBridge.exportPdf(
        sourcePath: _session.sourcePath,
        outputPath: outputPath,
        annotations: _annotations,
      );
      await PdfBridge.sharePdf(exportPath);
      _showMessage('Exported and ready to share.');
    } catch (error) {
      _showError('Export failed. $error');
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _status = '';
        });
      }
    }
  }

  Future<void> _openTextEditor({PdfTextBlock? block, Offset? position}) async {
    final backgroundColor = block == null
        ? null
        : await _sampleBackgroundColor(block.bounds);
    if (!mounted) return;
    final annotation = await showModalBottomSheet<PdfAnnotation>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _TextEditSheet(
        block: block,
        pageIndex: _pageIndex,
        pageSize: _session.pageSizes[_pageIndex],
        position: position,
        backgroundColor: backgroundColor,
        createId: _uuid.v4,
      ),
    );

    if (annotation != null) {
      await _addAnnotation(annotation);
    }
  }

  Future<void> _addImage() async {
    try {
      final picked = await PdfBridge.pickImage();
      if (picked == null) return;

      final id = _uuid.v4();
      final copy = await _store.copyImage(
        sourcePath: picked.path,
        id: id,
        originalName: picked.name,
      );
      final imageAspect = await _imageAspect(copy.path);
      final pageSize = _session.pageSizes[_pageIndex];
      final pageAspect = pageSize.width / pageSize.height;
      const width = 0.34;
      final height = (width * pageAspect / imageAspect).clamp(0.06, 0.34);

      await _addAnnotation(
        PdfAnnotation(
          id: id,
          pageIndex: _pageIndex,
          type: AnnotationType.image,
          bounds: Rect.fromLTWH(
            (1 - width) / 2,
            (1 - height) / 2,
            width,
            height,
          ),
          imagePath: copy.path,
        ),
      );
      setState(() => _tool = EditorTool.selectText);
    } catch (error) {
      _showError('Could not attach this image. $error');
    }
  }

  Future<double> _imageAspect(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final width = frame.image.width.toDouble();
    final height = frame.image.height.toDouble();
    frame.image.dispose();
    if (height <= 0) return 1;
    return width / height;
  }

  Future<Color> _sampleBackgroundColor(Rect normalizedBounds) async {
    final bytes = _pageBytes;
    if (bytes == null) return Colors.white;

    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        image.dispose();
        return Colors.white;
      }

      final samples = _backgroundSamplePoints(normalizedBounds);
      var red = 0;
      var green = 0;
      var blue = 0;
      var count = 0;

      for (final point in samples) {
        final x = (point.dx * (image.width - 1)).round().clamp(
          0,
          image.width - 1,
        );
        final y = (point.dy * (image.height - 1)).round().clamp(
          0,
          image.height - 1,
        );
        final offset = (y * image.width + x) * 4;
        final r = data.getUint8(offset);
        final g = data.getUint8(offset + 1);
        final b = data.getUint8(offset + 2);
        final luminance = 0.299 * r + 0.587 * g + 0.114 * b;
        if (luminance < 72 && samples.length > 4) continue;
        red += r;
        green += g;
        blue += b;
        count++;
      }

      image.dispose();
      if (count == 0) return Colors.white;
      return Color.fromARGB(255, red ~/ count, green ~/ count, blue ~/ count);
    } catch (_) {
      return Colors.white;
    }
  }

  List<Offset> _backgroundSamplePoints(Rect rect) {
    final padded = _clampRect(rect.inflate(0.012));
    final left = (padded.left - 0.01).clamp(0, 1).toDouble();
    final right = (padded.right + 0.01).clamp(0, 1).toDouble();
    final top = (padded.top - 0.01).clamp(0, 1).toDouble();
    final bottom = (padded.bottom + 0.01).clamp(0, 1).toDouble();
    final midX = padded.center.dx;
    final midY = padded.center.dy;
    return [
      Offset(left, top),
      Offset(midX, top),
      Offset(right, top),
      Offset(left, midY),
      Offset(right, midY),
      Offset(left, bottom),
      Offset(midX, bottom),
      Offset(right, bottom),
    ];
  }

  Future<void> _addInk(List<Offset> points, bool signature) async {
    if (points.length < 2) return;
    final bounds = _boundsForPoints(points).inflate(0.008);
    await _addAnnotation(
      PdfAnnotation(
        id: _uuid.v4(),
        pageIndex: _pageIndex,
        type: signature ? AnnotationType.signature : AnnotationType.ink,
        bounds: _clampRect(bounds),
        color: signature ? AppTheme.ink : const Color(0xFF6B4D35),
        strokeWidth: signature ? 2.8 : 2.2,
        points: points,
      ),
    );
  }

  Future<void> _addHighlight(Rect bounds) async {
    if (bounds.width < 0.012 || bounds.height < 0.008) return;
    await _addAnnotation(
      PdfAnnotation(
        id: _uuid.v4(),
        pageIndex: _pageIndex,
        type: AnnotationType.highlight,
        bounds: _clampRect(bounds),
        color: AppTheme.highlight,
        opacity: 0.55,
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final pageAnnotations = _annotations
        .where((annotation) => annotation.pageIndex == _pageIndex)
        .toList();
    final blocks = _textBlocks[_pageIndex] ?? const <PdfTextBlock>[];
    final canEditText = !_extractingText && blocks.isNotEmpty;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final canLeave = await _confirmLeaveWithUnsavedChanges();
        if (canLeave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _session.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                canEditText
                    ? '${blocks.length} editable text blocks'
                    : _extractingText
                    ? 'Finding text'
                    : 'Overlay tools available',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Save',
              onPressed: _dirty ? _saveSession : null,
              icon: const Icon(Icons.save_outlined),
            ),
            IconButton(
              tooltip: 'Undo',
              onPressed: _annotations.isEmpty ? null : _undo,
              icon: const Icon(Icons.undo_rounded),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: _redoStack.isEmpty ? null : _redo,
              icon: const Icon(Icons.redo_rounded),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton.icon(
                onPressed: _exporting ? null : _exportPdf,
                icon: _exporting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share_rounded),
                label: Text(_exporting ? 'Exporting' : 'Export'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _loadingPage
                          ? _LoadingCanvas(status: _status)
                          : _pageBytes == null
                          ? _RenderErrorCanvas(
                              message:
                                  _renderError ??
                                  'This page could not be rendered.',
                              onRetry: _renderPage,
                            )
                          : EditorCanvas(
                              pageBytes: _pageBytes!,
                              pageSize:
                                  _renderedPageSize ??
                                  Size(
                                    _session.pageSizes[_pageIndex].width,
                                    _session.pageSizes[_pageIndex].height,
                                  ),
                              annotations: pageAnnotations,
                              textBlocks: blocks,
                              tool: _tool,
                              onTextBlockTap: (block) =>
                                  _openTextEditor(block: block),
                              onPageTap: (position) =>
                                  _openTextEditor(position: position),
                              onTextAnnotationTap: _openTextAnnotationEditor,
                              onInkComplete: (points) =>
                                  _addInk(points, _tool == EditorTool.sign),
                              onHighlightComplete: _addHighlight,
                              onAnnotationChanged: _updateAnnotation,
                            ),
                    ),
                    if (_status.isNotEmpty && !_loadingPage)
                      Positioned(
                        left: 16,
                        right: 16,
                        top: 8,
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppTheme.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFE4D2C0),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Text(_status),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _EditorToolbar(
                selectedTool: _tool,
                pageIndex: _pageIndex,
                pageCount: _session.pageCount,
                onToolChanged: (tool) => setState(() => _tool = tool),
                onImagePressed: _addImage,
                onPreviousPage: _pageIndex == 0
                    ? null
                    : () => _goToPage(_pageIndex - 1),
                onNextPage: _pageIndex >= _session.pageCount - 1
                    ? null
                    : () => _goToPage(_pageIndex + 1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openTextAnnotationEditor(PdfAnnotation annotation) async {
    final updated = await showModalBottomSheet<PdfAnnotation>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _TextEditSheet(
        annotation: annotation,
        block: null,
        pageIndex: annotation.pageIndex,
        pageSize: _session.pageSizes[annotation.pageIndex],
        position: null,
        backgroundColor: annotation.backgroundColor,
        createId: _uuid.v4,
      ),
    );

    if (updated != null) {
      await _updateAnnotation(updated);
    }
  }
}

class EditorCanvas extends StatefulWidget {
  const EditorCanvas({
    super.key,
    required this.pageBytes,
    required this.pageSize,
    required this.annotations,
    required this.textBlocks,
    required this.tool,
    required this.onTextBlockTap,
    required this.onPageTap,
    required this.onTextAnnotationTap,
    required this.onInkComplete,
    required this.onHighlightComplete,
    required this.onAnnotationChanged,
  });

  final Uint8List pageBytes;
  final Size pageSize;
  final List<PdfAnnotation> annotations;
  final List<PdfTextBlock> textBlocks;
  final EditorTool tool;
  final ValueChanged<PdfTextBlock> onTextBlockTap;
  final ValueChanged<Offset> onPageTap;
  final ValueChanged<PdfAnnotation> onTextAnnotationTap;
  final ValueChanged<List<Offset>> onInkComplete;
  final ValueChanged<Rect> onHighlightComplete;
  final ValueChanged<PdfAnnotation> onAnnotationChanged;

  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends State<EditorCanvas> {
  var _draftPoints = <Offset>[];
  Offset? _dragStart;
  Rect? _draftHighlight;

  @override
  Widget build(BuildContext context) {
    final editingGesture =
        widget.tool == EditorTool.draw ||
        widget.tool == EditorTool.sign ||
        widget.tool == EditorTool.highlight;

    return Container(
      color: AppTheme.paper,
      child: InteractiveViewer(
        minScale: 0.75,
        maxScale: 5,
        panEnabled: !editingGesture,
        scaleEnabled: !editingGesture,
        boundaryMargin: const EdgeInsets.all(120),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: AspectRatio(
              aspectRatio: widget.pageSize.width / widget.pageSize.height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.biggest;
                  return GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown:
                        widget.tool == EditorTool.addText ||
                            widget.tool == EditorTool.selectText
                        ? (details) {
                            if (widget.tool == EditorTool.addText) {
                              widget.onPageTap(
                                _normalize(details.localPosition, size),
                              );
                            } else {
                              _selectTextAt(details.localPosition, size);
                            }
                          }
                        : null,
                    onPanStart: editingGesture
                        ? (details) => _startDrag(details.localPosition, size)
                        : null,
                    onPanUpdate: editingGesture
                        ? (details) => _updateDrag(details.localPosition, size)
                        : null,
                    onPanEnd: editingGesture ? (_) => _finishDrag() : null,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(3),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x1F3A2518),
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: Image.memory(
                              widget.pageBytes,
                              fit: BoxFit.fill,
                            ),
                          ),
                        ),
                        CustomPaint(
                          painter: _AnnotationPainter(
                            annotations: widget.annotations,
                            draftPoints: _draftPoints,
                            draftHighlight: _draftHighlight,
                            activeTool: widget.tool,
                            pageSize: widget.pageSize,
                          ),
                        ),
                        ...widget.annotations
                            .where(
                              (annotation) =>
                                  annotation.type == AnnotationType.image,
                            )
                            .map(
                              (annotation) => _ImageAnnotationTarget(
                                annotation: annotation,
                                size: size,
                                onChanged: widget.onAnnotationChanged,
                              ),
                            ),
                        if (widget.tool == EditorTool.selectText)
                          ...widget.textBlocks.map(
                            (block) => _TextBlockTarget(
                              block: block,
                              size: size,
                            ),
                          ),
                        if (widget.tool == EditorTool.selectText)
                          ...widget.annotations
                              .where(
                                (annotation) =>
                                    annotation.type ==
                                        AnnotationType.textOverlay ||
                                    annotation.type ==
                                        AnnotationType.textReplacement,
                              )
                              .map(
                                (annotation) => _TextAnnotationTarget(
                                  annotation: annotation,
                                  size: size,
                                  onTap: () =>
                                      widget.onTextAnnotationTap(annotation),
                                  onChanged: widget.onAnnotationChanged,
                                ),
                              ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _startDrag(Offset localPosition, Size size) {
    final normalized = _normalize(localPosition, size);
    if (widget.tool == EditorTool.draw || widget.tool == EditorTool.sign) {
      setState(() => _draftPoints = [normalized]);
    } else if (widget.tool == EditorTool.highlight) {
      setState(() {
        _dragStart = normalized;
        _draftHighlight = Rect.fromPoints(normalized, normalized);
      });
    }
  }

  void _updateDrag(Offset localPosition, Size size) {
    final normalized = _normalize(localPosition, size);
    if (widget.tool == EditorTool.draw || widget.tool == EditorTool.sign) {
      setState(() => _draftPoints = [..._draftPoints, normalized]);
    } else if (widget.tool == EditorTool.highlight && _dragStart != null) {
      setState(() {
        _draftHighlight = Rect.fromPoints(_dragStart!, normalized);
      });
    }
  }

  void _finishDrag() {
    if (widget.tool == EditorTool.draw || widget.tool == EditorTool.sign) {
      final points = _draftPoints;
      setState(() => _draftPoints = []);
      widget.onInkComplete(points);
    } else if (widget.tool == EditorTool.highlight) {
      final rect = _draftHighlight;
      setState(() {
        _dragStart = null;
        _draftHighlight = null;
      });
      if (rect != null) {
        widget.onHighlightComplete(_normalizeRect(rect));
      }
    }
  }

  void _selectTextAt(Offset localPosition, Size size) {
    final point = _normalize(localPosition, size);
    final horizontalPadding = 4 / size.width;
    final verticalPadding = 4 / size.height;

    Rect hitRect(Rect rect) => Rect.fromLTRB(
      rect.left - horizontalPadding,
      rect.top - verticalPadding,
      rect.right + horizontalPadding,
      rect.bottom + verticalPadding,
    );

    final annotations =
        widget.annotations
            .where(
              (annotation) =>
                  (annotation.type == AnnotationType.textOverlay ||
                      annotation.type == AnnotationType.textReplacement) &&
                  hitRect(annotation.bounds).contains(point),
            )
            .toList()
          ..sort(
            (a, b) => _rectArea(a.bounds).compareTo(_rectArea(b.bounds)),
          );
    if (annotations.isNotEmpty) {
      widget.onTextAnnotationTap(annotations.first);
      return;
    }

    final blocks =
        widget.textBlocks
            .where((block) => hitRect(block.bounds).contains(point))
            .toList()
          ..sort((a, b) => _rectArea(a.bounds).compareTo(_rectArea(b.bounds)));
    if (blocks.isNotEmpty) {
      widget.onTextBlockTap(blocks.first);
    }
  }

  Offset _normalize(Offset offset, Size size) {
    return Offset(
      (offset.dx / size.width).clamp(0, 1).toDouble(),
      (offset.dy / size.height).clamp(0, 1).toDouble(),
    );
  }
}

class _TextBlockTarget extends StatelessWidget {
  const _TextBlockTarget({
    required this.block,
    required this.size,
  });

  final PdfTextBlock block;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final rect = _scaleRect(block.bounds, size).inflate(0.75);
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.accent.withValues(alpha: 0.018),
            border: Border.all(
              color: AppTheme.accent.withValues(alpha: 0.42),
              width: 0.8,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _ImageAnnotationTarget extends StatelessWidget {
  const _ImageAnnotationTarget({
    required this.annotation,
    required this.size,
    required this.onChanged,
  });

  final PdfAnnotation annotation;
  final Size size;
  final ValueChanged<PdfAnnotation> onChanged;

  @override
  Widget build(BuildContext context) {
    final rect = _scaleRect(annotation.bounds, size);
    final imagePath = annotation.imagePath;
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        onPanUpdate: (details) => _move(details.delta),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.accent.withValues(alpha: 0.6)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (imagePath != null && File(imagePath).existsSync())
                Image.file(File(imagePath), fit: BoxFit.contain)
              else
                const Center(child: Icon(Icons.broken_image_outlined)),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) => _resize(details.delta),
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.surface.withValues(alpha: 0.92),
                      border: Border.all(color: AppTheme.accent),
                    ),
                    child: const Icon(Icons.open_in_full_rounded, size: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _move(Offset delta) {
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    final rect = annotation.bounds;
    final next = Rect.fromLTWH(
      (rect.left + dx).clamp(0, 1 - rect.width).toDouble(),
      (rect.top + dy).clamp(0, 1 - rect.height).toDouble(),
      rect.width,
      rect.height,
    );
    onChanged(annotation.copyWith(bounds: next));
  }

  void _resize(Offset delta) {
    final dx = delta.dx / size.width;
    final rect = annotation.bounds;
    final imageAspect = rect.width / math.max(rect.height, 0.001);
    final nextWidth = (rect.width + dx).clamp(0.05, 0.9).toDouble();
    final nextHeight = (nextWidth / imageAspect).clamp(0.04, 0.9).toDouble();
    final next = Rect.fromLTWH(
      rect.left.clamp(0, 1 - nextWidth).toDouble(),
      rect.top.clamp(0, 1 - nextHeight).toDouble(),
      nextWidth,
      nextHeight,
    );
    onChanged(annotation.copyWith(bounds: next));
  }
}

class _TextAnnotationTarget extends StatelessWidget {
  const _TextAnnotationTarget({
    required this.annotation,
    required this.size,
    required this.onTap,
    required this.onChanged,
  });

  final PdfAnnotation annotation;
  final Size size;
  final VoidCallback onTap;
  final ValueChanged<PdfAnnotation> onChanged;

  @override
  Widget build(BuildContext context) {
    final rect = _scaleRect(annotation.bounds, size).inflate(0.75);
    final movable = annotation.type == AnnotationType.textOverlay;
    final decoration = BoxDecoration(
      color: AppTheme.accent.withValues(alpha: 0.018),
      border: Border.all(
        color: AppTheme.accent.withValues(alpha: movable ? 0.56 : 0.42),
        width: movable ? 1 : 0.8,
      ),
      borderRadius: BorderRadius.circular(2),
    );
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: movable
          ? GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onTap,
              onPanUpdate: (details) => _move(details.delta),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(decoration: decoration),
                  ),
                  Positioned(
                    right: -8,
                    bottom: -8,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) => _resize(details.delta),
                      child: Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.surface.withValues(alpha: 0.94),
                          border: Border.all(color: AppTheme.accent),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.open_in_full_rounded, size: 12),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : IgnorePointer(child: DecoratedBox(decoration: decoration)),
    );
  }

  void _move(Offset delta) {
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    final rect = annotation.bounds;
    final next = Rect.fromLTWH(
      (rect.left + dx).clamp(0, 1 - rect.width).toDouble(),
      (rect.top + dy).clamp(0, 1 - rect.height).toDouble(),
      rect.width,
      rect.height,
    );
    onChanged(annotation.copyWith(bounds: next));
  }

  void _resize(Offset delta) {
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    final rect = annotation.bounds;
    final nextWidth = (rect.width + dx).clamp(0.025, 0.96).toDouble();
    final nextHeight = (rect.height + dy).clamp(0.012, 0.35).toDouble();
    final next = Rect.fromLTWH(
      rect.left.clamp(0, 1 - nextWidth).toDouble(),
      rect.top.clamp(0, 1 - nextHeight).toDouble(),
      nextWidth,
      nextHeight,
    );
    onChanged(annotation.copyWith(bounds: next));
  }
}

class _AnnotationPainter extends CustomPainter {
  const _AnnotationPainter({
    required this.annotations,
    required this.draftPoints,
    required this.draftHighlight,
    required this.activeTool,
    required this.pageSize,
  });

  final List<PdfAnnotation> annotations;
  final List<Offset> draftPoints;
  final Rect? draftHighlight;
  final EditorTool activeTool;
  final Size pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    for (final annotation in annotations) {
      switch (annotation.type) {
        case AnnotationType.highlight:
          _paintHighlight(
            canvas,
            size,
            annotation.bounds,
            annotation.color,
            annotation.opacity,
          );
        case AnnotationType.ink:
        case AnnotationType.signature:
          _paintInk(
            canvas,
            size,
            annotation.points,
            annotation.color,
            annotation.strokeWidth,
          );
        case AnnotationType.textOverlay:
          _paintText(canvas, size, annotation, false);
        case AnnotationType.textReplacement:
          _paintText(canvas, size, annotation, true);
        case AnnotationType.image:
          break;
      }
    }

    if (draftHighlight != null) {
      _paintHighlight(
        canvas,
        size,
        _normalizeRect(draftHighlight!),
        AppTheme.highlight,
        0.45,
      );
    }
    if (draftPoints.isNotEmpty) {
      _paintInk(
        canvas,
        size,
        draftPoints,
        activeTool == EditorTool.sign ? AppTheme.ink : const Color(0xFF6B4D35),
        activeTool == EditorTool.sign ? 2.8 : 2.2,
      );
    }
  }

  void _paintHighlight(
    Canvas canvas,
    Size size,
    Rect bounds,
    Color color,
    double opacity,
  ) {
    final paint = Paint()
      ..color = color.withValues(alpha: opacity.clamp(0, 1))
      ..style = PaintingStyle.fill;
    canvas.drawRect(_scaleRect(bounds, size), paint);
  }

  void _paintInk(
    Canvas canvas,
    Size size,
    List<Offset> points,
    Color color,
    double strokeWidth,
  ) {
    if (points.length < 2) return;
    final path = Path()
      ..moveTo(points.first.dx * size.width, points.first.dy * size.height);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx * size.width, point.dy * size.height);
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  void _paintText(
    Canvas canvas,
    Size size,
    PdfAnnotation annotation,
    bool whiteout,
  ) {
    final rect = _scaleRect(annotation.bounds, size);
    final text = annotation.text ?? '';
    if (whiteout) {
      final paint = Paint()..color = annotation.backgroundColor ?? Colors.white;
      canvas.drawRect(
        Rect.fromLTRB(rect.left - 0.6, rect.top, rect.right + 0.6, rect.bottom),
        paint,
      );
    }

    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: _googleFontStyle(
          annotation.fontFamily,
          color: annotation.color,
          fontSize: _previewFontSize(
            annotation.visualFontSize ?? annotation.fontSize,
            size,
          ),
          height: 1.08,
          fontWeight: _fontWeightFor(annotation.fontFamily),
        ),
      ),
      maxLines: text.contains('\n') ? 4 : 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width);

    painter.paint(
      canvas,
      Offset(
        rect.left,
        rect.top + math.max(0, (rect.height - painter.height) / 2),
      ),
    );
  }

  double _previewFontSize(double pdfPointSize, Size canvasSize) {
    if (pageSize.height <= 0 || canvasSize.height <= 0) {
      return pdfPointSize.clamp(1, 144).toDouble();
    }
    return (pdfPointSize / pageSize.height * canvasSize.height)
        .clamp(1, canvasSize.height)
        .toDouble();
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) {
    return oldDelegate.annotations != annotations ||
        oldDelegate.draftPoints != draftPoints ||
        oldDelegate.draftHighlight != draftHighlight ||
        oldDelegate.activeTool != activeTool ||
        oldDelegate.pageSize != pageSize;
  }
}

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.selectedTool,
    required this.pageIndex,
    required this.pageCount,
    required this.onToolChanged,
    required this.onImagePressed,
    required this.onPreviousPage,
    required this.onNextPage,
  });

  final EditorTool selectedTool;
  final int pageIndex;
  final int pageCount;
  final ValueChanged<EditorTool> onToolChanged;
  final VoidCallback onImagePressed;
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: Color(0xFFE4D2C0))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Previous page',
                onPressed: onPreviousPage,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              SizedBox(
                width: 72,
                child: Center(
                  child: Text(
                    '${pageIndex + 1}/$pageCount',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next page',
                onPressed: onNextPage,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              const VerticalDivider(width: 12, indent: 16, endIndent: 16),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      _ToolButton(
                        icon: Icons.text_fields_rounded,
                        tooltip: 'Select text',
                        selected: selectedTool == EditorTool.selectText,
                        onPressed: () => onToolChanged(EditorTool.selectText),
                      ),
                      _ToolButton(
                        icon: Icons.add_box_outlined,
                        tooltip: 'Add text',
                        selected: selectedTool == EditorTool.addText,
                        onPressed: () => onToolChanged(EditorTool.addText),
                      ),
                      _ToolButton(
                        icon: Icons.gesture_rounded,
                        tooltip: 'Sign',
                        selected: selectedTool == EditorTool.sign,
                        onPressed: () => onToolChanged(EditorTool.sign),
                      ),
                      _ToolButton(
                        icon: Icons.edit_rounded,
                        tooltip: 'Draw',
                        selected: selectedTool == EditorTool.draw,
                        onPressed: () => onToolChanged(EditorTool.draw),
                      ),
                      _ToolButton(
                        icon: Icons.border_color_rounded,
                        tooltip: 'Highlight',
                        selected: selectedTool == EditorTool.highlight,
                        onPressed: () => onToolChanged(EditorTool.highlight),
                      ),
                      _ToolButton(
                        icon: Icons.add_photo_alternate_outlined,
                        tooltip: 'Attach image',
                        selected: false,
                        onPressed: onImagePressed,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        tooltip: tooltip,
        isSelected: selected,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }
}

class _TextEditSheet extends StatefulWidget {
  const _TextEditSheet({
    this.annotation,
    required this.block,
    required this.pageIndex,
    required this.pageSize,
    required this.position,
    required this.backgroundColor,
    required this.createId,
  });

  final PdfAnnotation? annotation;
  final PdfTextBlock? block;
  final int pageIndex;
  final PdfPageSize pageSize;
  final Offset? position;
  final Color? backgroundColor;
  final String Function() createId;

  @override
  State<_TextEditSheet> createState() => _TextEditSheetState();
}

class _TextEditSheetState extends State<_TextEditSheet> {
  late final TextEditingController _controller;
  late final TextEditingController _sizeController;
  var _fontFamily = 'Roboto';
  var _color = AppTheme.ink;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.annotation?.text ?? widget.block?.text ?? '',
    );
    final fontSize =
        widget.annotation?.fontSize.clamp(1, 144).toDouble() ??
        widget.block?.fontSize.clamp(1, 144).toDouble() ??
        16;
    _sizeController = TextEditingController(
      text: fontSize.toStringAsFixed(
        fontSize.truncateToDouble() == fontSize ? 0 : 1,
      ),
    );
    _fontFamily =
        widget.annotation?.fontFamily ?? widget.block?.fontFamily ?? 'Roboto';
    _color = widget.annotation?.color ?? widget.block?.color ?? AppTheme.ink;
  }

  @override
  void dispose() {
    _controller.dispose();
    _sizeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, bottom + 18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.annotation == null && widget.block == null
                  ? 'Add text'
                  : 'Edit text',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(hintText: 'Text'),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 230,
                  child: OutlinedButton.icon(
                    onPressed: _pickFont,
                    icon: const Icon(Icons.font_download_outlined),
                    label: Text(
                      _fontFamily,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _googleFontStyle(_fontFamily),
                    ),
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _sizeController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Size'),
                  ),
                ),
                _ColorPickerButton(
                  selected: _color,
                  onSelected: (color) => setState(() => _color = color),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('Apply')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFont() async {
    final font = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _FontPickerSheet(selected: _fontFamily),
    );
    if (font != null) {
      setState(() => _fontFamily = font);
    }
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    final existing = widget.annotation;
    final block = widget.block;
    final position = widget.position ?? const Offset(0.12, 0.12);
    final fontSize =
        double.tryParse(
          _sizeController.text.trim(),
        )?.clamp(1, 144).toDouble() ??
        16;
    final visualFontSize = _visualFontSizeFor(fontSize, block, existing);
    final bounds = _textBoundsFor(
      text,
      visualFontSize ?? fontSize,
      block,
      position,
      existing?.bounds,
    );

    Navigator.of(context).pop(
      PdfAnnotation(
        id: existing?.id ?? widget.createId(),
        pageIndex: widget.pageIndex,
        type:
            existing?.type ??
            (block == null
                ? AnnotationType.textOverlay
                : AnnotationType.textReplacement),
        bounds: _clampRect(bounds),
        text: text,
        originalText: existing?.originalText ?? block?.text,
        fontFamily: _fontFamily,
        fontSize: fontSize,
        visualFontSize: visualFontSize,
        color: _color,
        backgroundColor: existing?.backgroundColor ?? widget.backgroundColor,
      ),
    );
  }

  Rect _textBoundsFor(
    String text,
    double layoutFontSize,
    PdfTextBlock? block,
    Offset position,
    Rect? existingBounds,
  ) {
    if (existingBounds != null) {
      return existingBounds;
    }

    if (block == null) {
      final estimatedWidth = _estimatedTextWidth(text, layoutFontSize);
      final estimatedHeight = (layoutFontSize * 1.18 / widget.pageSize.height)
          .clamp(0.025, 0.16);
      return Rect.fromLTWH(
        position.dx.clamp(0.02, 0.92 - estimatedWidth).toDouble(),
        position.dy.clamp(0.02, 0.95 - estimatedHeight).toDouble(),
        estimatedWidth,
        estimatedHeight,
      );
    }

    return block.bounds;
  }

  double _estimatedTextWidth(String text, double fontSize) {
    final longestLine = text
        .split('\n')
        .fold<int>(0, (longest, line) => math.max(longest, line.length));
    final width = (longestLine * fontSize * 0.62 + 10) / widget.pageSize.width;
    return width.clamp(0.08, 0.92).toDouble();
  }

  double? _visualFontSizeFor(
    double nextFontSize,
    PdfTextBlock? block,
    PdfAnnotation? existing,
  ) {
    if (existing != null &&
        _fontFamily == existing.fontFamily &&
        existing.visualFontSize != null &&
        existing.fontSize > 0) {
      return existing.visualFontSize! * nextFontSize / existing.fontSize;
    }

    if (block != null &&
        _fontFamily == block.fontFamily &&
        block.visualFontSize != null &&
        block.fontSize > 0) {
      return block.visualFontSize! * nextFontSize / block.fontSize;
    }

    return nextFontSize;
  }
}

class _FontPickerSheet extends StatefulWidget {
  const _FontPickerSheet({required this.selected});

  final String selected;

  @override
  State<_FontPickerSheet> createState() => _FontPickerSheetState();
}

class _FontPickerSheetState extends State<_FontPickerSheet> {
  late final TextEditingController _searchController;
  late final List<String> _fonts;
  var _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _fonts = GoogleFonts.asMap().keys.toList()..sort();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final filtered = _query.isEmpty
        ? _fonts.take(80).toList()
        : _fonts
              .where(
                (font) => font.toLowerCase().contains(_query.toLowerCase()),
              )
              .take(120)
              .toList();

    return Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, bottom + 18),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Font', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search Google Fonts',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final font = filtered[index];
                  return ListTile(
                    dense: true,
                    leading: widget.selected == font
                        ? const Icon(
                            Icons.check_rounded,
                            color: AppTheme.accent,
                          )
                        : const SizedBox(width: 24),
                    title: Text(
                      font,
                      style: _googleFontStyle(font, fontSize: 18),
                    ),
                    onTap: () => Navigator.of(context).pop(font),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorPickerButton extends StatelessWidget {
  const _ColorPickerButton({required this.selected, required this.onSelected});

  final Color selected;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        final color = await showModalBottomSheet<Color>(
          context: context,
          builder: (context) => _ColorPickerSheet(initial: selected),
        );
        if (color != null) onSelected(color);
      },
      icon: DecoratedBox(
        decoration: BoxDecoration(
          color: selected,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFD7C4B3)),
        ),
        child: const SizedBox(width: 20, height: 20),
      ),
      label: const Text('Color'),
    );
  }
}

class _ColorPickerSheet extends StatefulWidget {
  const _ColorPickerSheet({required this.initial});

  final Color initial;

  @override
  State<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends State<_ColorPickerSheet> {
  late int _red;
  late int _green;
  late int _blue;
  late final TextEditingController _redController;
  late final TextEditingController _greenController;
  late final TextEditingController _blueController;

  static const colors = [
    AppTheme.ink,
    Colors.black,
    Colors.white,
    AppTheme.accent,
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.purple,
    Color(0xFF7B5E33),
    Color(0xFF365B6D),
    Color(0xFF7A3F48),
  ];

  @override
  void initState() {
    super.initState();
    _red = (widget.initial.r * 255).round();
    _green = (widget.initial.g * 255).round();
    _blue = (widget.initial.b * 255).round();
    _redController = TextEditingController(text: _red.toString());
    _greenController = TextEditingController(text: _green.toString());
    _blueController = TextEditingController(text: _blue.toString());
  }

  @override
  void dispose() {
    _redController.dispose();
    _greenController.dispose();
    _blueController.dispose();
    super.dispose();
  }

  Color get _selected => Color.fromARGB(255, _red, _green, _blue);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Color', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: colors.map((color) {
              final active = color.toARGB32() == _selected.toARGB32();
              return InkWell(
                borderRadius: BorderRadius.circular(15),
                onTap: () => _setColor(color),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: active ? AppTheme.ink : const Color(0xFFD7C4B3),
                      width: active ? 2.4 : 1,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          Center(
            child: _ColorWheel(color: _selected, onChanged: _setColor),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _RgbInput(
                label: 'R',
                controller: _redController,
                onChanged: (value) => _setRgb(red: value),
              ),
              const SizedBox(width: 8),
              _RgbInput(
                label: 'G',
                controller: _greenController,
                onChanged: (value) => _setRgb(green: value),
              ),
              const SizedBox(width: 8),
              _RgbInput(
                label: 'B',
                controller: _blueController,
                onChanged: (value) => _setRgb(blue: value),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: _selected,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFD7C4B3)),
                ),
                child: const SizedBox(width: 46, height: 34),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_selected),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _setColor(Color color) {
    setState(() {
      _red = (color.r * 255).round();
      _green = (color.g * 255).round();
      _blue = (color.b * 255).round();
      _syncControllers();
    });
  }

  void _setRgb({int? red, int? green, int? blue}) {
    setState(() {
      _red = red ?? _red;
      _green = green ?? _green;
      _blue = blue ?? _blue;
    });
  }

  void _syncControllers() {
    _redController.text = _red.toString();
    _greenController.text = _green.toString();
    _blueController.text = _blue.toString();
  }
}

class _ColorWheel extends StatelessWidget {
  const _ColorWheel({required this.color, required this.onChanged});

  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanDown: (details) => _select(details.localPosition),
      onPanUpdate: (details) => _select(details.localPosition),
      child: CustomPaint(
        size: const Size.square(184),
        painter: _ColorWheelPainter(color),
      ),
    );
  }

  void _select(Offset position) {
    const size = 184.0;
    const radius = size / 2;
    const center = Offset(radius, radius);
    final delta = position - center;
    final distance = delta.distance;
    if (distance > radius) return;

    var hue = math.atan2(delta.dy, delta.dx) * 180 / math.pi;
    if (hue < 0) hue += 360;
    final saturation = (distance / radius).clamp(0.0, 1.0).toDouble();
    onChanged(HSVColor.fromAHSV(1, hue, saturation, 1).toColor());
  }
}

class _ColorWheelPainter extends CustomPainter {
  const _ColorWheelPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final huePaint = Paint()
      ..shader = const SweepGradient(
        colors: [
          Colors.red,
          Colors.yellow,
          Colors.green,
          Colors.cyan,
          Colors.blue,
          Colors.purple,
          Colors.red,
        ],
      ).createShader(rect);

    canvas.drawCircle(center, radius, huePaint);
    final saturationPaint = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white, Colors.white.withValues(alpha: 0)],
      ).createShader(rect);
    canvas.drawCircle(center, radius, saturationPaint);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFFD7C4B3),
    );

    final hsv = HSVColor.fromColor(color);
    final angle = hsv.hue * math.pi / 180;
    final marker = Offset(
      center.dx + math.cos(angle) * hsv.saturation * radius,
      center.dy + math.sin(angle) * hsv.saturation * radius,
    );
    canvas.drawCircle(
      marker,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    canvas.drawCircle(
      marker,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = AppTheme.ink,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _RgbInput extends StatelessWidget {
  const _RgbInput({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        onChanged: (value) {
          final parsed = int.tryParse(value);
          if (parsed == null) return;
          onChanged(parsed.clamp(0, 255).toInt());
        },
        onEditingComplete: () {
          final parsed = int.tryParse(controller.text)?.clamp(0, 255).toInt();
          if (parsed != null) {
            controller.text = parsed.toString();
            onChanged(parsed);
          }
          FocusManager.instance.primaryFocus?.unfocus();
        },
      ),
    );
  }
}

class _LoadingCanvas extends StatelessWidget {
  const _LoadingCanvas({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(status.isEmpty ? 'Loading' : status),
        ],
      ),
    );
  }
}

class _RenderErrorCanvas extends StatelessWidget {
  const _RenderErrorCanvas({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: AppTheme.accent,
                    size: 34,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Try again, or import a different PDF if this file is encrypted or damaged.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry'),
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

String _normalizeFontFamily(String? fontFamily) {
  if (fontFamily == null) return 'Roboto';

  final value = fontFamily.trim();
  if (value.isEmpty) return 'Roboto';

  final lower = value.toLowerCase();
  if (lower == 'mono' || lower.contains('courier') || lower.contains('mono')) {
    return 'Roboto Mono';
  }
  if (lower == 'serif' ||
      lower.contains('times') ||
      lower.contains('georgia') ||
      lower.contains('serif')) {
    return 'Noto Serif';
  }
  if (lower.contains('noto sans')) return 'Noto Sans';
  if (lower.contains('googlesans') || lower.contains('google sans')) {
    return 'Roboto';
  }
  if (lower == 'sans' ||
      lower.contains('arial') ||
      lower.contains('helvetica')) {
    return 'Roboto';
  }
  return value;
}

FontWeight? _fontWeightFor(String? fontFamily) {
  final lower = fontFamily?.toLowerCase() ?? '';
  if (lower.contains('black') || lower.contains('heavy')) {
    return FontWeight.w900;
  }
  if (lower.contains('bold')) return FontWeight.w700;
  if (lower.contains('medium')) return FontWeight.w500;
  if (lower.contains('light')) return FontWeight.w300;
  return null;
}

TextStyle _googleFontStyle(
  String fontFamily, {
  Color? color,
  double? fontSize,
  double? height,
  FontWeight? fontWeight,
}) {
  final normalized = _normalizeFontFamily(fontFamily);
  final base = TextStyle(
    color: color,
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
  );
  try {
    return GoogleFonts.getFont(normalized, textStyle: base);
  } catch (_) {
    return base.copyWith(fontFamily: normalized);
  }
}

Rect _scaleRect(Rect rect, Size size) {
  return Rect.fromLTWH(
    rect.left * size.width,
    rect.top * size.height,
    rect.width * size.width,
    rect.height * size.height,
  );
}

Rect _normalizeRect(Rect rect) {
  final left = math.min(rect.left, rect.right).clamp(0, 1).toDouble();
  final top = math.min(rect.top, rect.bottom).clamp(0, 1).toDouble();
  final right = math.max(rect.left, rect.right).clamp(0, 1).toDouble();
  final bottom = math.max(rect.top, rect.bottom).clamp(0, 1).toDouble();
  return Rect.fromLTRB(left, top, right, bottom);
}

Rect _boundsForPoints(List<Offset> points) {
  var left = points.first.dx;
  var right = points.first.dx;
  var top = points.first.dy;
  var bottom = points.first.dy;

  for (final point in points.skip(1)) {
    left = math.min(left, point.dx);
    right = math.max(right, point.dx);
    top = math.min(top, point.dy);
    bottom = math.max(bottom, point.dy);
  }

  return Rect.fromLTRB(left, top, right, bottom);
}

Rect _clampRect(Rect rect) {
  final normalized = _normalizeRect(rect);
  final width = normalized.width.clamp(0.004, 1).toDouble();
  final height = normalized.height.clamp(0.004, 1).toDouble();
  final left = normalized.left.clamp(0, 1 - width).toDouble();
  final top = normalized.top.clamp(0, 1 - height).toDouble();
  return Rect.fromLTWH(left, top, width, height);
}

double _rectOverlapRatio(Rect a, Rect b) {
  final left = math.max(a.left, b.left);
  final top = math.max(a.top, b.top);
  final right = math.min(a.right, b.right);
  final bottom = math.min(a.bottom, b.bottom);
  if (right <= left || bottom <= top) return 0;

  final overlapArea = (right - left) * (bottom - top);
  final smallerArea = math.min(a.width * a.height, b.width * b.height);
  if (smallerArea <= 0) return 0;
  return overlapArea / smallerArea;
}

double _rectArea(Rect rect) => rect.width * rect.height;
