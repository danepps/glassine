import AppKit
import PDFKit

enum HighlightColor: Int, CaseIterable {
    case yellow, green, blue, pink

    var title: String { ["Yellow", "Green", "Blue", "Pink"][rawValue] }
    // Use portable, full-opacity Zotero colors. PDFKit applies multiply blending;
    // display, thumbnails, print and reopened files all use the same RGB values.
    var color: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1, green: 212 / 255, blue: 0, alpha: 1)
        case .green: return NSColor(srgbRed: 95 / 255, green: 178 / 255, blue: 54 / 255, alpha: 1)
        case .blue: return NSColor(srgbRed: 46 / 255, green: 168 / 255, blue: 229 / 255, alpha: 1)
        case .pink: return NSColor(srgbRed: 229 / 255, green: 110 / 255, blue: 238 / 255, alpha: 1)
        }
    }

    func matches(_ color: NSColor) -> Bool {
        guard let actual = color.usingColorSpace(.sRGB), let expected = self.color.usingColorSpace(.sRGB) else { return false }
        // PDF serialization rounds components; opacity is not a different hue.
        return abs(actual.redComponent - expected.redComponent) < 0.02 &&
            abs(actual.greenComponent - expected.greenComponent) < 0.02 &&
            abs(actual.blueComponent - expected.blueComponent) < 0.02
    }
}

struct SavedHighlight {
    let page: PDFPage
    let annotation: PDFAnnotation
    let text: String
    let readingOrder: Int

    init(page: PDFPage, annotation: PDFAnnotation) {
        self.page = page
        self.annotation = annotation
        let selections = Self.rects(for: annotation).compactMap { page.selection(for: $0) }
        let extracted = selections.compactMap(\.string).joined(separator: " ")
        let passage = extracted.isEmpty ? (annotation.contents ?? "Highlight") : extracted
        text = passage.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        readingOrder = selections.compactMap { selection -> Int? in
            guard selection.numberOfTextRanges(on: page) > 0 else { return nil }
            let range = selection.range(at: 0, on: page)
            return range.location == NSNotFound ? nil : range.location
        }.min() ?? Int.max
    }

    var pageReference: String {
        let number = (page.document?.index(for: page) ?? 0) + 1
        let label = page.label ?? String(number)
        return label == String(number) ? "Page \(number)" : "Page \(label) · PDF \(number)"
    }

    static func rects(for annotation: PDFAnnotation) -> [CGRect] {
        guard let values = annotation.quadrilateralPoints, values.count >= 4,
              values.count.isMultiple(of: 4) else { return [annotation.bounds] }
        return stride(from: 0, to: values.count, by: 4).map { index in
            let points = values[index..<(index + 4)].map(\.pointValue)
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()! + annotation.bounds.minX,
                          y: ys.min()! + annotation.bounds.minY,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }
}

extension GlassineDocument {
    var canEditHighlights: Bool {
        // Rewriting an encrypted PDF needs an explicit password-preservation
        // workflow. Keep it read-only rather than silently remove encryption.
        kind == .pdf && pdf?.isLocked == false && pdf?.isEncrypted == false &&
            pdf?.allowsCommenting == true && !hasSignatureFields
    }

    var savedHighlights: [SavedHighlight] {
        guard kind == .pdf, let pdf else { return [] }
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.flatMap { page in
            let key = ObjectIdentifier(page)
            if let cached = highlightPageCache[key] { return cached }
            let items = page.annotations.filter { $0.type == "Highlight" }
                .map { SavedHighlight(page: page, annotation: $0) }
                .sorted {
                    // Text order keeps columns together; geometry is the
                    // fallback for image-only pages and tied text ranges.
                    if $0.readingOrder != $1.readingOrder { return $0.readingOrder < $1.readingOrder }
                    if $0.annotation.bounds.maxY != $1.annotation.bounds.maxY {
                        return $0.annotation.bounds.maxY > $1.annotation.bounds.maxY
                    }
                    return $0.annotation.bounds.minX < $1.annotation.bounds.minX
                }
            highlightPageCache[key] = items
            return items
        }
    }

    func canEdit(_ annotation: PDFAnnotation) -> Bool {
        guard canEditHighlights, annotation.page?.document === pdf,
              annotation.type == "Highlight" else { return false }
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        return flags & (64 | 128 | 512) == 0 // ReadOnly, Locked, LockedContents
    }

