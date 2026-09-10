import CoreGraphics
import Foundation
import PDFKit

/// Turns a PDF selection into text a person can paste.
///
/// PDFKit extracts what was *printed*: one hard line break per typeset line, and
/// words broken across a line end still carrying their hyphen ("consti-" /
/// "tution"). Pasted into Word or a mail message that is a wall of ragged short
/// lines with hyphens in the middle of words, and re-flowing it by hand is the
/// single most tedious thing about quoting from a PDF.
///
/// So the lines are put back together: the ones that belong to the same
/// paragraph are joined with a single space, a line-end hyphen is dropped when
/// it was a syllable break and kept when it belongs to the word ("well-known"),
/// and a real paragraph break stays a break.
///
/// Where a paragraph ends is a question the text alone cannot answer -- a
/// sentence ends mid-paragraph on nearly every page -- so the decision is made
/// from the *geometry* of the lines, which is what a reader's eye uses too: a
/// first-line indent, a line that stops well short of the right margin with a
/// full stop on it, a wider gap, a centred heading. `text(lines:isWord:)` takes
/// that geometry; `text(_:isWord:)` is the text-only fallback for callers that
/// have none.
///
/// PDFKit page coordinates put the origin at the bottom left with y growing
/// upward, so the *next* line down the page has the smaller `minY`.
public enum CopyCleanup {

    /// One printed line of a selection, with its geometry on its page.
    public struct Line: Sendable {
        /// The line's text, as extracted. Trimmed and space-collapsed here.
        public var text: String
        /// The line's bounds in page space (origin bottom-left, y up).
        public var bounds: CGRect
        /// The page's index in its document. Only ever compared, never indexed
        /// with, so a caller with one page can pass 0 for all of them.
        public var page: Int

        public init(text: String, bounds: CGRect, page: Int) {
            self.text = text
            self.bounds = bounds
            self.page = page
        }
    }

    // MARK: - Entry points

    /// Geometry-aware cleanup.
    ///
    /// - Parameters:
    ///   - lines: the selection's printed lines, in reading order.
    ///   - isWord: "is this a word in the dictionary", for deciding whether a
    ///     line-end hyphen belongs to the word. Nil means no dictionary is
    ///     available, in which case a hyphen before a lowercase letter is
    ///     treated as a syllable break -- which it usually is.
    ///   - paragraphSeparator: what goes between paragraphs. One newline by
    ///     default: a paste then gets one paragraph mark per paragraph, which is
    ///     what a word processor wants.
    public static func text(lines: [Line],
                            isWord: ((String) -> Bool)? = nil,
                            paragraphSeparator: String = "\n") -> String {
        let prepared = normalised(lines)
        guard let first = prepared.first else { return "" }
        let columns = columns(of: prepared)

        var out = first.text
        for index in prepared.indices.dropFirst() {
            if breaksParagraph(from: index - 1, to: index, in: prepared, columns: columns) {
                out += paragraphSeparator + prepared[index].text
            } else {
                out = joined(out, with: prepared[index].text, isWord: isWord)
            }
        }
        return out
    }

