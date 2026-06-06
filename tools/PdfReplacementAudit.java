import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import javax.imageio.ImageIO;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.font.PDFont;
import org.apache.pdfbox.pdmodel.graphics.color.PDColor;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.pdfbox.text.TextPosition;
import org.apache.pdfbox.util.Matrix;
import org.apache.pdfbox.util.Vector;

public final class PdfReplacementAudit {
  public static void main(String[] args) throws Exception {
    if (args.length < 1) {
      System.err.println("Usage: PdfReplacementAudit <pdf> [pagesToTest] [dpi]");
      System.exit(2);
    }

    File source = new File(args[0]);
    int pagesToTest = args.length > 1 ? Integer.parseInt(args[1]) : 6;
    int dpi = args.length > 2 ? Integer.parseInt(args[2]) : 180;
    File outPdf = new File("tools/out/self-replace.pdf");

    try (PDDocument document = PDDocument.load(source)) {
      int pages = Math.min(pagesToTest, document.getNumberOfPages());
      for (int pageIndex = 0; pageIndex < pages; pageIndex++) {
        replacePageLines(document, pageIndex, dpi);
      }
      document.save(outPdf);
    }

    try (PDDocument original = PDDocument.load(source);
        PDDocument replaced = PDDocument.load(outPdf)) {
      PDFRenderer originalRenderer = new PDFRenderer(original);
      PDFRenderer replacedRenderer = new PDFRenderer(replaced);
      int pages = Math.min(pagesToTest, original.getNumberOfPages());
      for (int pageIndex = 0; pageIndex < pages; pageIndex++) {
        BufferedImage a = originalRenderer.renderImageWithDPI(pageIndex, dpi, ImageType.RGB);
        BufferedImage b = replacedRenderer.renderImageWithDPI(pageIndex, dpi, ImageType.RGB);
        Diff diff = diff(a, b);
        ImageIO.write(b, "png", new File("tools/out/self-replace-page-" + pageIndex + ".png"));
        System.out.printf(
            Locale.US,
            "PAGE %d changedPixels=%d totalPixels=%d changedRatio=%.6f avgChannelDiff=%.4f maxChannelDiff=%d%n",
            pageIndex,
            diff.changedPixels,
            diff.totalPixels,
            diff.changedPixels / (double) diff.totalPixels,
            diff.avgChannelDiff,
            diff.maxChannelDiff);
      }
    }

    System.out.println("PDF " + outPdf.getAbsolutePath());
  }

