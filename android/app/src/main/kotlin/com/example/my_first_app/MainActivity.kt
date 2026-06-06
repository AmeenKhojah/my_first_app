package com.example.my_first_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.font.PDType0Font
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import com.tom_roush.pdfbox.util.Matrix
import com.tom_roush.pdfbox.util.Vector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

class MainActivity : FlutterActivity() {
    private var pendingPickResult: MethodChannel.Result? = null
    private val pdfExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PDFBoxResourceLoader.init(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "pickPdf" -> startPdfPicker(result)
                    "pickImage" -> startImagePicker(result)
                    "openPdf" -> {
                        val path = requireNotNull(call.argument<String>("path"))
                        result.success(openPdf(path))
                    }
                    "extractTextBlocks" -> {
                        val path = requireNotNull(call.argument<String>("path"))
                        val pageIndex = call.argument<Int>("pageIndex") ?: 0
                        pdfExecutor.execute {
                            try {
                                val blocks = extractTextBlocks(path, pageIndex)
                                runOnUiThread { result.success(blocks) }
                            } catch (error: Throwable) {
                                runOnUiThread {
                                    result.error("PDF_ERROR", error.message, error.stackTraceToString())
                                }
                            }
                        }
                    }
                    "exportPdf" -> {
                        val sourcePath = requireNotNull(call.argument<String>("sourcePath"))
                        val outputPath = requireNotNull(call.argument<String>("outputPath"))
                        val annotations = call.argument<List<Map<String, Any?>>>("annotations") ?: emptyList()
                        pdfExecutor.execute {
                            try {
                                val exportPath = exportPdf(sourcePath, outputPath, annotations)
                                runOnUiThread { result.success(exportPath) }
                            } catch (error: Throwable) {
                                runOnUiThread {
                                    result.error("PDF_ERROR", error.message, error.stackTraceToString())
                                }
                            }
                        }
                    }
                    "sharePdf" -> {
                        val path = requireNotNull(call.argument<String>("path"))
                        sharePdf(path)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Throwable) {
                result.error("PDF_ERROR", error.message, error.stackTraceToString())
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_PDF || requestCode == REQUEST_PICK_IMAGE) {
            val pending = pendingPickResult
            pendingPickResult = null
            if (pending == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }

            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                pending.success(null)
                return
            }

            try {
                pending.success(copyPickedFile(data.data!!, requestCode == REQUEST_PICK_IMAGE))
            } catch (error: Throwable) {
                pending.error("PICK_ERROR", error.message, error.stackTraceToString())
            }
            return
        }

        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun startPdfPicker(result: MethodChannel.Result) {
        startPicker(result, "application/pdf", "Choose PDF", REQUEST_PICK_PDF)
    }

    private fun startImagePicker(result: MethodChannel.Result) {
        startPicker(result, "image/*", "Choose image", REQUEST_PICK_IMAGE)
    }

