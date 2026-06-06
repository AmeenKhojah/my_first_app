import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/pdf_models.dart';

class SessionStore {
  static const _indexFileName = 'sessions.json';

  Future<Directory> get _root async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'warm_pdf'));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<Directory> get importDirectory async {
    final root = await _root;
    final dir = Directory(p.join(root.path, 'imports'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> get exportDirectory async {
    final root = await _root;
    final dir = Directory(p.join(root.path, 'exports'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> get imageDirectory async {
    final root = await _root;
    final dir = Directory(p.join(root.path, 'images'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> get _sessionDirectory async {
    final root = await _root;
    final dir = Directory(p.join(root.path, 'sessions'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<List<PdfDocumentSession>> loadRecentSessions() async {
    final root = await _root;
    final indexFile = File(p.join(root.path, _indexFileName));
    if (!await indexFile.exists()) {
      return [];
    }

    final ids = (jsonDecode(await indexFile.readAsString()) as List<dynamic>)
        .whereType<String>()
        .toList();
    final sessions = <PdfDocumentSession>[];

    for (final id in ids) {
      final session = await loadSession(id);
      if (session != null && await File(session.sourcePath).exists()) {
        sessions.add(session);
      }
    }

    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions.take(12).toList();
  }

  Future<PdfDocumentSession?> loadSession(String id) async {
    final dir = await _sessionDirectory;
    final file = File(p.join(dir.path, '$id.json'));
    if (!await file.exists()) {
      return null;
    }

    return PdfDocumentSession.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }

  Future<void> saveSession(PdfDocumentSession session) async {
    final dir = await _sessionDirectory;
    final file = File(p.join(dir.path, '${session.id}.json'));
    await file.writeAsString(session.encode());
    await _saveIndex(session.id);
  }

  Future<void> deleteSession(PdfDocumentSession session) async {
    final dir = await _sessionDirectory;
    final file = File(p.join(dir.path, '${session.id}.json'));
    if (await file.exists()) {
      await file.delete();
    }

    final source = File(session.sourcePath);
    if (await source.exists()) {
      await source.delete();
    }

    final root = await _root;
    final indexFile = File(p.join(root.path, _indexFileName));
    if (await indexFile.exists()) {
      final ids = (jsonDecode(await indexFile.readAsString()) as List<dynamic>)
          .whereType<String>()
          .where((id) => id != session.id)
          .toList();
      await indexFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(ids),
      );
    }
  }

  Future<File> copyImport({
    required String sourcePath,
    required String id,
    required String originalName,
  }) async {
    final dir = await importDirectory;
    final cleanName = originalName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final target = File(p.join(dir.path, '$id-$cleanName'));
    return File(sourcePath).copy(target.path);
  }

  Future<File> copyImage({
    required String sourcePath,
    required String id,
    required String originalName,
  }) async {
    final dir = await imageDirectory;
    final cleanName = originalName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final target = File(p.join(dir.path, '$id-$cleanName'));
    return File(sourcePath).copy(target.path);
  }

  Future<String> nextExportPath(String documentName) async {
    final dir = await exportDirectory;
    final baseName = p
        .basenameWithoutExtension(documentName)
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return p.join(dir.path, '$baseName-edited-$stamp.pdf');
  }

  Future<void> _saveIndex(String id) async {
    final root = await _root;
    final indexFile = File(p.join(root.path, _indexFileName));
    final ids = <String>[];
    if (await indexFile.exists()) {
      ids.addAll(
        (jsonDecode(await indexFile.readAsString()) as List<dynamic>)
            .whereType<String>(),
      );
    }

    ids.remove(id);
    ids.insert(0, id);
    await indexFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(ids.take(12).toList()),
    );
  }
}
