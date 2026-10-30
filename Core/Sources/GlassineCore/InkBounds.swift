import CoreGraphics

/// Where a PDF page has visible ink, measured by rasterising it.
///
/// A copy of the CoreGraphics half of the Mac's `ReaderContentBounds.detect`
/// (Reader Mode's margin detector), brought into Core so iOS can use it
/// without the Mac target changing. The two are meant to become one routine;
/// until then a fix to either belongs in both. What is left out is only the
/// PDFKit half -- reading a `PDFPage`'s live annotations on the main actor --
/// which the iOS caller, a WebKit print with no annotations, does not need.
///
/// Bounds are in unrotated PDF page coordinates. Rasterising the CGPDFPage
/// directly avoids PDFKit's rotation and box-origin transforms; annotation
/// rectangles are supplied separately because CoreGraphics does not draw
/// PDFKit's live annotations.
public enum InkBounds {
    public static let maximumRasterDimension = 1_200
    /// The coarsest raster `detect` accepts. Together with
    /// `maximumRasterDimension` it caps how tall a region one call can measure.
    public static let minimumPixelsPerPoint: CGFloat = 0.25
    private static let maximumAnnotationCount = 10_000
    private static let maximumPixelsPerPoint: CGFloat = 2
    private static let whiteThreshold: UInt8 = 252
    private static let safetyPixels: CGFloat = 2

    /// Returns the union of visible ink and annotations inside `cropBox`.
    /// `nil` means blank, invalid, or too uncertain to measure. A full-region
    /// result deliberately keeps all edges.
    ///
    /// The bitmap is at most 1,200 × 1,200 RGBA pixels (5.76 MB). Regions too
    /// large or too narrow to rasterise at a useful resolution return nil.
    /// Near-white noise counts as ink rather than being guessed away; tinted
    /// or dark paper therefore reads as ink everywhere.
    public static func detect(pageRef: CGPDFPage, cropBox: CGRect,
                              annotationBounds: [CGRect] = []) -> CGRect? {
        guard valid(cropBox), annotationBounds.count <= maximumAnnotationCount else { return nil }
        let crop = cropBox.intersection(pageRef.getBoxRect(.mediaBox))
        guard valid(crop) else { return nil }

        let scale = min(maximumPixelsPerPoint,
                        CGFloat(maximumRasterDimension) / max(crop.width, crop.height))
        guard scale >= minimumPixelsPerPoint else { return nil }
        // The longest side can round a fraction above 1,200 before ceil
        // (for example at 1,101 pt). Clamp that numerical overshoot instead
        // of silently declining an otherwise ordinary page size.
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

    /// The lowest point of ink on a page taller than one `detect` call can
    /// rasterise, or nil if the page is blank.
    ///
    /// The page is measured in horizontal bands from the bottom up, and the
    /// first band with any ink answers, so the cost is proportional to the
    /// blank tail rather than to the page: a 14,400 pt sheet whose text ends
    /// near the top is a handful of small rasters. `bandHeight` trades
    /// resolution for calls (2,400 pt measures at 0.5 px/pt).
    public static func lowestInk(pageRef: CGPDFPage, in box: CGRect,
                                 bandHeight: CGFloat = 2_400) -> CGFloat? {
        guard valid(box), bandHeight > 0 else { return nil }
        let crop = box.intersection(pageRef.getBoxRect(.mediaBox))
        guard valid(crop) else { return nil }
        var bandBottom = crop.minY
        while bandBottom < crop.maxY {
            let top = min(bandBottom + bandHeight, crop.maxY)
            let band = CGRect(x: crop.minX, y: bandBottom, width: crop.width,
                              height: top - bandBottom)
            if let ink = detect(pageRef: pageRef, cropBox: band) { return ink.minY }
            bandBottom = top
        }
        return nil
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
