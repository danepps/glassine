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
    private static let maximumAnnotationCount = 10_000
    private static let minimumPixelsPerPoint: CGFloat = 0.25
    private static let maximumPixelsPerPoint: CGFloat = 2
    private static let whiteThreshold: UInt8 = 252
    private static let safetyPixels: CGFloat = 2

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
    /// The bitmap is at most 1,200 × 1,200 RGBA pixels (5.76 MB). Oversized or
    /// exceptionally narrow pages are left alone when bounded rasterization
    /// would discard too much detail. Near-white scan noise is kept rather
    /// than guessed away; tinted or dark paper may therefore remain untrimmed.
    static func detect(pageRef: CGPDFPage, cropBox: CGRect,
                       annotationBounds: [CGRect] = []) -> CGRect? {
        guard valid(cropBox), annotationBounds.count <= maximumAnnotationCount else { return nil }
        let crop = cropBox.intersection(pageRef.getBoxRect(.mediaBox))
        guard valid(crop) else { return nil }

        let scale = min(maximumPixelsPerPoint,
                        CGFloat(maximumRasterDimension) / max(crop.width, crop.height))
        guard scale >= minimumPixelsPerPoint else { return nil }
        // The longest side can round a fraction above 1,200 before ceil
        // (for example at 1,101 pt). Clamp that numerical overshoot instead
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

        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width {
                let offset = row + x * 4
                // Use every color channel: a pale yellow mark can have white
                // red/green while its blue channel still carries visible ink.
                if pixels[offset] < whiteThreshold || pixels[offset + 1] < whiteThreshold ||
                    pixels[offset + 2] < whiteThreshold {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        var content = CGRect.null
        if maxX >= minX && maxY >= minY {
            // Bitmap rows run top to bottom; PDF user space runs bottom to
            // top. Use the allocated height (including its fractional-point
            // rounding) when mapping back. Include the entire detected pixel
            // and two neighbours so resampling cannot shave an ink edge.
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
