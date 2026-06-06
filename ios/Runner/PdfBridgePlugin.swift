import Flutter
import PDFKit
import UIKit

final class PdfBridgePlugin: NSObject, UIDocumentPickerDelegate {
  private enum PickKind {
    case pdf
    case image
  }

  private let channel: FlutterMethodChannel
  private var pendingPickResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "warm_pdf_editor/pdf",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "pickPdf", "pickPDF":
        try presentPicker(kind: .pdf, result: result)
      case "pickImage":
        try presentPicker(kind: .image, result: result)
      case "openPdf":
        let arguments = try arguments(from: call)
        let path = try string("path", from: arguments)
        result(try openPdf(path: path))
      case "extractTextBlocks":
        let arguments = try arguments(from: call)
        let path = try string("path", from: arguments)
        let pageIndex = Int(number(arguments["pageIndex"]))
        result(try extractTextBlocks(path: path, pageIndex: pageIndex))
      case "exportPdf":
        let arguments = try arguments(from: call)
        let sourcePath = try string("sourcePath", from: arguments)
        let outputPath = try string("outputPath", from: arguments)
        let annotations = arguments["annotations"] as? [[String: Any]] ?? []
        result(
          try exportPdf(
            sourcePath: sourcePath,
            outputPath: outputPath,
            annotations: annotations
          )
        )
      case "sharePdf":
        let arguments = try arguments(from: call)
        try sharePdf(path: string("path", from: arguments))
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(
        FlutterError(
          code: "PDF_ERROR",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func presentPicker(kind: PickKind, result: @escaping FlutterResult) throws {
    guard pendingPickResult == nil else {
      throw BridgeError.message("A file picker is already open.")
    }
    guard let presenter = topViewController() else {
      throw BridgeError.message("Could not find a screen to present the file picker.")
    }

    pendingPickResult = result
    let picker = UIDocumentPickerViewController(
      documentTypes: [kind == .pdf ? "com.adobe.pdf" : "public.image"],
      in: .import
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let result = takePendingPickResult() else { return }
    guard let source = urls.first else {
      result(nil)
      return
    }

    do {
      let name = safeFileName(source.lastPathComponent)
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("picked-\(UUID().uuidString)-\(name)")
      let securityAccess = source.startAccessingSecurityScopedResource()
      defer {
        if securityAccess {
          source.stopAccessingSecurityScopedResource()
        }
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
      result(["path": destination.path, "name": name])
    } catch {
      result(
        FlutterError(
          code: "PICK_ERROR",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    takePendingPickResult()?(nil)
  }

  private func takePendingPickResult() -> FlutterResult? {
    defer {
      pendingPickResult = nil
    }
    return pendingPickResult
  }

  private func openPdf(path: String) throws -> [String: Any] {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw BridgeError.message("Could not open the selected PDF.")
    }

    let pageSizes: [[String: Any]] = (0..<document.pageCount).compactMap { index in
      guard let page = document.page(at: index) else { return nil }
      let bounds = page.bounds(for: .mediaBox)
      return ["width": bounds.width, "height": bounds.height]
    }
    return ["pageCount": document.pageCount, "pageSizes": pageSizes]
  }

  private func extractTextBlocks(path: String, pageIndex: Int) throws -> [[String: Any]] {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)),
      pageIndex >= 0,
      pageIndex < document.pageCount,
      let page = document.page(at: pageIndex)
    else {
      throw BridgeError.message("Could not read PDF page \(pageIndex + 1).")
    }

    let pageBounds = page.bounds(for: .mediaBox)
    guard pageBounds.width > 0, pageBounds.height > 0 else {
      return []
    }

    return textParagraphs(on: page).enumerated().map { index, paragraph in
      textBlock(
        paragraph,
        id: "p\(pageIndex)-paragraph\(index)",
        pageIndex: pageIndex,
        pageBounds: pageBounds
      )
    }
  }

  private func exportPdf(
    sourcePath: String,
    outputPath: String,
    annotations: [[String: Any]]
  ) throws -> String {
    guard let document = PDFDocument(url: URL(fileURLWithPath: sourcePath)) else {
      throw BridgeError.message("Could not open the PDF for export.")
    }

    for item in annotations {
      let pageIndex = Int(number(item["pageIndex"]))
      guard pageIndex >= 0, pageIndex < document.pageCount,
        let page = document.page(at: pageIndex)
      else {
        continue
      }
      let type = item["type"] as? String ?? ""

      switch type {
      case "textReplacement":
        addCover(item, to: page)
        addText(item, to: page)
      case "textOverlay":
        addText(item, to: page)
      case "highlight":
        addHighlight(item, to: page)
      case "ink", "signature":
        addInk(item, to: page)
      case "image":
        throw BridgeError.message(
          "Image-overlay export is not supported on iOS yet."
        )
      default:
        continue
      }
    }

    let output = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard document.write(to: output) else {
      throw BridgeError.message("iOS could not write the exported PDF.")
    }
    return output.path
  }

  private func addCover(_ item: [String: Any], to page: PDFPage) {
    let originalRect = pdfRect(item, on: page)
    let rect = CGRect(
      x: originalRect.minX - 0.35,
      y: originalRect.minY,
      width: originalRect.width + 0.7,
      height: originalRect.height
    )
    let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
    annotation.color = .clear
    annotation.interiorColor = color(item["backgroundColor"], fallback: .white)
    annotation.border = border(width: 0)
    annotation.shouldPrint = true
    page.addAnnotation(annotation)
  }

  private func addText(_ item: [String: Any], to page: PDFPage) {
    guard let text = item["text"] as? String, !text.isEmpty else { return }
    let annotation = PDFAnnotation(
      bounds: pdfRect(item, on: page),
      forType: .freeText,
      withProperties: nil
    )
    let fontSize = max(1, min(number(item["fontSize"], fallback: 14), 144))
    let family = item["fontFamily"] as? String ?? ""
    annotation.contents = text
    annotation.font = UIFont(name: family, size: fontSize)
      ?? UIFont.systemFont(ofSize: fontSize)
    annotation.fontColor = color(item["color"], fallback: UIColor(red: 0.18, green: 0.15, blue: 0.13, alpha: 1))
    annotation.color = .clear
    annotation.interiorColor = .clear
    annotation.border = border(width: 0)
    annotation.alignment = .left
    annotation.shouldPrint = true
    page.addAnnotation(annotation)
  }

  private func addHighlight(_ item: [String: Any], to page: PDFPage) {
    let annotation = PDFAnnotation(
      bounds: pdfRect(item, on: page),
      forType: .square,
      withProperties: nil
    )
    let opacity = max(0, min(number(item["opacity"], fallback: 0.35), 1))
    annotation.color = .clear
    annotation.interiorColor = color(
      item["color"],
      fallback: UIColor(red: 1, green: 0.89, blue: 0.45, alpha: 1)
    ).withAlphaComponent(opacity)
    annotation.border = border(width: 0)
    annotation.shouldPrint = true
    page.addAnnotation(annotation)
  }

  private func addInk(_ item: [String: Any], to page: PDFPage) {
    guard let points = item["points"] as? [[String: Any]], points.count > 1 else {
      return
    }
    let pageBounds = page.bounds(for: .mediaBox)
    let annotation = PDFAnnotation(
      bounds: pageBounds,
      forType: .ink,
      withProperties: nil
    )
    let path = UIBezierPath()
    for (index, point) in points.enumerated() {
      let location = CGPoint(
        x: number(point["x"]) * pageBounds.width,
        y: (1 - number(point["y"])) * pageBounds.height
      )
      if index == 0 {
        path.move(to: location)
      } else {
        path.addLine(to: location)
      }
    }
    annotation.add(path)
    annotation.color = color(item["color"], fallback: .black)
    annotation.border = border(
      width: max(0.4, min(number(item["strokeWidth"], fallback: 2.2), 18))
    )
    annotation.shouldPrint = true
    page.addAnnotation(annotation)
  }

  private func sharePdf(path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      throw BridgeError.message("The exported PDF file does not exist.")
    }
    guard let presenter = topViewController() else {
      throw BridgeError.message("Could not find a screen to present the share sheet.")
    }
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let popover = controller.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 1,
        height: 1
      )
    }
    presenter.present(controller, animated: true)
  }

  private func pdfRect(_ item: [String: Any], on page: PDFPage) -> CGRect {
    let bounds = item["bounds"] as? [String: Any] ?? [:]
    let pageBounds = page.bounds(for: .mediaBox)
    let left = clamp(number(bounds["left"]))
    let top = clamp(number(bounds["top"]))
    let width = clamp(number(bounds["width"], fallback: 0.1), minimum: 0.001)
    let height = clamp(number(bounds["height"], fallback: 0.05), minimum: 0.001)
    return CGRect(
      x: pageBounds.minX + left * pageBounds.width,
      y: pageBounds.minY + (1 - top - height) * pageBounds.height,
      width: width * pageBounds.width,
      height: height * pageBounds.height
    )
  }

  private func textParagraphs(on page: PDFPage) -> [TextParagraph] {
    let attributedText = page.attributedString
    let plainText = page.string.map { $0 as NSString }
    var glyphs: [TextGlyph] = []

    for index in 0..<page.numberOfCharacters {
      let range = NSRange(location: index, length: 1)
      let rawText: String
      if let plainText = plainText, index < plainText.length {
        rawText = plainText.substring(with: range)
      } else {
        rawText = page.selection(for: range)?.string ?? ""
      }
      let text = rawText.replacingOccurrences(of: "\n", with: "")
        .replacingOccurrences(of: "\r", with: "")
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        continue
      }

      let bounds = page.characterBounds(at: index)
      guard bounds.width > 0, bounds.height > 0,
        bounds.minX.isFinite, bounds.minY.isFinite,
        bounds.width.isFinite, bounds.height.isFinite
      else {
        continue
      }

      let attributes: [NSAttributedString.Key: Any]
      if let attributedText = attributedText, index < attributedText.length {
        attributes = attributedText.attributes(at: index, effectiveRange: nil)
      } else {
        attributes = [:]
      }
      let font = attributes[.font] as? UIFont
      glyphs.append(
        TextGlyph(
          text: text,
          sourceIndex: index,
          bounds: bounds,
          fontSize: font?.pointSize ?? max(bounds.height * 0.8, 8),
          fontFamily: font?.familyName ?? "Sans",
          color: attributes[.foregroundColor] as? UIColor ?? .black
        )
      )
    }

    let sortedGlyphs = glyphs.sorted {
      let verticalDifference = abs($0.bounds.midY - $1.bounds.midY)
      if verticalDifference > max(2, min($0.bounds.height, $1.bounds.height) * 0.35) {
        return $0.bounds.midY > $1.bounds.midY
      }
      return $0.bounds.minX < $1.bounds.minX
    }

    var glyphLines: [[TextGlyph]] = []
    for glyph in sortedGlyphs {
      var bestIndex: Int?
      var bestDistance = CGFloat.greatestFiniteMagnitude
      for index in glyphLines.indices where isSameLine(glyph, as: glyphLines[index]) {
        let averageY =
          glyphLines[index].reduce(CGFloat.zero) { $0 + $1.bounds.midY }
          / CGFloat(glyphLines[index].count)
        let distance = abs(glyph.bounds.midY - averageY)
        if distance < bestDistance {
          bestIndex = index
          bestDistance = distance
        }
      }

      if let bestIndex = bestIndex {
        glyphLines[bestIndex].append(glyph)
      } else {
        glyphLines.append([glyph])
      }
    }

    let visualLines = glyphLines.flatMap {
      splitVisualLine($0, sourceText: plainText)
    }.sorted {
      let verticalDifference = abs($0.bounds.maxY - $1.bounds.maxY)
      if verticalDifference > 2 {
        return $0.bounds.maxY > $1.bounds.maxY
      }
      return $0.bounds.minX < $1.bounds.minX
    }

    return groupParagraphs(visualLines)
  }

