import java.io.File;
import java.io.IOException;
import java.util.Locale;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.graphics.color.PDColor;
import org.apache.pdfbox.pdmodel.graphics.state.RenderingMode;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.pdfbox.text.TextPosition;
import org.apache.pdfbox.util.Matrix;
import org.apache.pdfbox.util.Vector;

public final class PdfColorProbe {
  public static void main(String[] args) throws Exception {
    try (PDDocument document = PDDocument.load(new File(args[0]))) {
      Probe probe = new Probe();
      probe.setStartPage(1);
      probe.setEndPage(1);
      probe.getText(document);
    }
  }

  private static final class Probe extends PDFTextStripper {
    int count = 0;

    Probe() throws IOException {}

    @Override
    protected void showGlyph(
        Matrix textRenderingMatrix,
        org.apache.pdfbox.pdmodel.font.PDFont font,
        int code,
        String unicode,
        Vector displacement)
        throws IOException {
      if (unicode != null && !unicode.isBlank() && count < 25) {
        PDColor fill = getGraphicsState().getNonStrokingColor();
        PDColor stroke = getGraphicsState().getStrokingColor();
        RenderingMode mode = getGraphicsState().getTextState().getRenderingMode();
        System.out.printf(
            Locale.US,
            "GLYPH %s mode=%s fill=%s fillRGB=#%06X stroke=%s strokeRGB=#%06X alpha=%.3f%n",
            unicode,
            mode,
            fill,
            safeRgb(fill),
            stroke,
            safeRgb(stroke),
            getGraphicsState().getNonStrokeAlphaConstant());
        count++;
      }
      super.showGlyph(textRenderingMatrix, font, code, unicode, displacement);
    }

    @Override
    protected void processTextPosition(TextPosition text) {}

    private static int safeRgb(PDColor color) {
      try {
        return color.toRGB() & 0x00FFFFFF;
      } catch (Throwable ignored) {
        return -1;
      }
    }
  }
}