    /// Text-only fallback: no geometry, so the only paragraph break it can see
    /// is a blank line. A sentence ending at a line end is *not* treated as a
    /// paragraph break -- most of them are not -- so the result runs paragraphs
    /// together rather than shattering them, which is the recoverable mistake.
    public static func text(_ raw: String,
                            isWord: ((String) -> Bool)? = nil,
                            paragraphSeparator: String = "\n") -> String {
        var out = ""
        var started = false
        var pendingBreak = false
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = collapsingSpaces(String(rawLine))
            if line.isEmpty {
                if started { pendingBreak = true }
                continue
            }
            if !started {
                out = line
                started = true
            } else if pendingBreak {
                out += paragraphSeparator + line
                pendingBreak = false
            } else {
                out = joined(out, with: line, isWord: isWord)
            }
        }
        return out
    }

    /// The PDFKit form: the geometry comes from the selection's own lines.
    ///
    /// Falls back to the text-only path when PDFKit reports no usable bounds for
    /// any line -- some generated documents do that, and a column of zero-width
    /// rectangles would make every heuristic here answer nonsense.
    public static func text(for selection: PDFSelection,
                            isWord: ((String) -> Bool)? = nil,
                            paragraphSeparator: String = "\n") -> String {
        var lines: [Line] = []
        var sawGeometry = false
        for lineSelection in selection.selectionsByLine() {
            guard let page = lineSelection.pages.first else { continue }
            let bounds = usable(lineSelection.bounds(for: page))
            if bounds.width > 0, bounds.height > 0 { sawGeometry = true }
            lines.append(Line(text: lineSelection.string ?? "",
                              bounds: bounds,
                              page: page.document?.index(for: page) ?? 0))
        }
        guard sawGeometry else {
            return text(selection.string ?? "",
                        isWord: isWord,
                        paragraphSeparator: paragraphSeparator)
        }
        return text(lines: lines, isWord: isWord, paragraphSeparator: paragraphSeparator)
    }

    // MARK: - Preparation

    /// A line that survived normalisation, plus the one thing the empty lines
    /// were carrying: that a blank line came before this one.
    private struct Prepared {
        var text: String
        var bounds: CGRect
        var page: Int
        /// An empty line separated this line from the previous one.
        var afterBlank: Bool
    }

    private static func normalised(_ lines: [Line]) -> [Prepared] {
        var out: [Prepared] = []
        var blankSeen = false
        for line in lines {
            let text = collapsingSpaces(line.text)
            guard !text.isEmpty else {
                // Not dropped so much as remembered: a blank line is a paragraph
                // break, and it is the only one the text can state outright.
                blankSeen = !out.isEmpty
                continue
            }
            let bounds = usable(line.bounds)
            if !blankSeen, let previous = out.last,
               let merged = merging(previous, text, bounds, line.page) {
                out[out.count - 1] = merged
                continue
            }
            out.append(Prepared(text: text,
                                bounds: bounds,
                                page: line.page,
                                afterBlank: blankSeen))
            blankSeen = false
        }
        return out
    }

    /// Put back together a printed line that PDFKit cut in two.
    ///
    /// `selectionsByLine()` cuts a line wherever the font changes, so a footnote
    /// marker, an italicised case name or a small-caps author's name can each
    /// arrive as a "line" of its own -- sitting on the same baseline as the text
    /// it belongs to and starting where that text left off. Rejoining them here,
    /// before anything measures a margin, is not cosmetic: a superscript marker
    /// cut off the end of a line starts 300 pt from the left margin, which the
    /// first-line-indent test would read as the start of a new paragraph, and a
    /// marker cut off the *front* of a footnote would leave "28" a paragraph of
    /// its own.
    ///
    /// Whether a space goes between them is the page's answer rather than a
    /// guess: the two faces of "Lochner-era" touch, and so does a footnote
    /// marker set against the comma before it, while "28" and the name that
    /// follows it do not.
    private static func merging(_ previous: Prepared, _ text: String,
                                _ bounds: CGRect, _ page: Int) -> Prepared? {
        guard previous.page == page, bounds.width > 0, previous.bounds.width > 0 else {
            return nil
        }
        // Measured against the shorter of the two, and only when the two are
        // comparably tall at all. A page can carry a line that has nothing to
        // do with the text and happens to lie across it -- the sideways
        // "Downloaded from …" watermark a publisher stamps down the margin is
        // 750 pt tall and would otherwise swallow the line it ends beside.
        let scale = min(previous.bounds.height, bounds.height)
        let tolerance = 0.25 * scale
        let gap = bounds.minX - previous.bounds.maxX
        guard scale > 0,
              scale >= 0.4 * max(previous.bounds.height, bounds.height),
              abs(previous.bounds.minY - bounds.minY) < 0.5 * scale,
              gap >= -tolerance,
              // Adjacent, not merely level: a running head's page number and
              // its title share a baseline with a hand's breadth between them,
              // and they are two blocks of text, not one line.
              gap <= 2 * scale else { return nil }
        let spaced = gap > tolerance
        return Prepared(text: previous.text + (spaced ? " " : "") + text,
                        bounds: previous.bounds.union(bounds),
                        page: page,
                        afterBlank: previous.afterBlank)
    }

    /// PDFKit hands back `CGRect.null` for a line it has no geometry for, whose
    /// `minX` is infinite and would poison every comparison below.
    private static func usable(_ rect: CGRect) -> CGRect {
        (rect.isNull || rect.isInfinite || !rect.origin.x.isFinite || !rect.origin.y.isFinite
            || !rect.size.width.isFinite || !rect.size.height.isFinite) ? .zero : rect
    }

    /// Trim, and collapse internal runs of ASCII whitespace to one space.
    /// Deliberately blind to the exotic spaces (no-break, thin, figure): those
    /// are characters the author chose, and this is not a place that rewrites
    /// the text.
    private static func collapsingSpaces(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: isPlainSpace) else { return trimmed }
        var out = ""
        out.reserveCapacity(trimmed.count)
        var gap = false
        for character in trimmed {
            if isPlainSpace(character) {
                gap = true
            } else {
                if gap { out.append(" ") }
                gap = false
                out.append(character)
            }
        }
        return out
    }

    private static func isPlainSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }

    // MARK: - Columns

    /// The column a line sits in: the margins its paragraphs are measured
    /// against, and the type size those margins are measured in.
    ///
    /// The margins are quartiles rather than the extremes. A page carries lines
    /// that are in a column without being *of* it -- a running head above it, a
    /// figure caption across it, a publisher's sideways watermark beside it --
    /// and one of those at an outer edge would move a margin every line is then
    /// measured against. A quarter of the lines have to agree before an edge
    /// counts as the column's.
    private struct Column {
        var left: CGFloat
        var right: CGFloat
        var lineHeight: CGFloat
        /// Identifies one column of one page, so "same column" is a comparison
        /// rather than a re-derivation.
        var id: Int
    }

    /// Split each page's lines into columns by their left edges.
    ///
    /// A first-line indent is one or two ems; the gutter between two columns of
    /// a law review is a dozen. Three line heights sits comfortably between them
    /// and needs no page-width guess. Clustering is done on the *sorted* left
    /// edges, so the two columns separate however their lines were interleaved
    /// in reading order.
    ///
    /// A wide gap is necessary but not sufficient: a centred heading also starts
    /// far to the right of the body's left margin, and a column of its own is
    /// exactly what it must not become -- its margins are the ones that make it
    /// look centred. So a split also has to *clear* the lines above it: a real
    /// second column begins to the right of where the first one ends.
    private static func columns(of lines: [Prepared]) -> [Column] {
        var out = [Column](repeating: Column(left: 0, right: 0, lineHeight: 0, id: 0),
                           count: lines.count)
        var nextID = 0
        let pages = Dictionary(grouping: lines.indices, by: { lines[$0].page })

        for page in pages.keys.sorted() {
            let indices = pages[page] ?? []
            let pageHeight = median(indices.map { lines[$0].bounds.height }.filter { $0 > 0 })
            let gutter = pageHeight * 3

            var cluster: [Int] = []
            var previousLeft: CGFloat?
            var clusterRight: CGFloat = -.greatestFiniteMagnitude

            func flush() {
                guard !cluster.isEmpty else { return }
                let column = Column(
                    left: quantile(cluster.map { lines[$0].bounds.minX }, 0.25),
                    right: quantile(cluster.map { lines[$0].bounds.maxX }, 0.75),
                    lineHeight: median(cluster.map { lines[$0].bounds.height }.filter { $0 > 0 }),
                    id: nextID)
                for index in cluster { out[index] = column }
                nextID += 1
                cluster.removeAll()
                clusterRight = -.greatestFiniteMagnitude
            }

            for index in indices.sorted(by: { lines[$0].bounds.minX < lines[$1].bounds.minX }) {
                let left = lines[index].bounds.minX
                // With no height information there is no scale to judge a gutter
                // by, so the page stays one column.
                if let previous = previousLeft, gutter > 0,
                   left - previous > gutter, left >= clusterRight {
                    flush()
                }
                cluster.append(index)
                clusterRight = max(clusterRight, lines[index].bounds.maxX)
                previousLeft = left
            }
            flush()
        }
        return out
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        quantile(values, 0.5)
    }

    /// Nearest-rank quantile: with one value it is that value, and with two it
    /// is the lower of them at 0.25 and the upper at 0.75. A short selection
    /// therefore falls back to the extremes, which is right -- three lines are
    /// not enough to call one of them an outlier.
    private static func quantile(_ values: [CGFloat], _ fraction: Double) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    // MARK: - Where the paragraphs are

    /// Is there a paragraph break between line `a` and the line `b` that follows
    /// it in reading order?
    ///
    /// A page or column boundary is deliberately *not* one of the reasons: a
    /// paragraph running from the foot of one column to the head of the next is
    /// the normal case in a two-column article, and the tests below answer it
    /// correctly on their own.
    private static func breaksParagraph(from a: Int, to b: Int,
                                        in lines: [Prepared],
                                        columns: [Column]) -> Bool {
        let previous = lines[a], line = lines[b]
        let previousColumn = columns[a], column = columns[b]

        // (a) A blank line said so outright.
        if line.afterBlank { return true }

        // (f) A list marker starts an item, whatever the line before it did.
        if startsWithListMarker(line.text) { return true }

        // How much further in this line starts than the one before it, each
        // measured against its own column so that a column change is not itself
        // an indent. Nearly everything below turns on this rather than on the
        // absolute indent: a block quote is a run of lines that are all indented
        // and none of which begins a paragraph, and the only thing that
        // distinguishes its first line is that it steps *in* from the line above.
        let step = (line.bounds.minX - column.left)
            - (previous.bounds.minX - previousColumn.left)
        let indentChanged = column.lineHeight > 0 && abs(step) > 0.25 * column.lineHeight

        // (e) A centred line is a heading (or a display line): break on both
        // sides of it. Only where the indent changes, though -- every line of a
        // block quote is inset from both margins, and a run of them is one
        // paragraph rather than a dozen headings.
        if indentChanged, isCentred(previous, previousColumn) || isCentred(line, column) {
            return true
        }

        // (b) A first-line indent. A line that steps back *out* is not one: it
        // is the second line of a paragraph whose first line was indented.
        if column.lineHeight > 0, step > 0.8 * column.lineHeight { return true }

        // (c) The previous line ended a sentence and stopped short of its right
        // margin, with room to spare for the next word. Measured in the previous
        // line's own column, so it works at the foot of a column too.
        if endsSentence(previous.text),
           stopsShort(previous, in: previousColumn, before: line) {
            return true
        }

        // (d) Extra leading between two lines of the same column: a blank line
        // that carried no text, or the air around a heading.
        if previousColumn.id == column.id, previous.page == line.page,
           previousColumn.lineHeight > 0 {
            let step = previous.bounds.minY - line.bounds.minY
            if step > 1.6 * previousColumn.lineHeight { return true }
        }

        return false
    }

    /// Indented from both margins by more than two line heights: nothing set as
    /// running text is, and headings and display lines usually are.
    private static func isCentred(_ line: Prepared, _ column: Column) -> Bool {
        guard column.lineHeight > 0 else { return false }
        let slack = 2 * column.lineHeight
        return line.bounds.minX - column.left > slack
            && column.right - line.bounds.maxX > slack
    }

    /// Did `line` stop short of its right margin by more than the first word of
    /// `next` would have needed? Then the words did not run out; the paragraph
    /// did. The width per character comes from the *next* line, which is set in
    /// the same face, and is the only estimate available without the fonts.
    private static func stopsShort(_ line: Prepared, in column: Column,
                                   before next: Prepared) -> Bool {
        guard column.lineHeight > 0, next.bounds.width > 0, !next.text.isEmpty else {
            return false
        }
        let word = next.text.prefix { !$0.isWhitespace }
        let perCharacter = next.bounds.width / CGFloat(max(1, next.text.count))
        let needed = perCharacter * CGFloat(word.count + 1)
        return column.right - line.bounds.maxX > needed + 0.5 * column.lineHeight
    }

    private static let terminators: Set<Character> = [".", "?", "!", ":", ";", "…"]
    private static let closers: Set<Character> = ["\"", "”", "’", "'", ")", "]", "}", "»"]

    /// Does the line end a sentence? Closing quotes and brackets are looked
    /// through; a line ending in a dash is a sentence interrupted, not finished.
    private static func endsSentence(_ text: String) -> Bool {
        var tail = Substring(text)
        while let last = tail.last, closers.contains(last) { tail = tail.dropLast() }
        guard let last = tail.last else { return false }
        return terminators.contains(last)
    }

    private static let bullets: Set<Character> = ["•", "·", "◦", "▪", "‣", "–", "—", "*"]
    private static let romanLetters: Set<Character> = ["i", "v", "x", "I", "V", "X"]

    /// "1.", "(a)", "•", "iii)" and friends, followed by a space and something
    /// else. Hand-written rather than a regular expression so the one case that
    /// matters to a law library can be excluded: a wrapped line beginning "v.
    /// Board of Education" is a case name, not roman numeral five.
    private static func startsWithListMarker(_ text: String) -> Bool {
        let token = text.prefix { !$0.isWhitespace }
        // The marker has to be followed by a space and some text; a line that is
        // nothing but "1." is not an item, it is a stray number.
        guard !token.isEmpty, token.count < text.count else { return false }

        if token.count == 1, let only = token.first, bullets.contains(only) { return true }

        if token.count >= 3, token.first == "(", token.last == ")" {
            let inner = token.dropFirst().dropLast()
            if inner.count <= 3,
               inner.allSatisfy({ ($0.isLowercase && $0.isLetter) || $0.isNumber }) {
                return true
            }
        }

        guard let last = token.last, last == "." || last == ")" else { return false }
        let stem = token.dropLast()
        guard !stem.isEmpty else { return false }
        if stem.count <= 3, stem.allSatisfy(\.isNumber) { return true }
        // Roman numerals, minus "v." -- overwhelmingly a case name here.
        if stem.count <= 5, stem.allSatisfy({ romanLetters.contains($0) }), stem != "v" {
            return true
        }
        return false
    }

    // MARK: - Joining, and the hyphen

    private static let hyphens: Set<Character> = ["-", "\u{2010}"]
    private static let softHyphen: Character = "\u{00AD}"

    /// Append `next` to what has been built so far, deciding what to do about a
    /// hyphen at the end of it.
    private static func joined(_ accumulated: String, with next: String,
                               isWord: ((String) -> Bool)?) -> String {
        guard let last = accumulated.last else { return next }

        // A soft hyphen is by definition the typesetter's line-break hyphen, so
        // its presence is the answer: drop it and close the word up. It is also
        // invisible, so keeping one would paste a character nobody can see.
        if last == softHyphen { return String(accumulated.dropLast()) + next }

        guard hyphens.contains(last) else { return accumulated + " " + next }

        let stem = accumulated.dropLast()
        let left = trailingFragment(of: stem)
        let right = leadingFragment(of: next)
        // Nothing that reads as a word on one side of it: an em dash written as
        // "--", a hyphen carrying a closing quote or a footnote digit after it.
        // Not a broken word, so it is left alone and spaced like any other join.
        guard !left.isEmpty, !right.isEmpty else { return accumulated + " " + next }
        return keepsHyphen(left: left, right: right, isWord: isWord)
            ? accumulated + next
            : String(stem) + next
    }

    /// Was the hyphen the word's own, or the line's?
    ///
    /// The dictionary is asked in the order that keeps the two mistakes apart:
    /// "constitution" is a word, so "consti-tution" closes up; "well" and
    /// "known" are both words and "wellknown" is not, so "well-known" keeps its
    /// hyphen. A fragment pair the dictionary cannot place at all -- "certio",
    /// "rari" -- closes up, because a line-end hyphen between two lowercase
    /// non-words is a syllable break far more often than it is anything else.
    private static func keepsHyphen(left: Substring, right: Substring,
                                    isWord: ((String) -> Bool)?) -> Bool {
        guard let first = right.first, let end = left.last else { return true }
        // "Smith-Jones", "Fourth-Amendment", "18-19": a capital or a digit on
        // either side of the hyphen means the hyphen is part of the text.
        if first.isUppercase || first.isNumber || end.isNumber { return true }
        guard let isWord else { return false }
        if isWord(String(left) + String(right)) { return false }
        if isWord(String(left)), isWord(String(right)) { return true }
        return false
    }

    /// The trailing run of letters and digits: the fragment the hyphen split.
    private static func trailingFragment(of text: Substring) -> Substring {
        text.suffix(while: { $0.isLetter || $0.isNumber })
    }

    /// The leading run of letters and digits of the next line, stopping at the
    /// first punctuation mark or space.
    private static func leadingFragment(of text: String) -> Substring {
        text.prefix { $0.isLetter || $0.isNumber }
    }
}

private extension Substring {
    /// `prefix(while:)` from the other end.
    func suffix(while predicate: (Character) -> Bool) -> Substring {
        var start = endIndex
        while start > startIndex {
            let previous = index(before: start)
            if !predicate(self[previous]) { break }
            start = previous
        }
        return self[start...]
    }
}
