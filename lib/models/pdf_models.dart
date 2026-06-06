import 'dart:convert';
import 'dart:ui';

enum AnnotationType {
  textReplacement,
  textOverlay,
  image,
  ink,
  signature,
  highlight,
}

enum EditorTool { selectText, addText, draw, sign, highlight, image }

class PdfPageSize {
  const PdfPageSize({required this.width, required this.height});

  final double width;
  final double height;

  factory PdfPageSize.fromJson(Map<String, dynamic> json) {
    return PdfPageSize(
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {'width': width, 'height': height};
}

class PdfTextBlock {
  const PdfTextBlock({
    required this.id,
    required this.pageIndex,
    required this.text,
    required this.bounds,
    required this.fontSize,
    required this.fontFamily,
    required this.editable,
    this.visualFontSize,
    this.color = const Color(0xFF000000),
  });

  final String id;
  final int pageIndex;
  final String text;
  final Rect bounds;
  final double fontSize;
  final String fontFamily;
  final bool editable;
  final double? visualFontSize;
  final Color color;

  PdfTextBlock copyWith({
    String? id,
    int? pageIndex,
    String? text,
    Rect? bounds,
    double? fontSize,
    String? fontFamily,
    bool? editable,
    double? visualFontSize,
    Color? color,
  }) {
    return PdfTextBlock(
      id: id ?? this.id,
      pageIndex: pageIndex ?? this.pageIndex,
      text: text ?? this.text,
      bounds: bounds ?? this.bounds,
      fontSize: fontSize ?? this.fontSize,
      fontFamily: fontFamily ?? this.fontFamily,
      editable: editable ?? this.editable,
      visualFontSize: visualFontSize ?? this.visualFontSize,
      color: color ?? this.color,
    );
  }

  factory PdfTextBlock.fromJson(Map<String, dynamic> json) {
    return PdfTextBlock(
      id: json['id'] as String,
      pageIndex: json['pageIndex'] as int,
      text: json['text'] as String,
      bounds: _rectFromJson(json['bounds'] as Map<Object?, Object?>),
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14,
      fontFamily: json['fontFamily'] as String? ?? 'Sans',
      editable: json['editable'] as bool? ?? true,
      visualFontSize: (json['visualFontSize'] as num?)?.toDouble(),
      color: _colorFromInt(json['color'] as int? ?? 0xFF000000),
    );
  }
}

class PdfAnnotation {
  const PdfAnnotation({
    required this.id,
    required this.pageIndex,
    required this.type,
    required this.bounds,
    this.text,
    this.originalText,
    this.imagePath,
    this.fontFamily = 'Sans',
    this.fontSize = 14,
    this.visualFontSize,
    this.color = const Color(0xFF2D2620),
    this.backgroundColor,
    this.opacity = 1,
    this.strokeWidth = 2.4,
    this.points = const [],
  });

  final String id;
  final int pageIndex;
  final AnnotationType type;
  final Rect bounds;
  final String? text;
  final String? originalText;
  final String? imagePath;
  final String fontFamily;
  final double fontSize;
  final double? visualFontSize;
  final Color color;
  final Color? backgroundColor;
  final double opacity;
  final double strokeWidth;
  final List<Offset> points;

  PdfAnnotation copyWith({
    String? id,
    int? pageIndex,
    AnnotationType? type,
    Rect? bounds,
    String? text,
    String? originalText,
    String? imagePath,
    String? fontFamily,
    double? fontSize,
    double? visualFontSize,
    Color? color,
    Color? backgroundColor,
    double? opacity,
    double? strokeWidth,
    List<Offset>? points,
  }) {
    return PdfAnnotation(
      id: id ?? this.id,
      pageIndex: pageIndex ?? this.pageIndex,
      type: type ?? this.type,
      bounds: bounds ?? this.bounds,
      text: text ?? this.text,
      originalText: originalText ?? this.originalText,
      imagePath: imagePath ?? this.imagePath,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      visualFontSize: visualFontSize ?? this.visualFontSize,
      color: color ?? this.color,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      opacity: opacity ?? this.opacity,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      points: points ?? this.points,
    );
  }

  factory PdfAnnotation.fromJson(Map<String, dynamic> json) {
    return PdfAnnotation(
      id: json['id'] as String,
      pageIndex: json['pageIndex'] as int,
      type: _typeFromName(json['type'] as String),
      bounds: _rectFromJson(json['bounds'] as Map<Object?, Object?>),
      text: json['text'] as String?,
      originalText: json['originalText'] as String?,
      imagePath: json['imagePath'] as String?,
      fontFamily: json['fontFamily'] as String? ?? 'Sans',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14,
      visualFontSize: (json['visualFontSize'] as num?)?.toDouble(),
      color: _colorFromInt(json['color'] as int? ?? 0xFF2D2620),
      backgroundColor: json['backgroundColor'] == null
          ? null
          : _colorFromInt(json['backgroundColor'] as int),
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1,
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 2.4,
      points: ((json['points'] as List<dynamic>?) ?? [])
          .map((point) => _offsetFromJson(point as Map<Object?, Object?>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'pageIndex': pageIndex,
    'type': type.name,
    'bounds': _rectToJson(bounds),
    'text': text,
    'originalText': originalText,
    'imagePath': imagePath,
    'fontFamily': fontFamily,
    'fontSize': fontSize,
    'visualFontSize': visualFontSize,
    'color': color.toARGB32(),
    'backgroundColor': backgroundColor?.toARGB32(),
    'opacity': opacity,
    'strokeWidth': strokeWidth,
    'points': points.map(_offsetToJson).toList(),
  };
}

class PdfDocumentSession {
  const PdfDocumentSession({
    required this.id,
    required this.name,
    required this.sourcePath,
    required this.pageCount,
    required this.pageSizes,
    required this.updatedAt,
    required this.annotations,
  });

  final String id;
  final String name;
  final String sourcePath;
  final int pageCount;
  final List<PdfPageSize> pageSizes;
  final DateTime updatedAt;
  final List<PdfAnnotation> annotations;

  PdfDocumentSession copyWith({
    String? id,
    String? name,
    String? sourcePath,
    int? pageCount,
    List<PdfPageSize>? pageSizes,
    DateTime? updatedAt,
    List<PdfAnnotation>? annotations,
  }) {
    return PdfDocumentSession(
      id: id ?? this.id,
      name: name ?? this.name,
      sourcePath: sourcePath ?? this.sourcePath,
      pageCount: pageCount ?? this.pageCount,
      pageSizes: pageSizes ?? this.pageSizes,
      updatedAt: updatedAt ?? this.updatedAt,
      annotations: annotations ?? this.annotations,
    );
  }

  factory PdfDocumentSession.fromJson(Map<String, dynamic> json) {
    return PdfDocumentSession(
      id: json['id'] as String,
      name: json['name'] as String,
      sourcePath: json['sourcePath'] as String,
      pageCount: json['pageCount'] as int,
      pageSizes: (json['pageSizes'] as List<dynamic>)
          .map((page) => PdfPageSize.fromJson(page as Map<String, dynamic>))
          .toList(),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      annotations: (json['annotations'] as List<dynamic>? ?? [])
          .map((item) => PdfAnnotation.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sourcePath': sourcePath,
    'pageCount': pageCount,
    'pageSizes': pageSizes.map((page) => page.toJson()).toList(),
    'updatedAt': updatedAt.toIso8601String(),
    'annotations': annotations.map((item) => item.toJson()).toList(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

Rect _rectFromJson(Map<Object?, Object?> json) {
  return Rect.fromLTWH(
    (json['left'] as num).toDouble(),
    (json['top'] as num).toDouble(),
    (json['width'] as num).toDouble(),
    (json['height'] as num).toDouble(),
  );
}

Map<String, dynamic> _rectToJson(Rect rect) => {
  'left': rect.left,
  'top': rect.top,
  'width': rect.width,
  'height': rect.height,
};

Offset _offsetFromJson(Map<Object?, Object?> json) {
  return Offset((json['x'] as num).toDouble(), (json['y'] as num).toDouble());
}

Map<String, dynamic> _offsetToJson(Offset offset) => {
  'x': offset.dx,
  'y': offset.dy,
};

Color _colorFromInt(int value) => Color(value);

AnnotationType _typeFromName(String name) {
  return AnnotationType.values.firstWhere(
    (type) => type.name == name,
    orElse: () => AnnotationType.textOverlay,
  );
}
