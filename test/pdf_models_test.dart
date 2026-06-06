import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_first_app/models/pdf_models.dart';

void main() {
  test('PDF sessions preserve annotation data through JSON', () {
    final session = PdfDocumentSession(
      id: 'session-1',
      name: 'sample.pdf',
      sourcePath: '/tmp/sample.pdf',
      pageCount: 1,
      pageSizes: const [PdfPageSize(width: 612, height: 792)],
      updatedAt: DateTime.utc(2026, 6, 5),
      annotations: const [
        PdfAnnotation(
          id: 'edit-1',
          pageIndex: 0,
          type: AnnotationType.textReplacement,
          bounds: Rect.fromLTWH(0.1, 0.2, 0.3, 0.04),
          text: 'Updated text',
          originalText: 'Original text',
          fontFamily: 'Sans',
          fontSize: 14,
          visualFontSize: 10.5,
          color: Color(0xFF2D2620),
          backgroundColor: Color(0xFFE5F6EA),
        ),
        PdfAnnotation(
          id: 'image-1',
          pageIndex: 0,
          type: AnnotationType.image,
          bounds: Rect.fromLTWH(0.2, 0.3, 0.25, 0.12),
          imagePath: '/tmp/signature.png',
        ),
      ],
    );

    final restored = PdfDocumentSession.fromJson(
      jsonDecode(session.encode()) as Map<String, dynamic>,
    );

    expect(restored.id, session.id);
    expect(restored.pageSizes.single.width, 612);
    expect(restored.annotations.first.type, AnnotationType.textReplacement);
    expect(restored.annotations.first.text, 'Updated text');
    expect(restored.annotations.first.bounds.left, 0.1);
    expect(restored.annotations.first.visualFontSize, 10.5);
    expect(restored.annotations.first.backgroundColor, const Color(0xFFE5F6EA));
    expect(restored.annotations.last.type, AnnotationType.image);
    expect(restored.annotations.last.imagePath, '/tmp/signature.png');
  });
}
