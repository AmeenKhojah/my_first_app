import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.pdfbox.text.TextPosition;

public final class PdfParagraphAudit {
  public static void main(String[] args) throws Exception {
    if (args.length < 1) {
      System.err.println("Usage: PdfParagraphAudit <pdf> [pageIndex]");
      System.exit(2);
    }

    int pageIndex = args.length > 1 ? Integer.parseInt(args[1]) : 8;
    List<Paragraph> paragraphs;
    try (PDDocument document = PDDocument.load(new File(args[0]))) {
      Extractor extractor = new Extractor();
      extractor.setSortByPosition(false);
      extractor.setStartPage(pageIndex + 1);
      extractor.setEndPage(pageIndex + 1);
      extractor.getText(document);
      paragraphs = groupParagraphs(extractor.glyphs, null);
    }

    runSyntheticRegressions();

    for (int index = 0; index < paragraphs.size(); index++) {
      Paragraph paragraph = paragraphs.get(index);
      System.out.printf(
          Locale.US,
          "PARAGRAPH %02d box=[%.2f %.2f %.2f %.2f] text=\"%s\"%n",
          index,
          paragraph.bounds().left,
          paragraph.bounds().top,
          paragraph.bounds().width(),
          paragraph.bounds().height(),
          paragraph.text().replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n"));
    }

    if (pageIndex == 8) {
      assertSamplePage(paragraphs);
    }
    System.out.printf("PASS page=%d paragraphs=%d%n", pageIndex, paragraphs.size());
  }

  private static void assertSamplePage(List<Paragraph> paragraphs) {
    boolean leftParagraph = paragraphs.stream()
        .map(Paragraph::text)
        .anyMatch(text -> text.contains("Your legal name and address")
            && text.contains("verified by uploading official identity documents"));
    boolean rightParagraph = paragraphs.stream()
        .map(Paragraph::text)
        .anyMatch(text -> text.contains("Organizations will also need to provide their D-U-N-S")
            && text.contains("Make sure you have this number before you start"));
    boolean crossColumnMerge = paragraphs.stream()
        .map(Paragraph::text)
        .anyMatch(text -> text.contains("Your legal name and address")
            && text.contains("Organizations will also need to provide their D-U-N-S"));

    if (!leftParagraph || !rightParagraph || crossColumnMerge) {
      throw new IllegalStateException(
          "Paragraph regression: left=" + leftParagraph
              + " right=" + rightParagraph
              + " crossColumnMerge=" + crossColumnMerge);
    }
  }

  private static void runSyntheticRegressions() {
    assertNoLetterSpacingRegression();
    assertStackedLabelsStaySeparate();
    assertWrappedParagraphStillMerges();
  }

  private static void assertNoLetterSpacingRegression() {
    String source = "Serial Number IBAN";
    List<Glyph> glyphs = glyphsForTextLine(source, 40, 80, 10, 0);
    List<Paragraph> paragraphs = groupParagraphs(glyphs, source);
    if (paragraphs.size() != 1 || !paragraphs.get(0).text().equals(source)) {
      throw new IllegalStateException("Letter spacing regression: " + paragraphs);
    }
  }

  private static void assertStackedLabelsStaySeparate() {
    List<Glyph> glyphs = new ArrayList<>();
    glyphs.add(lineGlyph("IBAN Number", 60, 100, 10, 0));
    glyphs.add(lineGlyph("National ID", 60, 113, 10, 20));
    glyphs.add(lineGlyph("Serial Number", 60, 126, 10, 40));

    List<Paragraph> paragraphs = groupParagraphs(glyphs, null);
    if (paragraphs.size() != 3) {
      throw new IllegalStateException("Stacked label regression: " + paragraphTexts(paragraphs));
    }
  }

  private static void assertWrappedParagraphStillMerges() {
    List<Glyph> glyphs = new ArrayList<>();
    glyphs.add(lineGlyph("Your legal name and address. These will need to be", 60, 100, 10, 0));
    glyphs.add(lineGlyph("verified by uploading official identity documents.", 60, 113, 10, 60));

    List<Paragraph> paragraphs = groupParagraphs(glyphs, null);
    if (paragraphs.size() != 1
        || !paragraphs.get(0).text().contains("verified by uploading official identity documents")) {
      throw new IllegalStateException("Wrapped paragraph regression: " + paragraphTexts(paragraphs));
    }
  }

  private static List<String> paragraphTexts(List<Paragraph> paragraphs) {
    return paragraphs.stream().map(Paragraph::text).toList();
  }

  private static List<Glyph> glyphsForTextLine(
      String source, double left, double top, double fontSize, int sourceOffset) {
    List<Glyph> glyphs = new ArrayList<>();
    double x = left;
    double width = fontSize * 0.48;
    for (int index = 0; index < source.length(); index++) {
      char character = source.charAt(index);
      if (Character.isWhitespace(character)) {
        x += width * 1.4;
        continue;
      }
      glyphs.add(
          new Glyph(
              String.valueOf(character),
              sourceOffset + index,
              new Bounds(x, top, x + width, top + fontSize),
              fontSize,
              "Sans"));
      x += width + 1.2;
    }
    return glyphs;
  }

  private static Glyph lineGlyph(String text, double left, double top, double fontSize, int sourceIndex) {
    return new Glyph(
        text,
        sourceIndex,
        new Bounds(left, top, left + text.length() * fontSize * 0.48, top + fontSize),
        fontSize,
        "Sans");
  }

  private static List<Paragraph> groupParagraphs(List<Glyph> glyphs, String sourceText) {
    List<Glyph> sorted = new ArrayList<>(glyphs);
    sorted.sort((a, b) -> {
      double verticalDifference = Math.abs(a.midY() - b.midY());
      double threshold = Math.max(2, Math.min(a.bounds.height(), b.bounds.height()) * 0.35);
      return verticalDifference > threshold
          ? Double.compare(a.midY(), b.midY())
          : Double.compare(a.bounds.left, b.bounds.left);
    });

    List<List<Glyph>> glyphLines = new ArrayList<>();
    for (Glyph glyph : sorted) {
      List<Glyph> best = null;
      double bestDistance = Double.MAX_VALUE;
      for (List<Glyph> line : glyphLines) {
        if (!isSameLine(glyph, line)) continue;
        double averageY = line.stream().mapToDouble(Glyph::midY).average().orElse(glyph.midY());
        double distance = Math.abs(glyph.midY() - averageY);
        if (distance < bestDistance) {
          best = line;
          bestDistance = distance;
        }
      }
      if (best == null) {
        best = new ArrayList<>();
        glyphLines.add(best);
      }
      best.add(glyph);
    }

    List<Line> visualLines = new ArrayList<>();
    for (List<Glyph> line : glyphLines) {
      visualLines.addAll(splitVisualLine(line, sourceText));
    }
    visualLines.sort(Comparator.comparingDouble((Line line) -> line.bounds.top)
        .thenComparingDouble(line -> line.bounds.left));

    List<Paragraph> paragraphs = new ArrayList<>();
    for (Line line : visualLines) {
      Paragraph best = null;
      double bestScore = Double.MAX_VALUE;
      for (Paragraph paragraph : paragraphs) {
        Double score = paragraphJoinScore(paragraph, line);
        if (score != null && score < bestScore) {
          best = paragraph;
          bestScore = score;
        }
      }
      if (best == null) {
        best = new Paragraph();
        paragraphs.add(best);
      }
      best.lines.add(line);
    }

    paragraphs.sort(Comparator.comparingDouble((Paragraph paragraph) -> paragraph.bounds().top)
        .thenComparingDouble(paragraph -> paragraph.bounds().left));
    return paragraphs;
  }

  private static boolean isSameLine(Glyph glyph, List<Glyph> line) {
    double averageY = line.stream().mapToDouble(Glyph::midY).average().orElse(glyph.midY());
    double lineHeight = line.stream().mapToDouble(item -> item.bounds.height()).max()
        .orElse(glyph.bounds.height());
    double threshold = Math.max(2, Math.max(lineHeight, glyph.bounds.height()) * 0.55);
    return Math.abs(glyph.midY() - averageY) <= threshold;
  }

  private static List<Line> splitVisualLine(List<Glyph> glyphs, String sourceText) {
    List<Glyph> ordered = new ArrayList<>(glyphs);
    ordered.sort(Comparator.comparingDouble(glyph -> glyph.bounds.left));
    List<List<Glyph>> groups = new ArrayList<>();
    for (Glyph glyph : ordered) {
      if (groups.isEmpty()) groups.add(new ArrayList<>());
      List<Glyph> current = groups.get(groups.size() - 1);
      if (!current.isEmpty()) {
        Glyph previous = current.get(current.size() - 1);
        double gap = glyph.bounds.left - previous.bounds.right;
        double splitGap = Math.max(24, Math.max(previous.fontSize, glyph.fontSize) * 2.2);
        if (gap > splitGap) {
          current = new ArrayList<>();
          groups.add(current);
        }
      }
      current.add(glyph);
    }

    List<Line> lines = new ArrayList<>();
    for (List<Glyph> group : groups) {
      Line line = makeLine(group, sourceText);
      if (line != null) lines.add(line);
    }
    return lines;
  }

  private static Line makeLine(List<Glyph> glyphs, String sourceText) {
    if (glyphs.isEmpty()) return null;
    StringBuilder text = new StringBuilder();
    Bounds bounds = glyphs.get(0).bounds;
    Glyph previous = null;
    for (Glyph glyph : glyphs) {
      if (previous != null) {
        if (shouldInsertSpace(previous, glyph, sourceText)
            && !text.isEmpty()
            && text.charAt(text.length() - 1) != ' ') {
          text.append(' ');
        }
      }
      text.append(glyph.text);
      bounds = bounds.union(glyph.bounds);
      previous = glyph;
    }
    String clean = text.toString().replaceAll("\\s+", " ").trim();
    return clean.isEmpty()
        ? null
        : new Line(clean, bounds, glyphs.get(0).fontSize, glyphs.get(0).fontName);
  }

  private static boolean shouldInsertSpace(Glyph previous, Glyph glyph, String sourceText) {
    if (sourceText != null
        && glyph.sourceIndex > previous.sourceIndex + 1
        && glyph.sourceIndex <= sourceText.length()) {
      int start = previous.sourceIndex + 1;
      String skipped = sourceText.substring(start, glyph.sourceIndex);
      if (skipped.chars().anyMatch(Character::isWhitespace)) {
        return true;
      }
    }

    double gap = glyph.bounds.left - previous.bounds.right;
    double fontSize = Math.max(previous.fontSize, glyph.fontSize);
    double fallbackGap =
        sourceText == null ? Math.max(0.8, fontSize * 0.12) : Math.max(5, fontSize * 0.55);
    return gap > fallbackGap;
  }

  private static Double paragraphJoinScore(Paragraph paragraph, Line line) {
    if (paragraph.lines.isEmpty()) return null;
    Line previous = paragraph.lines.get(paragraph.lines.size() - 1);
    double verticalGap = line.bounds.top - previous.bounds.bottom;
    double allowedOverlap = Math.min(previous.bounds.height(), line.bounds.height()) * 0.2;
    double maximumGap = Math.max(previous.bounds.height(), line.bounds.height()) * 1.9;
    if (verticalGap < -allowedOverlap || verticalGap > maximumGap) return null;

    double overlap = Math.max(
        0,
        Math.min(previous.bounds.right, line.bounds.right)
            - Math.max(previous.bounds.left, line.bounds.left));
    double smallerWidth = Math.max(1, Math.min(previous.bounds.width(), line.bounds.width()));
    double overlapRatio = overlap / smallerWidth;
    double leftDifference = Math.abs(previous.bounds.left - line.bounds.left);
    double alignmentTolerance = Math.max(18, Math.max(previous.fontSize, line.fontSize) * 2.2);
    if (overlapRatio < 0.2 && leftDifference > alignmentTolerance) return null;

    double smallerFont = Math.max(1, Math.min(previous.fontSize, line.fontSize));
    double fontRatio = Math.max(previous.fontSize, line.fontSize) / smallerFont;
    if (fontRatio > 1.65) return null;
    if (!isParagraphContinuation(paragraph, line)) return null;

    return Math.max(0, verticalGap) + leftDifference * 0.12 - overlapRatio * 4;
  }

  private static boolean isParagraphContinuation(Paragraph paragraph, Line line) {
    if (paragraph.lines.isEmpty()) return false;
    Line previous = paragraph.lines.get(paragraph.lines.size() - 1);
    String previousText = previous.text.strip();
    String text = line.text.strip();
    if (previousText.isEmpty() || text.isEmpty()) return false;
    if (previousText.endsWith(":") || startsNewTextSection(text)) return false;
    if (paragraph.lines.size() >= 2
        && !paragraph.lines.stream().allMatch(item -> looksLikeFieldLabel(item.text))) {
      return true;
    }
    if (looksLikeFieldLabel(previousText) && looksLikeFieldLabel(text)) return false;
    if (looksLikeFieldLabel(text) && endsSentence(previousText)) return false;
    return isParagraphSized(previous) || isParagraphSized(line);
  }

  private static boolean startsNewTextSection(String text) {
    String trimmed = text.strip();
    if (trimmed.isEmpty()) return false;
    char first = trimmed.charAt(0);
    if ("•-–—*?▪".indexOf(first) >= 0) return true;
    return trimmed.matches("^\\d+[\\.)]\\s+.*");
  }

  private static boolean looksLikeFieldLabel(String text) {
    if (text.matches(".*[.,;:!?].*")) return false;
    String[] words = text.strip().split("\\s+");
    if (words.length == 0 || words.length > 5) return false;
    int meaningfulCount = text.replaceAll("\\s+", "").length();
    if (meaningfulCount > 40) return false;

    for (String word : words) {
      String lower = word.toLowerCase(Locale.US);
      if (List.of(
              "account", "address", "bank", "birth", "date", "email", "holder", "iban",
              "id", "identity", "name", "national", "number", "phone", "serial", "tax")
          .contains(lower)) {
        return true;
      }
    }
    return words.length <= 3;
  }

  private static boolean isParagraphSized(Line line) {
    int meaningfulCount = line.text.replaceAll("\\s+", "").length();
    if (meaningfulCount >= 28) return true;

    double estimatedCharacters = line.bounds.width() / Math.max(line.fontSize * 0.52, 1);
    return estimatedCharacters >= 28;
  }

  private static boolean endsSentence(String text) {
    String stripped = text.strip();
    if (stripped.isEmpty()) return false;
    char last = stripped.charAt(stripped.length() - 1);
    return ".!?".indexOf(last) >= 0;
  }

  private static final class Extractor extends PDFTextStripper {
    final List<Glyph> glyphs = new ArrayList<>();

    Extractor() throws IOException {}

    @Override
    protected void processTextPosition(TextPosition position) {
      String text = position.getUnicode();
      if (text == null || text.isBlank()) return;
      double height = Math.max(position.getHeightDir(), 1);
      glyphs.add(
          new Glyph(
              text,
              glyphs.size(),
              new Bounds(
                  position.getXDirAdj(),
                  position.getYDirAdj() - height,
                  position.getXDirAdj() + position.getWidthDirAdj(),
                  position.getYDirAdj()),
              Math.max(position.getYScale(), 1),
              position.getFont() == null ? "Sans" : position.getFont().getName()));
    }
  }

  private record Glyph(String text, int sourceIndex, Bounds bounds, double fontSize, String fontName) {
    double midY() {
      return (bounds.top + bounds.bottom) / 2;
    }
  }

  private record Line(String text, Bounds bounds, double fontSize, String fontName) {}

  private static final class Paragraph {
    final List<Line> lines = new ArrayList<>();

    String text() {
      return String.join("\n", lines.stream().map(Line::text).toList());
    }

    Bounds bounds() {
      return lines.stream().map(Line::bounds).reduce(Bounds::union).orElse(new Bounds(0, 0, 0, 0));
    }
  }

  private record Bounds(double left, double top, double right, double bottom) {
    double width() {
      return right - left;
    }

    double height() {
      return bottom - top;
    }

    Bounds union(Bounds other) {
      return new Bounds(
          Math.min(left, other.left),
          Math.min(top, other.top),
          Math.max(right, other.right),
          Math.max(bottom, other.bottom));
    }
  }
}
