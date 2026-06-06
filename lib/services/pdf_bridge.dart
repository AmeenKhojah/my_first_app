import 'package:flutter/services.dart';

import '../models/pdf_models.dart';

class PdfBridge {
  static const MethodChannel _channel = MethodChannel('warm_pdf_editor/pdf');

  static Future<PdfOpenResult> openPdf(String path) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('openPdf', {
      'path': path,
    });
    if (result == null) {
      throw const FormatException('The PDF bridge returned no document data.');
    }

    return PdfOpenResult.fromJson(result);
  }

  static Future<PickedPdf?> pickPdf() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('pickPdf');
    if (result == null) return null;
    return PickedPdf.fromJson(result);
  }

  static Future<PickedFile?> pickImage() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('pickImage');
    if (result == null) return null;
    return PickedFile.fromJson(result);
  }

  static Future<List<PdfTextBlock>> extractTextBlocks({
    required String path,
    required int pageIndex,
  }) async {
    final result = await _channel.invokeListMethod<dynamic>(
      'extractTextBlocks',
      {'path': path, 'pageIndex': pageIndex},
    );

    return (result ?? [])
        .map((item) => PdfTextBlock.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  static Future<String> exportPdf({
    required String sourcePath,
    required String outputPath,
    required List<PdfAnnotation> annotations,
  }) async {
    final result = await _channel.invokeMethod<String>('exportPdf', {
      'sourcePath': sourcePath,
      'outputPath': outputPath,
      'annotations': annotations.map((item) => item.toJson()).toList(),
    });

    if (result == null || result.isEmpty) {
      throw const FormatException(
        'The PDF bridge did not return an export path.',
      );
    }

    return result;
  }

  static Future<void> sharePdf(String path) async {
    await _channel.invokeMethod<void>('sharePdf', {'path': path});
  }
}

class PickedFile {
  const PickedFile({required this.path, required this.name});

  final String path;
  final String name;

  factory PickedFile.fromJson(Map<String, dynamic> json) {
    return PickedFile(
      path: json['path'] as String,
      name: json['name'] as String,
    );
  }
}

typedef PickedPdf = PickedFile;

class PdfOpenResult {
  const PdfOpenResult({required this.pageCount, required this.pageSizes});

  final int pageCount;
  final List<PdfPageSize> pageSizes;

  factory PdfOpenResult.fromJson(Map<String, dynamic> json) {
    return PdfOpenResult(
      pageCount: json['pageCount'] as int,
      pageSizes: (json['pageSizes'] as List<dynamic>)
          .map((page) => PdfPageSize.fromJson(Map<String, dynamic>.from(page)))
          .toList(),
    );
  }
}