  private static void replacePageLines(PDDocument document, int pageIndex, int dpi) throws Exception {
    PDPage page = document.getPage(pageIndex);
    PDRectangle box = page.getMediaBox();
    List<Line> lines = extractLines(document, pageIndex);
    BufferedImage rendered = new PDFRenderer(document).renderImageWithDPI(pageIndex, dpi, ImageType.RGB);
    try (PDPageContentStream stream =
        new PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)) {
      for (Line line : lines) {
        PDFont font = findEmbeddedFont(page, line.fontName);
        if (font == null || !canEncode(font, line.text)) continue;
        int rgb = sampleRenderedTextColor(rendered, box, line, line.rgb);
        int bg = sampleBackground(rendered, box, line);

        stream.setNonStrokingColor((bg >> 16) & 0xFF, (bg >> 8) & 0xFF, bg & 0xFF);
        stream.addRect(
            (float) (line.left - 1.2),
            (float) (box.getHeight() - line.bottom - 1.2),
            (float) (line.width + 2.4),
            (float) (line.height + 2.4));
        stream.fill();

        stream.setNonStrokingColor(
            (rgb >> 16) & 0xFF,
            (rgb >> 8) & 0xFF,
            rgb & 0xFF);
        stream.beginText();
        stream.setFont(font, (float) line.fontSize);
        stream.newLineAtOffset((float) line.left, (float) (box.getHeight() - line.bottom));
        stream.showText(line.text);
        stream.endText();
      }
    }
  }

  private static List<Line> extractLines(PDDocument document, int pageIndex) throws Exception {
    StyleStripper stripper = new StyleStripper();
    stripper.setSortByPosition(true);
    stripper.setStartPage(pageIndex + 1);
    stripper.setEndPage(pageIndex + 1);
    stripper.getText(document);

    List<TextChar> chars = stripper.characters;
    chars.sort(Comparator.comparingDouble((TextChar c) -> c.y).thenComparingDouble(c -> c.x));
    List<List<TextChar>> grouped = new ArrayList<>();
    for (TextChar ch : chars) {
      if (ch.value.isBlank()) continue;
      List<TextChar> current = grouped.isEmpty() ? null : grouped.get(grouped.size() - 1);
      if (current == null) {
        current = new ArrayList<>();
        grouped.add(current);
      } else {
        double currentY = current.stream().mapToDouble(c -> c.y).average().orElse(ch.y);
        double currentSize = current.stream().mapToDouble(c -> c.yScale).max().orElse(12);
        double threshold = Math.max(2.0, Math.max(ch.yScale, currentSize) * 0.46);
        if (Math.abs(ch.y - currentY) > threshold) {
          current = new ArrayList<>();
          grouped.add(current);
        }
      }
      current.add(ch);
    }

    List<Line> lines = new ArrayList<>();
    for (List<TextChar> lineChars : grouped) {
      lineChars.sort(Comparator.comparingDouble(c -> c.x));
      for (List<TextChar> runChars : splitTextRuns(lineChars)) {
      String text = buildLineText(runChars);
      if (text.isBlank()) continue;
      double left = runChars.stream().mapToDouble(c -> c.x).min().orElse(0);
      double right = runChars.stream().mapToDouble(c -> c.x + c.width).max().orElse(0);
      double top = runChars.stream().mapToDouble(c -> c.y - c.height).min().orElse(0);
      double bottom = runChars.stream().mapToDouble(c -> c.y).max().orElse(0);
      lines.add(
          new Line(
              text,
              left,
              top,
              right - left,
              bottom - top,
              bottom,
              median(runChars.stream().mapToDouble(c -> c.yScale).sorted().toArray()),
              dominantFont(runChars),
              dominantColor(runChars)));
      }
    }
    return lines;
  }

  private static List<List<TextChar>> splitTextRuns(List<TextChar> chars) {
    List<List<TextChar>> runs = new ArrayList<>();
    if (chars.isEmpty()) return runs;

    List<TextChar> current = new ArrayList<>();
    current.add(chars.get(0));
    TextChar previous = chars.get(0);
    for (int i = 1; i < chars.size(); i++) {
      TextChar ch = chars.get(i);
      double gap = ch.x - (previous.x + previous.width);
      double splitGap = Math.max(24.0, previous.yScale * 1.8);
      if (gap > splitGap) {
        runs.add(current);
        current = new ArrayList<>();
      }
      current.add(ch);
      previous = ch;
    }
    runs.add(current);
    return runs;
  }

  private static String buildLineText(List<TextChar> chars) {
    StringBuilder builder = new StringBuilder();
    Double previousRight = null;
    double previousFontSize = 12;
    for (TextChar ch : chars) {
      double gap = previousRight == null ? 0 : ch.x - previousRight;
      double wordGap = Math.max(0.8, previousFontSize * 0.08);
      if (gap > wordGap && !builder.isEmpty() && builder.charAt(builder.length() - 1) != ' ') {
        builder.append(' ');
      }
      builder.append(ch.value);
      previousRight = ch.x + ch.width;
      previousFontSize = ch.yScale;
    }
    return builder.toString().replaceAll("\\s+", " ").trim();
  }

  private static PDFont findEmbeddedFont(PDPage page, String family) throws IOException {
    String requested = family.substring(family.indexOf('+') + 1);
    for (COSName name : page.getResources().getFontNames()) {
      PDFont font = page.getResources().getFont(name);
      String fontName = font.getName();
      if (fontName.equals(family) || fontName.substring(fontName.indexOf('+') + 1).equals(requested)) {
        return font;
      }
    }
    return null;
  }

  private static boolean canEncode(PDFont font, String text) {
    try {
      font.encode(text);
      return true;
    } catch (Throwable ignored) {
      return false;
    }
  }

  private static String dominantFont(List<TextChar> chars) {
    String best = chars.get(0).fontName;
    int bestCount = -1;
    for (TextChar ch : chars) {
      int count = 0;
      for (TextChar other : chars) {
        if (other.fontName.equals(ch.fontName)) count++;
      }
      if (count > bestCount) {
        bestCount = count;
        best = ch.fontName;
      }
    }
    return best;
  }

  private static int dominantColor(List<TextChar> chars) {
    int best = chars.get(0).rgb;
    int bestCount = -1;
    for (TextChar ch : chars) {
      int count = 0;
      for (TextChar other : chars) {
        if (other.rgb == ch.rgb) count++;
      }
      if (count > bestCount) {
        bestCount = count;
        best = ch.rgb;
      }
    }
    return best;
  }

  private static double median(double[] sorted) {
    if (sorted.length == 0) return 0;
    int middle = sorted.length / 2;
    return sorted.length % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2.0 : sorted[middle];
  }

  private static Diff diff(BufferedImage a, BufferedImage b) {
    int width = Math.min(a.getWidth(), b.getWidth());
    int height = Math.min(a.getHeight(), b.getHeight());
    long totalDiff = 0;
    int max = 0;
    int changed = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int ca = a.getRGB(x, y);
        int cb = b.getRGB(x, y);
        int dr = Math.abs(((ca >> 16) & 0xFF) - ((cb >> 16) & 0xFF));
        int dg = Math.abs(((ca >> 8) & 0xFF) - ((cb >> 8) & 0xFF));
        int db = Math.abs((ca & 0xFF) - (cb & 0xFF));
        int localMax = Math.max(dr, Math.max(dg, db));
        if (localMax > 2) changed++;
        max = Math.max(max, localMax);
        totalDiff += dr + dg + db;
      }
    }
    return new Diff(changed, width * height, totalDiff / (double) (width * height * 3), max);
  }

  private static int sampleRenderedTextColor(
      BufferedImage image, PDRectangle pageBox, Line line, int fallback) {
    int left = clamp((int) Math.floor(line.left / pageBox.getWidth() * image.getWidth()) - 2, 0, image.getWidth() - 1);
    int top = clamp((int) Math.floor(line.top / pageBox.getHeight() * image.getHeight()) - 2, 0, image.getHeight() - 1);
    int right = clamp((int) Math.ceil((line.left + line.width) / pageBox.getWidth() * image.getWidth()) + 2, left + 1, image.getWidth());
    int bottom = clamp((int) Math.ceil((line.top + line.height) / pageBox.getHeight() * image.getHeight()) + 2, top + 1, image.getHeight());

    int bg = sampleBackground(image, pageBox, line);
    double red = 0;
    double green = 0;
    double blue = 0;
    double weight = 0;
    for (int y = top; y < bottom; y++) {
      for (int x = left; x < right; x++) {
        int rgb = image.getRGB(x, y) & 0x00FFFFFF;
        double distance = colorDistance(rgb, bg);
        if (distance < 18) continue;
        double localWeight = Math.min(distance, 180);
        red += ((rgb >> 16) & 0xFF) * localWeight;
        green += ((rgb >> 8) & 0xFF) * localWeight;
        blue += (rgb & 0xFF) * localWeight;
        weight += localWeight;
      }
    }
    if (weight <= 0) return fallback;
    return ((clamp((int) Math.round(red / weight), 0, 255) & 0xFF) << 16)
        | ((clamp((int) Math.round(green / weight), 0, 255) & 0xFF) << 8)
        | (clamp((int) Math.round(blue / weight), 0, 255) & 0xFF);
  }

  private static int sampleBackground(BufferedImage image, PDRectangle pageBox, Line line) {
    double cx = (line.left + line.width / 2) / pageBox.getWidth();
    double cy = (line.top + line.height / 2) / pageBox.getHeight();
    double[][] points = {
      {line.left / pageBox.getWidth(), line.top / pageBox.getHeight()},
      {cx, Math.max(0, line.top / pageBox.getHeight() - 0.012)},
      {Math.min(1, (line.left + line.width) / pageBox.getWidth() + 0.01), cy},
      {cx, Math.min(1, (line.top + line.height) / pageBox.getHeight() + 0.012)}
    };
    int red = 0;
    int green = 0;
    int blue = 0;
    for (double[] point : points) {
      int x = clamp((int) Math.round(point[0] * (image.getWidth() - 1)), 0, image.getWidth() - 1);
      int y = clamp((int) Math.round(point[1] * (image.getHeight() - 1)), 0, image.getHeight() - 1);
      int rgb = image.getRGB(x, y) & 0x00FFFFFF;
      red += (rgb >> 16) & 0xFF;
      green += (rgb >> 8) & 0xFF;
      blue += rgb & 0xFF;
    }
    int r = (int) Math.round(red / points.length);
    int g = (int) Math.round(green / points.length);
    int b = (int) Math.round(blue / points.length);
    return (r << 16) | (g << 8) | b;
  }

  private static double colorDistance(int a, int b) {
    int dr = ((a >> 16) & 0xFF) - ((b >> 16) & 0xFF);
    int dg = ((a >> 8) & 0xFF) - ((b >> 8) & 0xFF);
    int db = (a & 0xFF) - (b & 0xFF);
    return Math.sqrt(dr * dr + dg * dg + db * db);
  }

  private static int clamp(int value, int min, int max) {
    return Math.max(min, Math.min(max, value));
  }

  private static final class StyleStripper extends PDFTextStripper {
    final List<TextChar> characters = new ArrayList<>();
    final List<Integer> glyphColors = new ArrayList<>();

    StyleStripper() throws IOException {}

    @Override
    protected void showGlyph(
        Matrix textRenderingMatrix, PDFont font, int code, String unicode, Vector displacement)
        throws IOException {
      glyphColors.add(currentTextColor());
      super.showGlyph(textRenderingMatrix, font, code, unicode, displacement);
    }

    @Override
    protected void processTextPosition(TextPosition text) {
      String value = text.getUnicode();
      if (value == null || value.isEmpty()) return;
      int color = glyphColors.isEmpty() ? currentTextColor() : glyphColors.remove(0);
      characters.add(
          new TextChar(
              value,
              text.getXDirAdj(),
              text.getYDirAdj(),
              text.getWidthDirAdj(),
              text.getHeightDir(),
              text.getFontSizeInPt(),
              text.getYScale(),
              text.getFont() == null ? "unknown" : text.getFont().getName(),
              color));
    }

    private int currentTextColor() {
      try {
        PDColor color =
            getGraphicsState().getTextState().getRenderingMode().isFill()
                ? getGraphicsState().getNonStrokingColor()
                : getGraphicsState().getStrokingColor();
        return color.toRGB() & 0x00FFFFFF;
      } catch (Throwable ignored) {
        return 0;
      }
    }
  }

  private record TextChar(
      String value,
      double x,
      double y,
      double width,
      double height,
      double fontSize,
      double yScale,
      String fontName,
      int rgb) {}

  private record Line(
      String text,
      double left,
      double top,
      double width,
      double height,
      double bottom,
      double fontSize,
      String fontName,
      int rgb) {}

  private record Diff(int changedPixels, int totalPixels, double avgChannelDiff, int maxChannelDiff) {}
}