    @discardableResult
    func addHighlight(selection: PDFSelection, color: HighlightColor) -> [SavedHighlight] {
        guard canEditHighlights, selection.string?.isEmpty == false,
              selection.pages.allSatisfy({ $0.document === pdf }) else { return [] }
        let lines = selection.selectionsByLine()
        let added: [SavedHighlight] = selection.pages.compactMap { page in
            let pageLines = lines.filter { $0.pages.contains(where: { $0 === page }) }
            let rects = pageLines.map { $0.bounds(for: page) }.filter {
                !$0.isEmpty && !$0.isInfinite && !$0.isNull &&
                $0.origin.x.isFinite && $0.origin.y.isFinite
            }
            guard let first = rects.first else { return nil }
            let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = color.color
            annotation.quadrilateralPoints = rects.flatMap { rect in
                let r = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                return [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
                        NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY)]
                    .map { NSValue(point: $0) }
            }
            annotation.modificationDate = Date()
            annotation.shouldPrint = true
            return SavedHighlight(page: page, annotation: annotation)
        }
        setHighlights(added, present: true, action: "Highlight")
        return added
    }

    func removeHighlight(_ annotation: PDFAnnotation) {
        guard canEdit(annotation), let page = annotation.page else { return }
        setHighlights([SavedHighlight(page: page, annotation: annotation)], present: false,
                      action: "Delete Highlight")
    }

    private func setHighlights(_ items: [SavedHighlight], present: Bool, action: String) {
        guard !items.isEmpty, items.allSatisfy({ $0.page.document === pdf }) else { return }
        // NSDocument observes this manager for edited-state and close prompts.
        undoManager?.registerUndo(withTarget: self) { document in
            document.setHighlights(items, present: !present, action: action)
        }
        undoManager?.setActionName(action)
        for item in items {
            highlightPageCache.removeValue(forKey: ObjectIdentifier(item.page))
            if present { item.page.addAnnotation(item.annotation) }
            else { item.page.removeAnnotation(item.annotation) }
        }
        scheduleHighlightSave()
        NotificationCenter.default.post(name: .glassineHighlightsDidChange, object: self,
                                        userInfo: ["pages": items.map(\.page)])
    }

    func recolorHighlight(_ annotation: PDFAnnotation, color: NSColor) {
        guard canEdit(annotation), annotation.color != color else { return }
        let previous = annotation.color
        let date = annotation.modificationDate
        setHighlightColor(annotation, color: color, date: Date(), previous: previous, previousDate: date)
    }

    private func setHighlightColor(_ annotation: PDFAnnotation, color: NSColor, date: Date?,
                                   previous: NSColor, previousDate: Date?) {
        guard annotation.page?.document === pdf else { return }
        undoManager?.registerUndo(withTarget: self) { document in
            document.setHighlightColor(annotation, color: previous, date: previousDate,
                                       previous: color, previousDate: date)
        }
        undoManager?.setActionName("Change Highlight Color")
        annotation.color = color
        annotation.modificationDate = date
        scheduleHighlightSave()
        NotificationCenter.default.post(name: .glassineHighlightsDidChange, object: self,
                                        userInfo: ["pages": annotation.page.map { [$0] } ?? []])
    }
}

extension GlassineDocument {
    /// Signature fields can inherit /FT from a parent and need not have a
    /// visible widget. Inspect the form tree, not just PDFKit's page annotations.
    static func containsSignatureFields(in document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var form: CGPDFDictionaryRef?
        var permissions: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Perms", &permissions) { return true }
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form else { return false }
        var signatureFlags: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(form, "SigFlags", &signatureFlags), signatureFlags != 0 { return true }
        func containsSignature(_ fields: CGPDFArrayRef, depth: Int) -> Bool {
            // Malformed/cyclic form trees are also unsafe to rewrite.
            guard depth < 64 else { return true }
            for index in 0..<CGPDFArrayGetCount(fields) {
                var field: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(fields, index, &field), let field else { continue }
                var type: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(field, "FT", &type), let type,
                   String(cString: type) == "Sig" { return true }
                var children: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(field, "Kids", &children), let children,
                   containsSignature(children, depth: depth + 1) { return true }
            }
            return false
        }
        var fields: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(form, "Fields", &fields) &&
            fields.map { containsSignature($0, depth: 0) } == true
    }
}
