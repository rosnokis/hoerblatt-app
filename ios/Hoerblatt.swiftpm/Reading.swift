import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Reading order, sentences and hit tests on one page. Port of hitWord, hitGap, answerOn, answerAt, boxWords,
// seq and sentenceAt from index.html (the tested web version). Pure value logic, no UIKit, no actor state.

/// What "Satz" reads: text pieces and gap tones, plus one rectangle per line to light up.
struct Sentence {
    var parts: [SpeechPart]
    var rects: [CGRect]
}

/// A word or a gap in reading order (JS: an item of seq()).
fileprivate struct ReadingItem {
    /// Index in `Page.words`.
    var word: Int?
    /// Index in `Page.gaps`.
    var gap: Int?
    var x0: CGFloat
    var y0: CGFloat
    var x1: CGFloat
    var y1: CGFloat
    /// Row number in reading order.
    var li: Int = 0
    /// First item of its row.
    var first: Bool = false
    /// Left edge and bottom of the row's first item (the start of the line).
    var rowX: CGFloat = 0
    var rowY1: CGFloat = 0
    /// The row holds only gaps (an answer line on its own, e.g. for writing a whole sentence).
    var gapRow: Bool = false
    var rowRight: CGFloat = 0
    /// Typical word height of the row; 0 when the row has no words.
    var rowH: CGFloat = 0
    /// Right edge of the text block around the row.
    var blockRight: CGFloat = 0

    init(word: Int?, gap: Int?, rect: CGRect) {
        self.word = word
        self.gap = gap
        x0 = rect.minX
        y0 = rect.minY
        x1 = rect.maxX
        y1 = rect.maxY
    }

    var h: CGFloat { return y1 - y0 }
    var cy: CGFloat { return (y0 + y1) / 2 }
    var rect: CGRect { return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
}

struct Reading {
    /// Typical text height in page pixels (JS: doc.fs); tolerances and new answer fields scale with it.
    let textSize: CGFloat

    private let page: Page
    private let items: [ReadingItem]
    /// Position in `items` of each word / gap (by index), -1 if missing.
    private let wordPos: [Int]
    private let gapPos: [Int]

    init(page: Page) {
        self.page = page
        let th = page.textHeight
        if th.isFinite && th > 1 {
            textSize = th
        } else {
            textSize = max(12, page.pixelSize.height * 0.024)
        }
        let order = readingOrder(page)
        items = order
        var wp = [Int](repeating: -1, count: page.words.count)
        var gp = [Int](repeating: -1, count: page.gaps.count)
        for (n, it) in order.enumerated() {
            if let w = it.word, w >= 0, w < wp.count { wp[w] = n }
            if let g = it.gap, g >= 0, g < gp.count { gp[g] = n }
        }
        wordPos = wp
        gapPos = gp
    }

    private var pageW: CGFloat { return max(page.pixelSize.width, 1) }
    private var pageH: CGFloat { return max(page.pixelSize.height, 1) }

    // MARK: - Hits

    /// Word id under the finger: the closest word whose (slightly enlarged) box holds the point;
    /// `loose` also takes a word just next to it.
    func wordAt(_ p: CGPoint, loose: Bool) -> Int? {
        var best = -1
        var bd = CGFloat.infinity
        for (i, w) in page.words.enumerated() {
            let r = w.rect
            let px = r.height * 0.25
            let py = r.height * 0.3
            let insideX = p.x >= r.minX - px && p.x <= r.maxX + px
            let insideY = p.y >= r.minY - py && p.y <= r.maxY + py
            if insideX && insideY {
                let d = abs(p.x - r.midX) + abs(p.y - r.midY) * 2
                if d < bd {
                    bd = d
                    best = i
                }
            }
        }
        if best < 0 && loose {
            for (i, w) in page.words.enumerated() {
                let r = w.rect
                let dx = max(r.minX - p.x, 0, p.x - r.maxX)
                let dy = max(r.minY - p.y, 0, p.y - r.maxY) * 1.5
                let d = (dx * dx + dy * dy).squareRoot()
                if d < r.height * 0.9 && d < bd {
                    bd = d
                    best = i
                }
            }
        }
        return best >= 0 ? page.words[best].id : nil
    }

    /// Index in `page.gaps` of the gap under the finger (first one, as in the JS).
    func gapAt(_ p: CGPoint) -> Int? {
        for (k, g) in page.gaps.enumerated() {
            let b = g.rect
            // a tall field must not catch taps far above or below it
            let h: CGFloat = g.kind == .box ? min(b.height, textSize) : b.height
            let side = h * 0.2
            let above = h * 0.3
            let below = h * 0.5
            let insideX = p.x >= b.minX - side && p.x <= b.maxX + side
            let insideY = p.y >= b.minY - above && p.y <= b.maxY + below
            if insideX && insideY { return k }
        }
        return nil
    }

    /// Index in `page.answers` of the answer field under the finger (the topmost one).
    func answerAt(_ p: CGPoint) -> Int? {
        let pad = textSize * 0.2
        for k in page.answers.indices.reversed() {
            let r = fieldRect(page.answers[k]).insetBy(dx: -pad, dy: -pad)
            if r.contains(p) { return k }
        }
        return nil
    }

    /// Index in `page.marks` of the mark under the finger (the one drawn last).
    func markAt(_ p: CGPoint) -> Int? {
        let pad = max(4, textSize * 0.15)
        for k in page.marks.indices.reversed() {
            guard let r = markRect(page.marks[k]) else { continue }
            if r.insetBy(dx: -pad, dy: -pad).contains(p) { return k }
        }
        return nil
    }

    // MARK: - Sentences

    func sentence(atWord id: Int) -> Sentence {
        guard let i = wordIndex(id) else { return Sentence(parts: [], rects: []) }
        let pos = wordPos[i]
        if pos < 0 {
            let w = page.words[i]
            return Sentence(parts: [SpeechPart.text(w.text)], rects: [w.rect])
        }
        return sentence(atPosition: pos)
    }

    func sentence(atGap index: Int) -> Sentence {
        guard index >= 0 && index < page.gaps.count else { return Sentence(parts: [], rects: []) }
        let pos = gapPos[index]
        if pos < 0 {
            return Sentence(parts: [SpeechPart.tone], rects: [page.gaps[index].rect])
        }
        return sentence(atPosition: pos)
    }

    /// The words of a printed box in reading order.
    func boxWords(_ box: Int) -> [Word] {
        var list: [(pos: Int, word: Word)] = []
        for (i, w) in page.words.enumerated() where w.box == box {
            let pos = (i < wordPos.count && wordPos[i] >= 0) ? wordPos[i] : Int.max
            list.append((pos: pos, word: w))
        }
        list.sort { a, b in
            if a.pos != b.pos { return a.pos < b.pos }
            if a.word.line != b.word.line { return a.word.line < b.word.line }
            return a.word.rect.minX < b.word.rect.minX
        }
        return list.map { $0.word }
    }

    /// What was answered into the gap ("" when empty): its own answer, else a field placed onto it.
    func answerText(onGap index: Int) -> String {
        guard index >= 0 && index < page.gaps.count else { return "" }
        let g = page.gaps[index]
        for a in page.answers where a.gap == g.id {
            let t = readingTrim(a.text)
            if !t.isEmpty { return t }
        }
        // JS answerOn: a field over the gap that sits on its line
        let b = g.rect
        for a in page.answers {
            let t = readingTrim(a.text)
            if t.isEmpty { continue }
            // (a field that belongs to another gap stays there)
            if let other = a.gap, other != g.id, page.gaps.contains(where: { $0.id == other }) { continue }
            let r = a.rect
            let overX = r.minX < b.maxX && r.maxX > b.minX
            let topOK = r.minY < b.maxY + b.height * 0.5
            let bottomOK = r.minY + textSize * 1.6 > b.minY
            if overX && topOK && bottomOK { return t }
        }
        return ""
    }

    // MARK: - New answer fields

    /// A new field on the gap: in a box it sits inside (at least a few letters wide),
    /// on a line it is as wide as the line with its bottom about on it.
    func newAnswerRect(forGap index: Int) -> CGRect {
        guard index >= 0 && index < page.gaps.count else { return newAnswerRect(at: CGPoint.zero) }
        let g = page.gaps[index].rect
        let fs = textSize
        let height = fs * 1.5
        let x = readingClamp(g.minX, 0, pageW - 120)
        if page.gaps[index].kind == .box {
            let inset = max(0, (g.height - fs * 1.45) / 2)
            let y = readingClamp(g.minY + inset, 0, pageH - fs * 2)
            let w = min(max(g.width, fs * 3.2), pageW - x)
            return CGRect(x: x, y: y, width: w, height: height)
        }
        let y = readingClamp(g.maxY - fs * 1.45, 0, pageH - fs * 2)
        let w = min(max(g.width, pageW * 0.15), pageW - x)
        return CGRect(x: x, y: y, width: w, height: height)
    }

    /// A free field where the finger is (anywhere on the page).
    func newAnswerRect(at p: CGPoint) -> CGRect {
        let fs = textSize
        let room = min(pageW * 0.55, pageW - p.x + pageW * 0.02)
        let w = min(max(room, pageW * 0.25), pageW)
        var x = readingClamp(p.x - pageW * 0.02, 0, pageW - 120)
        // (near the right edge the field moves left instead of sticking out)
        if x + w > pageW { x = max(0, pageW - w) }
        let y = readingClamp(p.y - fs * 0.9, 0, pageH - fs * 2)
        return CGRect(x: x, y: y, width: w, height: fs * 1.5)
    }

    /// Where a mark is drawn: the whole word, or only the marked part of it.
    func markRect(_ mark: Mark) -> CGRect? {
        guard mark.word >= 0 && mark.word < page.words.count else { return nil }
        let r = page.words[mark.word].rect
        if let a = mark.from, let b = mark.to {
            let x0 = min(a, b)
            let x1 = max(a, b)
            return CGRect(x: x0, y: r.minY - 3, width: x1 - x0, height: r.height + 6)
        }
        return r.insetBy(dx: -4, dy: -4)
    }

    /// Punctuation at the edges goes ("Hund." → "Hund"), so a single word is read without a pause.
    static func cleanWord(_ t: String) -> String {
        let keep: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        guard let first = t.firstIndex(where: keep), let last = t.lastIndex(where: keep) else { return "" }
        return String(t[first...last])
    }

    // MARK: - Private

    private func wordIndex(_ id: Int) -> Int? {
        if id >= 0 && id < page.words.count && page.words[id].id == id { return id }
        return page.words.firstIndex(where: { $0.id == id })
    }

    /// The answer field as it appears: it grows downwards with longer answers.
    private func fieldRect(_ a: Answer) -> CGRect {
        let font = textSize * 1.1
        let width = max(a.rect.width, textSize * 2)
        let chars = CGFloat(a.text.count)
        let perLine = max(1, (width / (font * 0.5)).rounded(.down))
        let lines = max(1, (chars / perLine).rounded(.up))
        let height = max(a.rect.height, textSize * 1.5, lines * font * 1.25)
        return CGRect(x: a.rect.minX, y: a.rect.minY, width: width, height: height)
    }

    private func isBoxGap(_ x: ReadingItem) -> Bool {
        guard let g = x.gap else { return false }
        return page.gaps[g].kind == .box
    }

    /// A gap not inside a line of text stands alone.
    private func isSoloGap(_ x: ReadingItem) -> Bool {
        guard let g = x.gap else { return false }
        return !page.gaps[g].inText
    }

    private func boxOf(_ x: ReadingItem) -> Int {
        guard let w = x.word else { return -1 }
        return page.words[w].box ?? -1
    }

    /// The text of the first word of row `li` ("" if it starts with a gap).
    private func firstText(ofRow li: Int) -> String {
        guard let it = items.first(where: { $0.li == li }), let w = it.word else { return "" }
        return page.words[w].text
    }

    /// The sentence ends after item k: . ! ? : (also before closing quotes), not "1.", not "Name: ____".
    private func isEnd(_ k: Int) -> Bool {
        let x = items[k]
        if let g = x.gap { return page.gaps[g].endsSentence }
        guard let wi = x.word else { return false }
        let t = page.words[wi].text
        if t.hasSuffix(":") && k + 1 < items.count {
            let nx = items[k + 1]
            if nx.gap != nil && nx.li == x.li { return false }
        }
        return readingEndsSentence(t)
    }

    /// Two neighbours in reading order belong to different sentences (JS: apart).
    private func apart(_ a: ReadingItem, _ b: ReadingItem) -> Bool {
        if boxOf(a) != boxOf(b) { return true }
        if isSoloGap(a) || isSoloGap(b) { return true }
        if a.li == b.li { return false }
        if a.gapRow || b.gapRow { return true }
        let h = a.rowH > 0 ? a.rowH : a.h
        let h2 = b.rowH > 0 ? b.rowH : b.h
        // heading and text (typical height of each line)
        if max(h, h2) > min(h, h2) * 1.4 { return true }
        // next numbered task
        if b.first, let bw = b.word, readingIsNumbered(page.words[bw].text) { return true }
        // a numbered list without full stops ("1 Rückblick" / "2 Das Werkzeug der Stunde"): each line is a sentence
        if b.first, let bw = b.word, readingIsNumber(page.words[bw].text), readingIsNumber(firstText(ofRow: a.li)) {
            return true
        }
        if b.y0 < a.y0 - h { return true }
        // measured at the start of the line: on a slanted photo the end of a line sits higher or lower
        let dy = b.y0 - (b.first ? a.rowY1 : a.y1)
        // a line ending far before the right edge of its block, then a line starting with a capital: not wrapped
        // ("Klasse: [Klasse]" / "Mein Ermittlerteam:")
        if b.first, let bw = b.word, readingStartsCapital(page.words[bw].text),
           a.rowRight < a.blockRight - (a.blockRight - a.rowX) * 0.4 { return true }
        if dy <= h * 1.3 { return false }
        // worksheets space lines widely (room for gaps): a line starting under the start of the previous one goes on
        let closeBelow = dy < h * 3.2
        let sameStart = abs(b.rowX - a.rowX) < h * 2.5
        if !(b.first && closeBelow && sameStart) { return true }
        // a clearly short line followed by a capital was not wrapped: it ends there
        guard let bw = b.word else { return false }
        let short = a.rowRight < a.blockRight - (a.blockRight - a.rowX) * 0.25
        return short && readingStartsCapital(page.words[bw].text)
    }

    private func sentence(atPosition pos: Int) -> Sentence {
        let it = items
        guard pos >= 0 && pos < it.count else { return Sentence(parts: [], rects: []) }
        var s = pos
        var e = pos
        while s > 0 && !isEnd(s - 1) && !apart(it[s - 1], it[s]) { s -= 1 }
        while e < it.count - 1 && !isEnd(e) && !apart(it[e], it[e + 1]) { e += 1 }

        var lineRects: [Int: CGRect] = [:]
        var parts: [SpeechPart] = []
        var buf: [String] = []
        var prev: ReadingItem? = nil
        var prevText = false
        for n in s...e {
            let x = it[n]
            if let old = lineRects[x.li] {
                lineRects[x.li] = old.union(x.rect)
            } else {
                lineRects[x.li] = x.rect
            }
            // a box inside a word: its answer and the rest of the word are read as one word ("Sp" + "ielen")
            var glue = false
            if let pv = prev, pv.li == x.li, isBoxGap(x) || isBoxGap(pv) {
                glue = x.x0 - pv.x1 < x.h * 0.25
            }
            prev = x
            var piece: String? = nil
            if let wi = x.word {
                piece = readingNoUnderscores(page.words[wi].text)
            } else if let gi = x.gap {
                let t = answerText(onGap: gi)
                if !t.isEmpty { piece = t }
            }
            if let t = piece {
                if glue && prevText && !buf.isEmpty {
                    buf[buf.count - 1] += t
                } else {
                    buf.append(t)
                }
                prevText = true
            } else {
                // an empty gap: the tone
                let joined = readingTrim(buf.joined(separator: " "))
                if !joined.isEmpty { parts.append(SpeechPart.text(joined)) }
                buf = []
                parts.append(SpeechPart.tone)
                prevText = false
            }
        }
        let joined = readingTrim(buf.joined(separator: " "))
        if !joined.isEmpty { parts.append(SpeechPart.text(joined)) }
        let rects = lineRects.keys.sorted().compactMap { lineRects[$0] }
        return Sentence(parts: parts, rects: rects)
    }
}

// MARK: - Reading order (JS: seq)

/// Rows built from where words and gaps sit (the recognition's own lines sometimes mix two rows):
/// neighbours at the same height are chained from left to right into rows, rows from top to bottom.
fileprivate func readingOrder(_ page: Page) -> [ReadingItem] {
    var all: [ReadingItem] = []
    for (i, w) in page.words.enumerated() {
        all.append(ReadingItem(word: i, gap: nil, rect: w.rect))
    }
    for (k, g) in page.gaps.enumerated() {
        all.append(ReadingItem(word: nil, gap: k, rect: g.rect))
    }
    if all.isEmpty { return [] }
    all = readingStableSorted(all) { $0.x0 < $1.x0 }

    var segs: [[ReadingItem]] = []
    for it in all {
        readingPlace(&segs, [it], head: it, maxGap: 6)
    }
    // pieces of one row with more room between them (e.g. around an arrow or a picture);
    // answer lines or writing fields on their own stay a row of their own
    let pieces = readingStableSorted(segs.filter { !$0.isEmpty }) { $0[0].x0 < $1[0].x0 }
    var rows: [[ReadingItem]] = []
    for s in pieces {
        if s.allSatisfy({ $0.gap != nil }) {
            rows.append(s)
        } else {
            readingPlace(&rows, s, head: s[0], maxGap: 25)
        }
    }
    rows = readingStableSorted(rows.filter { !$0.isEmpty }) { $0[0].cy < $1[0].cy }

    var built: [[ReadingItem]] = []
    for (k, row) in rows.enumerated() {
        var r = readingStableSorted(row) { $0.x0 < $1.x0 }
        let onlyGaps = r.allSatisfy { $0.gap != nil }
        let hs = r.filter { $0.word != nil }.map { $0.h }.sorted()
        let rowH: CGFloat = hs.isEmpty ? 0 : hs[hs.count >> 1]
        let rowX = r[0].x0
        let rowY1 = r[0].y1
        let rowRight = r[r.count - 1].x1
        for n in r.indices {
            r[n].li = k
            r[n].first = (n == 0)
            r[n].rowX = rowX
            r[n].rowY1 = rowY1
            r[n].gapRow = onlyGaps
            r[n].rowRight = rowRight
            r[n].rowH = rowH
        }
        built.append(r)
    }
    // right edge of the text block: the furthest line end among rows starting at about the same place, a few rows around
    for k in built.indices {
        let r = built[k]
        let h = r[0].h
        var right = r[r.count - 1].x1
        let lo = max(0, k - 3)
        let hi = min(built.count - 1, k + 3)
        for o in lo...hi {
            let other = built[o]
            if abs(other[0].x0 - r[0].x0) < h * 2.5 {
                right = max(right, other[other.count - 1].x1)
            }
        }
        for n in built[k].indices {
            built[k][n].blockRight = right
        }
    }
    var out: [ReadingItem] = []
    for r in built {
        out.append(contentsOf: r)
    }
    return out
}

/// Joins `items` to the row whose last item ends left of `head` at about the same height; close neighbours first.
fileprivate func readingPlace(_ rows: inout [[ReadingItem]], _ items: [ReadingItem], head it: ReadingItem, maxGap: CGFloat) {
    var best = -1
    var bd = CGFloat.infinity
    for (ri, r) in rows.enumerated() {
        guard let l = r.last else { continue }
        let h = min(l.h, it.h)
        let dx = it.x0 - l.x1
        let dy = abs(it.cy - l.cy)
        // (boxes of neighbouring words may overlap a bit)
        let over = min(it.y1, l.y1) - max(it.y0, l.y0)
        let behind = it.x0 < l.x0 + (l.x1 - l.x0) * 0.5
        let far = dx > max(l.h, it.h) * maxGap
        let otherHeight = dy > h * 0.6 && over < h * 0.5
        // a tall field (an empty table cell) is no line of text: words next to it start their own row
        let tall = (l.gap != nil && l.h > it.h * 1.8) || (it.gap != nil && it.h > l.h * 1.8)
        if behind || far || otherHeight || tall { continue }
        let d = dy + max(dx, 0) * 0.05
        if d < bd {
            bd = d
            best = ri
        }
    }
    if best >= 0 {
        rows[best].append(contentsOf: items)
    } else {
        rows.append(items)
    }
}

/// Sorting that keeps the order of equal elements (like JS Array.sort).
fileprivate func readingStableSorted<T>(_ list: [T], by less: (T, T) -> Bool) -> [T] {
    let indexed = Array(list.enumerated())
    let sorted = indexed.sorted { p, q in
        if less(p.element, q.element) { return true }
        if less(q.element, p.element) { return false }
        return p.offset < q.offset
    }
    return sorted.map { $0.element }
}

// MARK: - Text helpers

fileprivate func readingClamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    return max(lo, min(hi, v))
}