  private func isSameLine(_ glyph: TextGlyph, as line: [TextGlyph]) -> Bool {
    guard !line.isEmpty else { return false }
    let averageY =
      line.reduce(CGFloat.zero) { $0 + $1.bounds.midY } / CGFloat(line.count)
    let lineHeight = line.map(\.bounds.height).max() ?? glyph.bounds.height
    let threshold = max(2, max(lineHeight, glyph.bounds.height) * 0.55)
    return abs(glyph.bounds.midY - averageY) <= threshold
  }

  private func splitVisualLine(_ line: [TextGlyph], sourceText: NSString?) -> [TextLine] {
    let ordered = line.sorted { $0.bounds.minX < $1.bounds.minX }
    guard let first = ordered.first else { return [] }

    var groups: [[TextGlyph]] = [[first]]
    var previous = first
    for glyph in ordered.dropFirst() {
      let gap = glyph.bounds.minX - previous.bounds.maxX
      let splitGap = max(24, max(previous.fontSize, glyph.fontSize) * 2.2)
      if gap > splitGap {
        groups.append([])
      }
      groups[groups.count - 1].append(glyph)
      previous = glyph
    }

    return groups.compactMap { makeTextLine($0, sourceText: sourceText) }
  }

  private func makeTextLine(_ glyphs: [TextGlyph], sourceText: NSString?) -> TextLine? {
    guard let first = glyphs.first else { return nil }
    var text = ""
    var bounds = first.bounds
    var previous: TextGlyph?

    for glyph in glyphs {
      if let previous = previous {
        if shouldInsertSpace(between: previous, and: glyph, sourceText: sourceText),
          !text.hasSuffix(" ")
        {
          text.append(" ")
        }
      }
      text.append(contentsOf: glyph.text)
      bounds = bounds.union(glyph.bounds)
      previous = glyph
    }

    let cleanText = text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !cleanText.isEmpty else { return nil }
    return TextLine(
      text: cleanText,
      bounds: bounds,
      fontSize: first.fontSize,
      fontFamily: first.fontFamily,
      color: first.color
    )
  }

