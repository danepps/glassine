import Foundation
import GlassineCore
import ObjectiveC
import PDFKit

/// Lets a mouse drag, double-click or triple-click select the text on a
/// scanned page instead of the scan.
///
/// The bug: JSTOR's scans (and others made the same way) are one full-page
/// image with an invisible OCR text layer over it. PDFKit puts the image into
/// the page's text as a single U+FFFC whose bounds cover the page, and every
/// point-based hit test lands on that character, so in any `PDFView` -- not
/// just Glassine's -- a drag, double-click or triple-click selects the image
/// and nothing can be copied or highlighted. The text, and `selection(for:)`
/// over a character range, are still correct.
///
/// The fix: all of PDFKit's selection tracking funnels through one private
/// `PDFPage` method, `selectionFromPoint:toPoint:type:` (type 0 character,
/// 1 word, 2 line), plus two edge variants for drags that cross a page. This
/// adds those methods to `ReaderPage` (never to `PDFPage` itself), where they
/// ask `ReaderPage.textPreferringSelection`, which answers from the page's own
/// text geometry only when PDFKit's hit was a scan under text, and otherwise
/// call PDFKit's original implementation with the arguments untouched.
///
/// Private API, so Mac-only: it lives in the app target, never in Core or the
/// iOS app. If a future PDFKit renames or retypes these methods, the lookup or
/// the signature check below fails, nothing is installed (one log line), and
/// selection behaves as it does without the fix. Turn it off with
/// `defaults write com.epps.Glassine DisableScanSelectionFix -bool YES`.
enum ScanSelectionPatch {

    /// Install once; later calls are free. Safe from any thread.
    static func install() { _ = installed }

    /// The selectors that were actually overridden. For the tests.
    static var installedSelectors: [String] { installed }

    private static let installed: [String] = {
        guard !UserDefaults.standard.bool(forKey: "DisableScanSelectionFix") else { return [] }
        var done: [String] = []
        if installTwoPoint() { done.append(twoPointName) }
        if installEdge(edgeToBottomName, toBottom: true) { done.append(edgeToBottomName) }
        if installEdge(edgeFromTopName, toBottom: false) { done.append(edgeFromTopName) }
        return done
    }()

    private static let twoPointName = "selectionFromPoint:toPoint:type:"
    private static let edgeToBottomName = "selectionFromPointToBottom:type:"
    private static let edgeFromTopName = "selectionFromTopToPoint:type:"

    private typealias TwoPointIMP = @convention(c) (AnyObject, Selector, CGPoint, CGPoint, Int32) -> PDFSelection?
    private typealias EdgeIMP = @convention(c) (AnyObject, Selector, CGPoint, Int32) -> PDFSelection?

    private static func installTwoPoint() -> Bool {
        let selector = NSSelectorFromString(twoPointName)
        guard let method = verifiedMethod(selector, arguments: ["{CGPoint=dd}", "{CGPoint=dd}", "i"]) else {
            return false
        }
        let original = unsafeBitCast(method_getImplementation(method), to: TwoPointIMP.self)
        let block: @convention(block) (AnyObject, CGPoint, CGPoint, Int32) -> PDFSelection? = {
            object, from, to, type in
            // A plain click (no movement) clears the selection: PDFKit's nil.
            if !(type == 0 && from == to), let page = object as? ReaderPage,
               let granularity = granularity(type),
               case .text(let selection) = page.textPreferringSelection(from: from, to: to,
                                                                        granularity: granularity) {
                return selection
            }
            return original(object, selector, from, to, type)
        }
        return add(selector, block: block, method: method)
    }

    private static func installEdge(_ name: String, toBottom: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let method = verifiedMethod(selector, arguments: ["{CGPoint=dd}", "i"]) else { return false }
        let original = unsafeBitCast(method_getImplementation(method), to: EdgeIMP.self)
        let block: @convention(block) (AnyObject, CGPoint, Int32) -> PDFSelection? = { object, point, type in
            if let page = object as? ReaderPage, let granularity = granularity(type) {
                let answer = toBottom
                    ? page.textPreferringSelection(fromPointToBottom: point, granularity: granularity)
                    : page.textPreferringSelection(fromTopToPoint: point, granularity: granularity)
                if case .text(let selection) = answer { return selection }
            }
            return original(object, selector, point, type)
        }
        return add(selector, block: block, method: method)
    }

    private static func granularity(_ type: Int32) -> PageTextMap.Granularity? {
        switch type {
        case 0: .character
        case 1: .word
        case 2: .line
        default: nil
        }
    }

    /// PDFPage's method, if it exists with exactly the expected shape: an
    /// object back, then self, _cmd and `arguments`.
    private static func verifiedMethod(_ selector: Selector, arguments: [String]) -> Method? {
        guard let method = class_getInstanceMethod(PDFPage.self, selector) else {
            NSLog("Glassine: scan selection fix not installed: PDFPage has no %@", NSStringFromSelector(selector))
            return nil
        }
        let expected = ["@", ":"] + arguments
        var actual: [String] = []
        let count = method_getNumberOfArguments(method)
        for index in 0..<count {
            guard let type = method_copyArgumentType(method, index) else { break }
            actual.append(String(cString: type))
            free(type)
        }
        let returnType = method_copyReturnType(method)
        let returns = String(cString: returnType)
        free(returnType)
        guard returns == "@", actual == expected else {
            NSLog("Glassine: scan selection fix not installed: %@ is %@ %@, expected @ %@",
                  NSStringFromSelector(selector), returns, actual.joined(separator: " "),
                  expected.joined(separator: " "))
            return nil
        }
        return method
    }

    private static func add(_ selector: Selector, block: Any, method: Method) -> Bool {
        let added = class_addMethod(ReaderPage.self, selector, imp_implementationWithBlock(block),
                                    method_getTypeEncoding(method))
        if !added {
            NSLog("Glassine: scan selection fix not installed: ReaderPage already implements %@",
                  NSStringFromSelector(selector))
        }
        return added
    }
}