fileprivate func readingTrim(_ s: String) -> String {
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// "____" read as part of a word becomes a space (JS: replace(/_+/g, " ")).
fileprivate func readingNoUnderscores(_ t: String) -> String {
    guard t.contains("_") else { return t }
    var out = ""
    var inRun = false
    for ch in t {
        if ch == "_" {
            if !inRun { out.append(" ") }
            inRun = true
        } else {
            out.append(ch)
            inRun = false
        }
    }
    return out
}

fileprivate func readingIsDigit(_ c: Character) -> Bool {
    guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    return (48...57).contains(s.value)
}

/// "1." – a number, not the end of a sentence (JS: /^\d+\.$/).
fileprivate func readingIsNumberDot(_ t: String) -> Bool {
    let cs = Array(t)
    guard cs.count >= 2, cs[cs.count - 1] == "." else { return false }
    return cs.dropLast().allSatisfy { readingIsDigit($0) }
}

/// "3" alone: a list number without a full stop.
fileprivate func readingIsNumber(_ t: String) -> Bool {
    return !t.isEmpty && t.count <= 2 && t.allSatisfy { $0.isNumber }
}

/// "3." or "3)" at the start of a line: the next task (JS: /^\d+[.)]$/).
fileprivate func readingIsNumbered(_ t: String) -> Bool {
    let cs = Array(t)
    guard cs.count >= 2 else { return false }
    let last = cs[cs.count - 1]
    guard last == "." || last == ")" else { return false }
    return cs.dropLast().allSatisfy { readingIsDigit($0) }
}

/// . ! ? : at the end, also before closing quotes or a bracket ("dabei!“), but not "1."
/// (JS: /[.!?:]["“”»«‘’)]*$/ and not /^\d+\.$/).
fileprivate func readingEndsSentence(_ t: String) -> Bool {
    var cs = Array(t)
    let closing: Set<Character> = ["\"", "“", "”", "»", "«", "‘", "’", ")"]
    while let last = cs.last, closing.contains(last) {
        cs.removeLast()
    }
    guard let last = cs.last else { return false }
    let marks: Set<Character> = [".", "!", "?", ":"]
    guard marks.contains(last) else { return false }
    return !readingIsNumberDot(t)
}

/// Starts with a capital, maybe after an opening quote (JS: /^[„"]?[A-ZÄÖÜ]/).
fileprivate func readingStartsCapital(_ t: String) -> Bool {
    var rest = Substring(t)
    if let f = rest.first, f == "„" || f == "\"" {
        rest = rest.dropFirst()
    }
    guard let c = rest.first, let s = c.unicodeScalars.first else { return false }
    // A–Z, Ä, Ö, Ü
    switch s.value {
    case 65...90, 0xC4, 0xD6, 0xDC:
        return true
    default:
        return false
    }
}