  private func shouldInsertSpace(
    between previous: TextGlyph,
    and glyph: TextGlyph,
    sourceText: NSString?
  ) -> Bool {
    if let sourceText = sourceText,
      glyph.sourceIndex > previous.sourceIndex + 1,
      glyph.sourceIndex <= sourceText.length
    {
      let location = previous.sourceIndex + 1
      let length = glyph.sourceIndex - location
      if length > 0 {
        let skippedText = sourceText.substring(
          with: NSRange(location: location, length: length)
        )
        if skippedText.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
          return true
        }
      }
    }

    let gap = glyph.bounds.minX - previous.bounds.maxX
    let fontSize = max(previous.fontSize, glyph.fontSize)
    let fallbackGap: CGFloat
    if sourceText == nil {
      fallbackGap = max(3, fontSize * 0.35)
    } else {
      fallbackGap = max(5, fontSize * 0.55)
    }
    return gap > fallbackGap
  }

  private func groupParagraphs(_ lines: [TextLine]) -> [TextParagraph] {
    var paragraphs: [TextParagraph] = []

    for line in lines {
      var bestIndex: Int?
      var bestScore = CGFloat.greatestFiniteMagnitude
      for index in paragraphs.indices {
        guard let score = paragraphJoinScore(paragraphs[index], line: line) else {
          continue
        }
        if score < bestScore {
          bestIndex = index
          bestScore = score
        }
      }

      if let bestIndex = bestIndex {
        paragraphs[bestIndex].lines.append(line)
      } else {
        paragraphs.append(TextParagraph(lines: [line]))
      }
    }

    return paragraphs.sorted {
      let verticalDifference = abs($0.bounds.maxY - $1.bounds.maxY)
      if verticalDifference > 2 {
        return $0.bounds.maxY > $1.bounds.maxY
      }
      return $0.bounds.minX < $1.bounds.minX
    }
  }

  private func paragraphJoinScore(
    _ paragraph: TextParagraph,
    line: TextLine
  ) -> CGFloat? {
    guard let previous = paragraph.lines.last else { return nil }

    let verticalGap = previous.bounds.minY - line.bounds.maxY
    let allowedOverlap = min(previous.bounds.height, line.bounds.height) * 0.2
    let maximumGap = max(previous.bounds.height, line.bounds.height) * 1.9
    guard verticalGap >= -allowedOverlap, verticalGap <= maximumGap else {
      return nil
    }

    let overlap = max(
      0,
      min(previous.bounds.maxX, line.bounds.maxX)
        - max(previous.bounds.minX, line.bounds.minX)
    )
    let smallerWidth = max(1, min(previous.bounds.width, line.bounds.width))
    let overlapRatio = overlap / smallerWidth
    let leftDifference = abs(previous.bounds.minX - line.bounds.minX)
    let alignmentTolerance = max(18, max(previous.fontSize, line.fontSize) * 2.2)
    guard overlapRatio >= 0.2 || leftDifference <= alignmentTolerance else {
      return nil
    }

    let smallerFont = max(1, min(previous.fontSize, line.fontSize))
    let fontRatio = max(previous.fontSize, line.fontSize) / smallerFont
    guard fontRatio <= 1.65 else { return nil }
    guard isParagraphContinuation(from: paragraph, to: line) else { return nil }

    return max(0, verticalGap) + leftDifference * 0.12 - overlapRatio * 4
  }

  private func isParagraphContinuation(from paragraph: TextParagraph, to line: TextLine) -> Bool {
    guard let previous = paragraph.lines.last else { return false }
    let previousText = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !previousText.isEmpty, !text.isEmpty else { return false }
    if previousText.hasSuffix(":") || startsNewTextSection(text) {
      return false
    }
    if paragraph.lines.count >= 2,
      !paragraph.lines.allSatisfy({ looksLikeFieldLabel($0.text) })
    {
      return true
    }
    if looksLikeFieldLabel(previousText) && looksLikeFieldLabel(text) {
      return false
    }
    if looksLikeFieldLabel(text) && endsSentence(previousText) {
      return false
    }

    return isParagraphSized(previous) || isParagraphSized(line)
  }

  private func startsNewTextSection(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return false }
    if "•-–—*?▪".contains(first) {
      return true
    }
    return trimmed.range(
      of: #"^\d+[\.\)]\s+"#,
      options: .regularExpression
    ) != nil
  }

  private func looksLikeFieldLabel(_ text: String) -> Bool {
    if text.rangeOfCharacter(from: CharacterSet(charactersIn: ".,;:!?")) != nil {
      return false
    }

    let words = text
      .split { $0.isWhitespace }
      .map(String.init)
      .filter { !$0.isEmpty }
    guard !words.isEmpty, words.count <= 5 else {
      return false
    }

    let meaningfulCount = text.filter { !$0.isWhitespace }.count
    guard meaningfulCount <= 40 else {
      return false
    }

    let formTerms = [
      "account", "address", "bank", "birth", "date", "email", "holder", "iban",
      "id", "identity", "name", "national", "number", "phone", "serial", "tax",
    ]
    let lowerWords = words.map { $0.lowercased() }
    if lowerWords.contains(where: { formTerms.contains($0) }) {
      return true
    }

    return words.count <= 3
  }

  private func isParagraphSized(_ line: TextLine) -> Bool {
    let meaningfulCount = line.text.filter { !$0.isWhitespace }.count
    if meaningfulCount >= 28 {
      return true
    }

    let estimatedCharacters = line.bounds.width / max(line.fontSize * 0.52, 1)
    return estimatedCharacters >= 28
  }

  private func endsSentence(_ text: String) -> Bool {
    guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
      return false
    }
    return ".!?".contains(last)
  }

  private func textBlock(
    _ paragraph: TextParagraph,
    id: String,
    pageIndex: Int,
    pageBounds: CGRect
  ) -> [String: Any] {
    let bounds = paragraph.bounds.intersection(pageBounds)
    let left = (bounds.minX - pageBounds.minX) / pageBounds.width
    let top = (pageBounds.maxY - bounds.maxY) / pageBounds.height
    return [
      "id": id,
      "pageIndex": pageIndex,
      "text": paragraph.text,
      "bounds": [
        "left": clamp(left),
        "top": clamp(top),
        "width": clamp(bounds.width / pageBounds.width, minimum: 0.002),
        "height": clamp(bounds.height / pageBounds.height, minimum: 0.002),
      ],
      "fontSize": paragraph.fontSize,
      "visualFontSize": paragraph.fontSize,
      "fontFamily": paragraph.fontFamily,
      "color": argb(paragraph.color),
      "editable": true,
    ]
  }

  private func border(width: CGFloat) -> PDFBorder {
    let value = PDFBorder()
    value.lineWidth = width
    return value
  }

  private func color(_ raw: Any?, fallback: UIColor) -> UIColor {
    guard raw != nil else { return fallback }
    let value = UInt32(truncatingIfNeeded: Int64(number(raw)))
    return UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: CGFloat((value >> 24) & 0xFF) / 255
    )
  }

  private func argb(_ color: UIColor) -> Int64 {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
      return 0xFF000000
    }
    return (Int64(alpha * 255) << 24)
      | (Int64(red * 255) << 16)
      | (Int64(green * 255) << 8)
      | Int64(blue * 255)
  }

  private func number(_ value: Any?, fallback: CGFloat = 0) -> CGFloat {
    (value as? NSNumber).map { CGFloat(truncating: $0) } ?? fallback
  }

  private func clamp(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
    max(minimum, min(value, 1))
  }

  private func arguments(from call: FlutterMethodCall) throws -> [String: Any] {
    guard let arguments = call.arguments as? [String: Any] else {
      throw BridgeError.message("The PDF request did not include valid arguments.")
    }
    return arguments
  }

  private func string(_ key: String, from arguments: [String: Any]) throws -> String {
    guard let value = arguments[key] as? String, !value.isEmpty else {
      throw BridgeError.message("The PDF request is missing '\(key)'.")
    }
    return value
  }

  private func safeFileName(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
    return name.components(separatedBy: invalid).joined(separator: "_")
  }

  private func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    return topViewController(from: root)
  }

  private func topViewController(from controller: UIViewController?) -> UIViewController? {
    if let presented = controller?.presentedViewController {
      return topViewController(from: presented)
    }
    if let navigation = controller as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = controller as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    return controller
  }
}

private struct TextGlyph {
  let text: String
  let sourceIndex: Int
  let bounds: CGRect
  let fontSize: CGFloat
  let fontFamily: String
  let color: UIColor
}

private struct TextLine {
  let text: String
  let bounds: CGRect
  let fontSize: CGFloat
  let fontFamily: String
  let color: UIColor
}

private struct TextParagraph {
  var lines: [TextLine]

  var text: String {
    lines.map(\.text).joined(separator: "\n")
  }

  var bounds: CGRect {
    lines.dropFirst().reduce(lines.first?.bounds ?? .null) {
      $0.union($1.bounds)
    }
  }

  var fontSize: CGFloat {
    lines.first?.fontSize ?? 12
  }

  var fontFamily: String {
    lines.first?.fontFamily ?? "Sans"
  }

  var color: UIColor {
    lines.first?.color ?? .black
  }
}

private enum BridgeError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message):
      return message
    }
  }
}