    private fun startPicker(
        result: MethodChannel.Result,
        mimeType: String,
        title: String,
        requestCode: Int,
    ) {
        if (pendingPickResult != null) {
            result.error("PICK_ACTIVE", "A file picker is already open.", null)
            return
        }

        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
        }
        try {
            startActivityForResult(Intent.createChooser(intent, title), requestCode)
        } catch (error: Throwable) {
            pendingPickResult = null
            result.error("PICK_ERROR", error.message, error.stackTraceToString())
        }
    }

    private fun copyPickedFile(uri: Uri, image: Boolean): Map<String, Any> {
        val displayName = queryDisplayName(uri)
            ?: if (image) "image-${System.currentTimeMillis()}.png" else "document-${System.currentTimeMillis()}.pdf"
        val safeName = displayName.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val target = File(cacheDir, "picked-${System.currentTimeMillis()}-$safeName")

        val input = requireNotNull(contentResolver.openInputStream(uri)) {
            "Could not open the selected PDF."
        }
        input.use { source ->
            target.outputStream().use { destination ->
                source.copyTo(destination)
            }
        }

        return mapOf("path" to target.absolutePath, "name" to safeName)
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null).use { cursor ->
            if (cursor == null || !cursor.moveToFirst()) return null
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            return if (index >= 0) cursor.getString(index) else null
        }
    }

    private fun openPdf(path: String): Map<String, Any> {
        PDDocument.load(File(path)).use { document ->
            val sizes = (0 until document.numberOfPages).map { index ->
                val box = document.getPage(index).mediaBox
                mapOf(
                    "width" to box.width.toDouble(),
                    "height" to box.height.toDouble(),
                )
            }
            return mapOf(
                "pageCount" to document.numberOfPages,
                "pageSizes" to sizes,
            )
        }
    }

    private fun extractTextBlocks(path: String, pageIndex: Int): List<Map<String, Any>> {
        PDDocument.load(File(path)).use { document ->
            if (pageIndex !in 0 until document.numberOfPages) return emptyList()
            val page = document.getPage(pageIndex)
            val box = page.mediaBox
            val stripper = PositionTextStripper()
            stripper.sortByPosition = true
            stripper.startPage = pageIndex + 1
            stripper.endPage = pageIndex + 1
            stripper.getText(document)

            return groupTextLines(stripper.characters, pageIndex, box.width.toDouble(), box.height.toDouble())
        }
    }

    private fun groupTextLines(
        characters: List<TextChar>,
        pageIndex: Int,
        pageWidth: Double,
        pageHeight: Double,
    ): List<Map<String, Any>> {
        val sorted = characters
            .filter { it.value.isNotEmpty() }
            .sortedWith(compareBy<TextChar> { it.y }.thenBy { it.x })

        val lines = mutableListOf<MutableList<TextChar>>()
        for (char in sorted) {
            val current = lines.lastOrNull()
            if (current == null) {
                lines.add(mutableListOf(char))
                continue
            }

            val currentY = current.map { it.y }.average()
            val threshold = max(2.0, max(char.fontSize, current.maxOf { it.fontSize }) * 0.46)
            if (abs(char.y - currentY) <= threshold) {
                current.add(char)
            } else {
                lines.add(mutableListOf(char))
            }
        }

        return lines.flatMapIndexed { lineIndex, line ->
            splitTextRuns(line.sortedBy { it.x }).mapIndexedNotNull { runIndex, ordered ->
            val left = ordered.minOf { it.x }
            val right = ordered.maxOf { it.x + it.width }
            val fontSize = dominantFontSize(ordered)
            val top = ordered.minOf { it.y - it.height }.coerceAtLeast(0.0)
            val bottom = ordered.maxOf { it.y }.coerceAtMost(pageHeight)
            val height = (bottom - top).coerceAtLeast(1.0)
            val width = (right - left).coerceAtLeast(1.0)
            val text = buildLineText(ordered)
            if (text.isBlank()) return@mapIndexedNotNull null

            mapOf(
                    "id" to "p$pageIndex-l$lineIndex-r$runIndex",
                "pageIndex" to pageIndex,
                "text" to text,
                "bounds" to mapOf(
                    "left" to (left / pageWidth).coerceIn(0.0, 1.0),
                    "top" to (top / pageHeight).coerceIn(0.0, 1.0),
                    "width" to (width / pageWidth).coerceIn(0.002, 1.0),
                    "height" to (height / pageHeight).coerceIn(0.002, 1.0),
                ),
                "fontSize" to fontSize,
                "visualFontSize" to dominantVisualFontSize(ordered),
                "fontFamily" to dominantFontFamily(ordered),
                "color" to dominantColor(ordered),
                "editable" to true,
            )
            }
        }
    }

    private fun splitTextRuns(chars: List<TextChar>): List<List<TextChar>> {
        if (chars.isEmpty()) return emptyList()

        val runs = mutableListOf<MutableList<TextChar>>()
        var current = mutableListOf(chars.first())
        var previous = chars.first()

        for (char in chars.drop(1)) {
            val gap = char.x - (previous.x + previous.width)
            val splitGap = max(24.0, previous.fontSize * 1.8)
            if (gap > splitGap) {
                runs.add(current)
                current = mutableListOf()
            }
            current.add(char)
            previous = char
        }

        runs.add(current)
        return runs
    }

    private fun dominantFontFamily(chars: List<TextChar>): String {
        return chars
            .map { it.fontName ?: "Roboto" }
            .groupingBy { it }
            .eachCount()
            .maxByOrNull { it.value }
            ?.key ?: "Roboto"
    }

    private fun dominantFontSize(chars: List<TextChar>): Double {
        val sizes = chars
            .map { it.fontSize }
            .filter { it in 0.5..300.0 }
            .sorted()
        if (sizes.isEmpty()) return 12.0

        val middle = sizes.size / 2
        return if (sizes.size % 2 == 0) {
            (sizes[middle - 1] + sizes[middle]) / 2.0
        } else {
            sizes[middle]
        }
    }

    private fun dominantVisualFontSize(chars: List<TextChar>): Double {
        val sizes = chars
            .map { it.yScale }
            .filter { it in 0.5..300.0 }
            .sorted()
        if (sizes.isEmpty()) return dominantFontSize(chars)

        val middle = sizes.size / 2
        return if (sizes.size % 2 == 0) {
            (sizes[middle - 1] + sizes[middle]) / 2.0
        } else {
            sizes[middle]
        }
    }

    private fun dominantColor(chars: List<TextChar>): Long {
        return chars
            .groupingBy { it.color }
            .eachCount()
            .maxByOrNull { it.value }
            ?.key ?: 0xFF000000L
    }

    private fun buildLineText(chars: List<TextChar>): String {
        val builder = StringBuilder()
        var previousRight: Double? = null
        var previousFontSize = 12.0

        for (char in chars) {
            val gap = previousRight?.let { char.x - it } ?: 0.0
            val wordGap = max(0.8, previousFontSize * 0.08)
            if (gap > wordGap && builder.isNotEmpty() && !builder.endsWith(" ")) {
                builder.append(' ')
            }
            builder.append(char.value)
            previousRight = char.x + char.width
            previousFontSize = char.fontSize
        }

        return builder.toString().replace(Regex("\\s+"), " ").trim()
    }

    private fun exportPdf(
        sourcePath: String,
        outputPath: String,
        annotations: List<Map<String, Any?>>,
    ): String {
        val output = File(outputPath)
        output.parentFile?.mkdirs()

        PDDocument.load(File(sourcePath)).use { document ->
            val fonts = mutableMapOf<String, PDFont>()
            val grouped = annotations.groupBy { number(it["pageIndex"]).toInt() }

            for ((pageIndex, pageAnnotations) in grouped) {
                if (pageIndex !in 0 until document.numberOfPages) continue
                val page = document.getPage(pageIndex)
                PDPageContentStream(
                    document,
                    page,
                    PDPageContentStream.AppendMode.APPEND,
                    true,
                    true,
                ).use { stream ->
                    for (annotation in pageAnnotations) {
                        when (annotation["type"] as? String) {
                            "textReplacement" -> {
                                paintCover(stream, page, annotation)
                                paintText(stream, document, page, annotation, fonts)
                            }
                            "textOverlay" -> paintText(stream, document, page, annotation, fonts)
                            "image" -> paintImage(stream, document, page, annotation)
                            "highlight" -> paintHighlight(stream, page, annotation)
                            "ink", "signature" -> paintInk(stream, page, annotation)
                        }
                    }
                }
            }

            document.save(output)
        }

        return output.absolutePath
    }

    private fun paintCover(
        stream: PDPageContentStream,
        page: PDPage,
        annotation: Map<String, Any?>,
    ) {
        val rect = pdfRect(page, annotation)
        val cover = color(annotation["backgroundColor"], default = PdfColor(255, 255, 255))
        stream.setNonStrokingColor(cover.r, cover.g, cover.b)
        stream.addRect(
            (rect.left - 1.4).toFloat(),
            (rect.bottom - 1.4).toFloat(),
            (rect.width + 2.8).toFloat(),
            (rect.height + 2.8).toFloat(),
        )
        stream.fill()
    }

    private fun paintText(
        stream: PDPageContentStream,
        document: PDDocument,
        page: PDPage,
        annotation: Map<String, Any?>,
        fonts: MutableMap<String, PDFont>,
    ) {
        val text = (annotation["text"] as? String)?.replace("\r", "") ?: return
        if (text.isBlank()) return

        val rect = pdfRect(page, annotation)
        val fontSize = number(annotation["fontSize"], 14.0).coerceIn(1.0, 144.0).toFloat()
        val family = annotation["fontFamily"] as? String ?: "Sans"
        val font = fonts.getOrPut("$page:$family:$text") {
            resolveFont(document, page, family, text)
        }
        val color = color(annotation["color"])

        stream.setNonStrokingColor(color.r, color.g, color.b)
        val lines = text.split('\n').map { it.trimEnd() }.ifEmpty { listOf(text) }
        val safeLines = lines.map { safePdfText(font, it) }
        if (safeLines.all { it.isBlank() }) return

        stream.beginText()
        stream.setFont(font, fontSize)
        val baseline = rect.bottom
        stream.newLineAtOffset(rect.left.toFloat(), baseline.toFloat())

        for ((index, line) in safeLines.withIndex()) {
            if (index > 0) stream.newLineAtOffset(0f, -fontSize * 1.18f)
            if (line.isNotBlank()) {
                stream.showText(line)
            }
        }

        stream.endText()
    }

    private fun safePdfText(font: PDFont, raw: String): String {
        val builder = StringBuilder()
        for (char in raw.replace("\u25CF", "\u2022")) {
            val candidate = when {
                char.code < 32 -> ' '
                char == '\u25CF' -> '\u2022'
                else -> char
            }
            val text = candidate.toString()
            if (canEncode(font, text)) {
                builder.append(candidate)
            } else if (candidate != '?' && canEncode(font, "?")) {
                builder.append('?')
            } else if (canEncode(font, " ")) {
                builder.append(' ')
            }
        }
        return builder.toString()
    }

    private fun canEncode(font: PDFont, text: String): Boolean {
        return try {
            font.encode(text)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun paintImage(
        stream: PDPageContentStream,
        document: PDDocument,
        page: PDPage,
        annotation: Map<String, Any?>,
    ) {
        val imagePath = annotation["imagePath"] as? String ?: return
        val imageFile = File(imagePath)
        if (!imageFile.exists()) return
        val rect = pdfRect(page, annotation)
        val image = PDImageXObject.createFromFile(imageFile.absolutePath, document)
        stream.drawImage(
            image,
            rect.left.toFloat(),
            rect.bottom.toFloat(),
            rect.width.toFloat(),
            rect.height.toFloat(),
        )
    }

    private fun paintHighlight(
        stream: PDPageContentStream,
        page: PDPage,
        annotation: Map<String, Any?>,
    ) {
        val rect = pdfRect(page, annotation)
        val color = color(annotation["color"], default = PdfColor(255, 228, 154))
        stream.setNonStrokingColor(color.r, color.g, color.b)
        stream.addRect(rect.left.toFloat(), rect.bottom.toFloat(), rect.width.toFloat(), rect.height.toFloat())
        stream.fill()
    }

    private fun paintInk(
        stream: PDPageContentStream,
        page: PDPage,
        annotation: Map<String, Any?>,
    ) {
        val points = annotation["points"] as? List<Map<String, Any?>> ?: return
        if (points.size < 2) return

        val box = page.mediaBox
        val color = color(annotation["color"])
        val strokeWidth = number(annotation["strokeWidth"], 2.2).coerceIn(0.4, 18.0).toFloat()

        stream.setStrokingColor(color.r, color.g, color.b)
        stream.setLineWidth(strokeWidth)
        stream.setLineJoinStyle(1)
        stream.setLineCapStyle(1)

        val first = points.first()
        stream.moveTo(
            (number(first["x"]) * box.width).toFloat(),
            (box.height - number(first["y"]) * box.height).toFloat(),
        )
        for (point in points.drop(1)) {
            stream.lineTo(
                (number(point["x"]) * box.width).toFloat(),
                (box.height - number(point["y"]) * box.height).toFloat(),
            )
        }
        stream.stroke()
    }

    private fun sharePdf(path: String) {
        val source = File(path)
        val shareFile = File(cacheDir, source.name)
        source.copyTo(shareFile, overwrite = true)
        val uri = FileProvider.getUriForFile(this, "${applicationContext.packageName}.fileprovider", shareFile)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "application/pdf"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "Share PDF"))
    }

    private fun pdfRect(page: PDPage, annotation: Map<String, Any?>): PdfRect {
        val bounds = annotation["bounds"] as? Map<String, Any?> ?: emptyMap()
        val box = page.mediaBox
        val left = number(bounds["left"]).coerceIn(0.0, 1.0) * box.width
        val top = number(bounds["top"]).coerceIn(0.0, 1.0) * box.height
        val width = number(bounds["width"], 0.1).coerceIn(0.001, 1.0) * box.width
        val height = number(bounds["height"], 0.05).coerceIn(0.001, 1.0) * box.height
        val bottom = box.height - top - height
        return PdfRect(left, bottom, width, height)
    }

    private fun resolveFont(
        document: PDDocument,
        page: PDPage,
        family: String,
        text: String,
    ): PDFont {
        findEmbeddedFont(page, family)?.let { font ->
            if (canEncode(font, text)) return font
        }

        val normalized = fontFamilyName(family)
        val candidates = when (normalized) {
            "Noto Serif" -> listOf(
                "/system/fonts/NotoSerif-Regular.ttf",
                "/system/fonts/RobotoSerif-Regular.ttf",
                "/system/fonts/Roboto-Regular.ttf",
                "/system/fonts/DroidSansFallback.ttf",
            )
            "Roboto Mono" -> listOf(
                "/system/fonts/RobotoMono-Regular.ttf",
                "/system/fonts/DroidSansMono.ttf",
                "/system/fonts/Roboto-Regular.ttf",
                "/system/fonts/DroidSansFallback.ttf",
            )
            "Noto Sans" -> listOf(
                "/system/fonts/NotoSans-Regular.ttf",
                "/system/fonts/Roboto-Regular.ttf",
                "/system/fonts/NotoNaskhArabic-Regular.ttf",
                "/system/fonts/DroidSansFallback.ttf",
            )
            else -> listOf(
                "/system/fonts/Roboto-Regular.ttf",
                "/system/fonts/NotoSans-Regular.ttf",
                "/system/fonts/NotoNaskhArabic-Regular.ttf",
                "/system/fonts/DroidSansFallback.ttf",
            )
        }

        for (path in candidates) {
            val file = File(path)
            if (file.exists()) {
                return PDType0Font.load(document, file)
            }
        }

        return when (normalized) {
            "Noto Serif" -> PDType1Font.TIMES_ROMAN
            "Roboto Mono" -> PDType1Font.COURIER
            else -> PDType1Font.HELVETICA
        }
    }

    private fun findEmbeddedFont(page: PDPage, family: String): PDFont? {
        val resources = page.resources ?: return null
        val requested = family.substringAfter('+')
        for (name in resources.fontNames) {
            val font = try {
                resources.getFont(name)
            } catch (_: Throwable) {
                null
            } ?: continue

            val fontName = font.name ?: continue
            if (fontName == family || fontName.substringAfter('+') == requested) {
                return font
            }
        }
        return null
    }

    private fun fontFamilyName(fontName: String?): String {
        val original = fontName ?: return "Roboto"
        val name = original.lowercase()
        return when {
            "courier" in name || "mono" in name -> "Roboto Mono"
            "times" in name || "serif" in name || "georgia" in name -> "Noto Serif"
            "roboto" in name -> "Roboto"
            "noto" in name -> "Noto Sans"
            "arial" in name || "helvetica" in name || "sans" in name -> "Roboto"
            else -> original.substringAfter('+').replace('-', ' ')
        }
    }

    private fun color(value: Any?, default: PdfColor = PdfColor(45, 38, 32)): PdfColor {
        val raw = (value as? Number)?.toLong() ?: return default
        return PdfColor(
            r = ((raw shr 16) and 0xFF).toInt(),
            g = ((raw shr 8) and 0xFF).toInt(),
            b = (raw and 0xFF).toInt(),
        )
    }

    private fun number(value: Any?, default: Double = 0.0): Double {
        return (value as? Number)?.toDouble() ?: default
    }

    private class PositionTextStripper : PDFTextStripper() {
        val characters = mutableListOf<TextChar>()
        private val glyphColors = ArrayDeque<Long>()

        override fun showGlyph(
            textRenderingMatrix: Matrix,
            font: PDFont,
            code: Int,
            unicode: String,
            displacement: Vector,
        ) {
            glyphColors.addLast(currentTextColor())
            super.showGlyph(textRenderingMatrix, font, code, unicode, displacement)
        }

        override fun processTextPosition(text: TextPosition) {
            val value = text.unicode ?: return
            if (value.isEmpty()) return
            val color = if (glyphColors.isEmpty()) currentTextColor() else glyphColors.removeFirst()
            characters.add(
                TextChar(
                    value = value,
                    x = text.xDirAdj.toDouble(),
                    y = text.yDirAdj.toDouble(),
                    width = text.widthDirAdj.toDouble(),
                    height = text.heightDir.toDouble(),
                    fontSize = text.yScale.toDouble(),
                    yScale = text.yScale.toDouble(),
                    fontName = text.font?.name,
                    color = color,
                )
            )
        }

        private fun currentTextColor(): Long {
            return try {
                val mode = graphicsState.textState.renderingMode
                val pdfColor = if (mode.isFill) {
                    graphicsState.nonStrokingColor
                } else {
                    graphicsState.strokingColor
                }
                val rgb = pdfColor.toRGB()
                0xFF000000L or (rgb.toLong() and 0x00FFFFFFL)
            } catch (_: Throwable) {
                0xFF000000L
            }
        }
    }

    private data class TextChar(
        val value: String,
        val x: Double,
        val y: Double,
        val width: Double,
        val height: Double,
        val fontSize: Double,
        val yScale: Double,
        val fontName: String?,
        val color: Long,
    )

    private data class PdfRect(
        val left: Double,
        val bottom: Double,
        val width: Double,
        val height: Double,
    )

    private data class PdfColor(val r: Int, val g: Int, val b: Int)

    companion object {
        private const val CHANNEL = "warm_pdf_editor/pdf"
        private const val REQUEST_PICK_PDF = 4501
        private const val REQUEST_PICK_IMAGE = 4502
    }
}
