import CoreGraphics
import PDFKit

/// Finds visibly empty outer margins without changing PDF page geometry.
///
/// Bounds are always in unrotated PDF page coordinates. Rasterizing the
/// CGPDFPage directly avoids PDFKit's rotation and box-origin transforms;
/// visible annotation rectangles are supplied separately because CoreGraphics
/// does not draw PDFKit's live annotations.
enum ReaderContentBounds {
    static let maximumRasterDimension = 1_200
    /// Finding a margin needs about two points of precision, not legible
    /// text: a US Letter page becomes a 306 × 396 bitmap, a ninth of the
    /// pixels the old 1,200-pixel raster drew and scanned. Pages longer than
    /// 2,400 points fall back to the 1,200-pixel cap, exactly as before.
    static let detectionPixelsPerPoint: CGFloat = 0.5
    private static let maximumAnnotationCount = 10_000
    private static let minimumPixelsPerPoint: CGFloat = 0.25
    /// A channel is ink when it is darker than 252. Every value from 252 to
    /// 255 has its top six bits set, so one masked compare of the whole RGBA
    /// word tests all three colour channels at once and ignores alpha.
    private static let whiteMask = UInt32(bigEndian: 0xFCFC_FC00)
    private static let safetyPixels: CGFloat = 1

    /// Capture PDFKit state on its owning actor. Background callers should
    /// capture the pageRef, original crop box and annotation bounds themselves,
    /// then use the CoreGraphics-only overload on a serial worker.
    @MainActor
    static func detect(on page: PDFPage, cropBox: CGRect? = nil) -> CGRect? {
        guard let pageRef = page.pageRef else { return nil }
        return detect(pageRef: pageRef, cropBox: cropBox ?? page.bounds(for: .cropBox),
                      annotationBounds: visibleAnnotationBounds(on: page))
    }

    @MainActor
    static func visibleAnnotationBounds(on page: PDFPage) -> [CGRect] {
        guard page.displaysAnnotations else { return [] }
        return page.annotations.filter { annotation in
            // PDFKit adds Popup annotations for note icons. Their nominal
            // rectangles are much larger than the icon, but a closed popup
            // has no page appearance and must not consume the reader margin.
            annotation.shouldDisplay && (annotation.type != "Popup" || annotation.isOpen)
        }.map(\.bounds)
    }

    /// Returns the union of visible ink and annotations inside the original
    /// crop box. `nil` means blank, invalid, or too uncertain to trim: retain
    /// the original page. A full-page result also deliberately keeps all edges.
    ///
    /// The bitmap is drawn at half a pixel per point and is at most 1,200 ×
    /// 1,200 RGBA pixels (5.76 MB). Oversized or
    /// exceptionally narrow pages are left alone when bounded rasterization
    /// would discard too much detail. Near-white scan noise is kept rather
    /// than guessed away; tinted or dark paper may therefore remain untrimmed.
    static func detect(pageRef: CGPDFPage, cropBox: CGRect,
                       annotationBounds: [CGRect] = []) -> CGRect? {
        guard valid(cropBox), annotationBounds.count <= maximumAnnotationCount else { return nil }
        let crop = cropBox.intersection(pageRef.getBoxRect(.mediaBox))
        guard valid(crop) else { return nil }

        let scale = min(detectionPixelsPerPoint,
                        CGFloat(maximumRasterDimension) / max(crop.width, crop.height))
        guard scale >= minimumPixelsPerPoint else { return nil }
        // Past 2,400 pt the longest side can round a fraction above 1,200
        // before ceil (for example at 2,401 pt). Clamp that numerical overshoot instead
        // of silently declining to trim an otherwise ordinary page size.
        let width = min(Int(ceil(crop.width * scale)), maximumRasterDimension)
        let height = min(Int(ceil(crop.height * scale)), maximumRasterDimension)
        guard width >= 32, height >= 32,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                          CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.clip(to: crop)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.drawPDFPage(pageRef)

        let words = data.bindMemory(to: UInt32.self, capacity: width * height)
        return finish(ink: inkBounds(words, width: width, height: height), crop: crop,
                      scale: scale, height: height, annotationBounds: annotationBounds)
    }

    /// The smallest pixel rectangle holding every ink pixel, in bitmap rows
    /// (top to bottom), or `nil` for a blank bitmap. Instead of testing every
    /// pixel, it finds the first and last inked rows, then narrows the left
    /// and right edges row by row, scanning only the columns still outside
    /// the edges found so far. A text page therefore costs roughly its
    /// margins, not its area.
    static func inkBounds(_ words: UnsafeMutablePointer<UInt32>,
                                  width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        @inline(__always) func inked(_ x: Int, _ y: Int) -> Bool {
            words[y * width + x] & whiteMask != whiteMask
        }
        func rowHasInk(_ y: Int) -> Bool {
            for x in 0..<width where inked(x, y) { return true }
            return false
        }
        guard let minY = (0..<height).first(where: rowHasInk),
              let maxY = (minY..<height).reversed().first(where: rowHasInk) else { return nil }
        var minX = width, maxX = -1
        for y in minY...maxY {
            for x in 0..<minX where inked(x, y) {
                minX = x
                break
            }
            // The right edge is narrowed separately: a row whose ink starts
            // inside minX can still reach further right than any row so far.
            var x = width - 1
            while x > maxX {
                if inked(x, y) { maxX = x; break }
                x -= 1
            }
        }
        return maxX >= minX ? (minX, minY, maxX, maxY) : nil
    }

    private static func finish(ink: (minX: Int, minY: Int, maxX: Int, maxY: Int)?,
                               crop: CGRect, scale: CGFloat, height: Int,
                               annotationBounds: [CGRect]) -> CGRect? {
        var content = CGRect.null
        if let (minX, minY, maxX, maxY) = ink {
            // Bitmap rows run top to bottom; PDF user space runs bottom to
            // top. Use the allocated height (including its fractional-point
            // rounding) when mapping back. Include the entire detected pixel
            // and its neighbour so resampling cannot shave an ink edge.
            content = CGRect(x: crop.minX + CGFloat(minX) / scale,
                             y: crop.minY + CGFloat(height - maxY - 1) / scale,
                             width: CGFloat(maxX - minX + 1) / scale,
                             height: CGFloat(maxY - minY + 1) / scale)
                .insetBy(dx: -safetyPixels / scale, dy: -safetyPixels / scale)
        }
        for bounds in annotationBounds {
            guard finite(bounds) else { return nil }
            guard !bounds.isEmpty else { continue }
            let visible = bounds.standardized.intersection(crop)
            if !visible.isNull && !visible.isEmpty {
                content = content.union(visible.insetBy(dx: -safetyPixels / scale,
                                                       dy: -safetyPixels / scale))
            }
        }
        guard !content.isNull else { return nil }
        let result = content.intersection(crop)
        return valid(result) ? result : nil
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite &&
            rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func valid(_ rect: CGRect) -> Bool {
        finite(rect) && rect.width > 0 && rect.height > 0 && !rect.isNull
    }
}
