import java.awt.Color;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import javax.imageio.ImageIO;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.graphics.color.PDColor;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.pdfbox.text.TextPosition;
import org.apache.pdfbox.util.Matrix;
import org.apache.pdfbox.util.Vector;

public final class PdfStyleAudit {
  public static void main(String[] args) throws Exception {
    if (args.length < 1) {
      System.err.println("Usage: PdfStyleAudit <pdf> [pageIndex] [renderDpi]");
      System.exit(2);
    }

    File pdf = new File(args[0]);
    int pageIndex = args.length > 1 ? Integer.parseInt(args[1]) : 0;
    int dpi = args.length > 2 ? Integer.parseInt(args[2]) : 180;

    try (PDDocument document = PDDocument.load(pdf)) {
      PDPage page = document.getPage(pageIndex);
      PDRectangle media = page.getMediaBox();
      PDRectangle crop = page.getCropBox();
      System.out.printf(
          Locale.US,
          "DOC pages=%d page=%d media=%.2fx%.2f crop=%.2fx%.2f userUnit=%.4f%n",
          document.getNumberOfPages(),
          pageIndex,
          media.getWidth(),
          media.getHeight(),
          crop.getWidth(),
          crop.getHeight(),
          page.getUserUnit());

      StyleStripper stripper = new StyleStripper();
      stripper.setSortByPosition(true);
      stripper.setStartPage(pageIndex + 1);
      stripper.setEndPage(pageIndex + 1);
      stripper.getText(document);

      List<List<TextChar>> lines = groupLines(stripper.characters);
      for (int i = 0; i < Math.min(lines.size(), 80); i++) {
        List<TextChar> line = lines.get(i);
        line.sort(Comparator.comparingDouble(c -> c.x));
        String text = buildLineText(line);
        if (text.isBlank()) continue;

        double left = line.stream().mapToDouble(c -> c.x).min().orElse(0);
        double right = line.stream().mapToDouble(c -> c.x + c.width).max().orElse(0);
        double top = line.stream().mapToDouble(c -> c.y - c.heightDir).min().orElse(0);
        double bottom = line.stream().mapToDouble(c -> c.y).max().orElse(0);
        System.out.printf(
            Locale.US,
            "LINE %03d text=\"%s\" font=%s rgb=#%06X fontPt=%.4f fontRaw=%.4f yScale=%.4f xScale=%.4f height=%.4f heightDir=%.4f box=[%.2f %.2f %.2f %.2f]%n",
            i,
            clean(text),
            dominantFont(line),
            dominantColor(line),
            median(line.stream().mapToDouble(c -> c.fontSizeInPt).sorted().toArray()),
            median(line.stream().mapToDouble(c -> c.fontSize).sorted().toArray()),
            median(line.stream().mapToDouble(c -> c.yScale).sorted().toArray()),
            median(line.stream().mapToDouble(c -> c.xScale).sorted().toArray()),
            median(line.stream().mapToDouble(c -> c.height).sorted().toArray()),
            median(line.stream().mapToDouble(c -> c.heightDir).sorted().toArray()),
            left,
            top,
            right - left,
            bottom - top);
      }

      PDFRenderer renderer = new PDFRenderer(document);
      BufferedImage image = renderer.renderImageWithDPI(pageIndex, dpi, ImageType.RGB);
      File out = new File("tools/out/audit-page-" + pageIndex + "-" + dpi + "dpi.png");
      ImageIO.write(image, "png", out);
      System.out.println("RENDER " + out.getAbsolutePath());
    }
  }

  private static List<List<TextChar>> groupLines(List<TextChar> chars) {
    chars.sort(Comparator.comparingDouble((TextChar c) -> c.y).thenComparingDouble(c -> c.x));
    List<List<TextChar>> lines = new ArrayList<>();
    for (TextChar ch : chars) {
      if (ch.value.isBlank()) continue;
      List<TextChar> current = lines.isEmpty() ? null : lines.get(lines.size() - 1);
      if (current == null) {
        current = new ArrayList<>();
        lines.add(current);
        current.add(ch);
        continue;
      }
      double currentY = current.stream().mapToDouble(c -> c.y).average().orElse(ch.y);
      double currentSize = current.stream().mapToDouble(c -> c.fontSizeInPt).max().orElse(12);
      double threshold = Math.max(2.0, Math.max(ch.fontSizeInPt, currentSize) * 0.46);
      if (Math.abs(ch.y - currentY) <= threshold) {
        current.add(ch);
      } else {
        current = new ArrayList<>();
        lines.add(current);
        current.add(ch);
      }
    }
    return lines;
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
      previousFontSize = ch.fontSizeInPt;
    }
    return builder.toString().replaceAll("\\s+", " ").trim();
  }

  private static String dominantFont(List<TextChar> chars) {
    return chars.stream()
        .map(c -> c.fontName == null ? "unknown" : c.fontName)
        .reduce((a, b) -> count(chars, a) >= count(chars, b) ? a : b)
        .orElse("unknown");
  }

  private static int count(List<TextChar> chars, String font) {
    int total = 0;
    for (TextChar ch : chars) {
      String value = ch.fontName == null ? "unknown" : ch.fontName;
      if (value.equals(font)) total++;
    }
    return total;
  }

  private static int dominantColor(List<TextChar> chars) {
    int bestColor = 0;
    int bestCount = -1;
    for (TextChar ch : chars) {
      int count = 0;
      for (TextChar other : chars) {
        if (other.rgb == ch.rgb) count++;
      }
      if (count > bestCount) {
        bestCount = count;
        bestColor = ch.rgb;
      }
    }
    return bestColor;
  }

  private static double median(double[] sorted) {
    if (sorted.length == 0) return 0;
    int middle = sorted.length / 2;
    if (sorted.length % 2 == 0) {
      return (sorted[middle - 1] + sorted[middle]) / 2.0;
    }
    return sorted[middle];
  }

  private static String clean(String text) {
    return text.replace("\\", "\\\\").replace("\"", "\\\"");
  }

  private static final class StyleStripper extends PDFTextStripper {
    final List<TextChar> characters = new ArrayList<>();
    final List<Integer> glyphColors = new ArrayList<>();

    StyleStripper() throws IOException {}

    @Override
    protected void showGlyph(
        Matrix textRenderingMatrix, org.apache.pdfbox.pdmodel.font.PDFont font, int code, String unicode, Vector displacement)
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
              text.getHeight(),
              text.getHeightDir(),
              text.getFontSize(),
              text.getFontSizeInPt(),
              text.getXScale(),
              text.getYScale(),
              text.getFont() == null ? null : text.getFont().getName(),
              color));
    }

    private int currentTextColor() {
      try {
        PDColor color = getGraphicsState().getNonStrokingColor();
        return color.toRGB() & 0x00FFFFFF;
      } catch (Throwable ignored) {
        return Color.BLACK.getRGB() & 0x00FFFFFF;
      }
    }
  }

  private record TextChar(
      String value,
      double x,
      double y,
      double width,
      double height,
      double heightDir,
      double fontSize,
      double fontSizeInPt,
      double xScale,
      double yScale,
      String fontName,
      int rgb) {}
}
