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
    /// For each part: where its words stand in the spoken text (to light up the word being spoken).
    var words: [[SpokenWord]] = []
}

/// A word inside a spoken text part: its place in the text (UTF-16, as the speech synthesizer counts) and on the page.
struct SpokenWord {
    var start: Int
    var length: Int
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
    /// Words in the row (a list has one or two per row: "schnell = blitzschnell" / "schwarz = ____").
    var rowWords: Int = 0
    /// The row holds answers to choose, two or more ("(R) Auf dem Flur …   (M) Im dunklen Kellergang"): it ends there.
    var choiceRow: Bool = false
    /// Typical word height of the row; 0 when the row has no words.
    var rowH: CGFloat = 0
    /// Right edge of the text block around the row.
    var blockRight: CGFloat = 0
    /// Page of a photographed double page (0 = left), or column; sentences never run from one into the next.
    var part: Int = 0
    /// Cut-off text of the neighbouring page at the photo's edge: not read when the whole page is read.
    var edge: Bool = false

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

    /// The page as it was when this reading was made.
    let page: Page
    private let items: [ReadingItem]
    /// Position in `items` of each word / gap (by index), -1 if missing.
    private let wordPos: [Int]
    private let gapPos: [Int]
    /// Mean ink colour of each row (by `li`), where its words have one.
    private let rowInk: [Int: (br: Double, gr: Double)]

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
        var sums: [Int: (br: Double, gr: Double, n: Double)] = [:]
        for it in order {
            guard let w = it.word, w >= 0, w < page.words.count, let c = page.words[w].ink, c.count == 2 else { continue }
            // (weighted by size: small coloured labels of an icon in the same row hardly count)
            let r = page.words[w].rect
            let k = Double(max(1, r.width * r.height))
            let s = sums[it.li] ?? (br: 0, gr: 0, n: 0)
            sums[it.li] = (br: s.br + c[0] * k, gr: s.gr + c[1] * k, n: s.n + k)
        }
        var ri: [Int: (br: Double, gr: Double)] = [:]
        for (li, s) in sums where s.n > 0 { ri[li] = (br: s.br / s.n, gr: s.gr / s.n) }
        rowInk = ri
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
            // (the further lines of an answer over several lines catch the finger too)
            for extra in g.more ?? [] {
                let h = extra.height
                if p.x >= extra.minX - h * 0.2 && p.x <= extra.maxX + h * 0.2 && p.y >= extra.minY - h * 0.3
                    && p.y <= extra.maxY + h * 0.5 {
                    return k
                }
            }
            let b = g.rect
            // a tall field must not catch taps far above or below it
            let h: CGFloat = g.kind != .line ? min(b.height, textSize) : b.height
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
            let a = page.answers[k]
            if let lines = page.answerLines(a) {
                // an answer over several writing lines: only its bands, not the box around them (a tap under the
                // field or on the printed text before the first line is not the answer)
                for band in answerFieldBands(a.text, lines: lines, textHeight: textSize)
                where band.insetBy(dx: -pad, dy: -pad).contains(p) {
                    return k
                }
                continue
            }
            let r = fieldRect(a).insetBy(dx: -pad, dy: -pad)
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
        if let more = page.gaps[index].more, !more.isEmpty {
            // one field over all lines (drawn as bands on the lines, see `answerBands`): the box around them
            let lines = [g] + more
            return answerBands(lines, rows: lines.count, textHeight: fs).reduce(CGRect.null) { $0.union($1) }
        }
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

    /// The answer field as it appears (about): it grows downwards with longer answers; in a box the writing gets
    /// smaller first (down to half, as `answerFontSize`), so the field stays in its box as long as it can.
    private func fieldRect(_ a: Answer) -> CGRect {
        let width = max(a.rect.width, textSize * 2)
        let inner = max(1, width - textSize * 0.3)
        let chars = CGFloat(readingTrim(a.text).count)
        func lines(_ font: CGFloat) -> CGFloat {
            let perLine = max(1, (inner / (font * 0.5)).rounded(.down))
            return max(1, (chars / perLine).rounded(.up))
        }
        let base = textSize * 1.1
        var font = base
        if let room = answerRoom(a, in: page) {
            while lines(font) * font * 1.25 + textSize * 0.12 > room && font > base * 0.5 {
                font = max(base * 0.5, font * 0.9)
            }
        }
        let height = max(a.rect.height, textSize * 1.5, lines(font) * font * 1.25 + textSize * 0.12)
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
        if a.part != b.part { return true }
        if boxOf(a) != boxOf(b) { return true }
        if isSoloGap(a) || isSoloGap(b) { return true }
        // an answer to choose ("(R) Auf dem Flur …   (M) Im dunklen Kellergang"): each one is read on its own,
        // also side by side
        if let bw = b.word, readingIsChoiceMark(page.words[bw].text) { return true }
        if a.li == b.li { return false }
        if a.gapRow || b.gapRow { return true }
        // a row with answers to choose ends there ("(F) Er läuft wütend davon" / "Was entdeckt … ?")
        if a.choiceRow { return true }
        // a list: rows of one or two words each, one below the other ("schnell = blitzschnell" / "schwarz = ____";
        // Live Text's tall boxes made them look like close lines of text). Not in a table: cells wrap narrow text.
        // (really one below the other: a slanted line read in two pieces overlaps in height)
        if a.rowWords <= 2 && b.rowWords <= 2 && a.rowWords > 0 && b.rowWords > 0 && boxOf(a) < 0,
           b.y0 - a.y1 > min(a.h, b.h) * 0.3 {
            return true
        }
        let h = a.rowH > 0 ? a.rowH : a.h
        let h2 = b.rowH > 0 ? b.rowH : b.h
        // a line starting with a small letter right below the start of the line before goes on with it, however tall
        // Live Text draws the words (curved book page: "… Onkel Titus zahlte / gut.", "vergammel- / ter Blechklumpen.")
        // (only after a full line: the text was wrapped there; labels of an icon are short rows)
        if b.first, let bw = b.word, readingStartsLower(page.words[bw].text),
           abs(b.rowX - a.rowX) < min(h, h2) * 3, b.y0 - a.rowY1 < max(h, h2),
           a.rowRight >= a.blockRight - (a.blockRight - a.rowX) * 0.2 {
            return false
        }
        // heading and text (typical height of each line)
        if max(h, h2) > min(h, h2) * 1.4 { return true }
        // heading and text in different colours (a dark blue heading over black text, same size)
        if let ia = rowInk[a.li], let ib = rowInk[b.li] {
            let dx = ia.br - ib.br, dy = ia.gr - ib.gr
            if (dx * dx + dy * dy).squareRoot() > 40 { return true }
        }
        // next numbered task
        if b.first, let bw = b.word, readingIsNumbered(page.words[bw].text) { return true }
        // a task marked with a letter ("A Legt die Bildkarten …" / "B Spielt …", "a)", "b.")
        if b.first, let bw = b.word, readingIsLetterMark(page.words[bw].text) { return true }
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

    /// Pages found on the photo (a double page: 2) and which of them are cut-off text of a neighbouring page.
    var pageParts: (count: Int, edge: [Int]) {
        let n = (items.map { $0.part }.max() ?? 0) + 1
        let edge = Set(items.filter { $0.edge }.map { $0.part }).sorted()
        return (n, edge)
    }

    /// Which page of a double page (0 = left) a word belongs to.
    func part(ofWord id: Int) -> Int {
        guard let i = wordIndex(id), i < wordPos.count, wordPos[i] >= 0 else { return 0 }
        return items[wordPos[i]].part
    }

    /// The whole page read aloud (a book): sentence after sentence, from the sentence of word `fromWord` (nil: from
    /// the top), without the cut-off text of the neighbouring page at the photo's edge.
    func pageSentences(fromWord: Int?) -> [Sentence] {
        let it = items
        var pos = 0
        if let id = fromWord, let i = wordIndex(id), i < wordPos.count, wordPos[i] >= 0, !it[wordPos[i]].edge {
            pos = bounds(wordPos[i]).start
        }
        var out: [Sentence] = []
        while pos < it.count {
            if it[pos].edge {
                pos += 1
                continue
            }
            let b = bounds(pos)
            let s = sentence(from: b.start, to: b.end)
            // (a gap on its own – often a line at the book's edge – is no sentence to read)
            if s.parts.contains(where: { if case .text = $0 { return true } else { return false } }) { out.append(s) }
            pos = b.end + 1
        }
        return out
    }

    /// First and last position of the sentence around `pos`.
    private func bounds(_ pos: Int) -> (start: Int, end: Int) {
        let it = items
        var s = pos
        var e = pos
        while s > 0 && !isEnd(s - 1) && !apart(it[s - 1], it[s]) { s -= 1 }
        while e < it.count - 1 && !isEnd(e) && !apart(it[e], it[e + 1]) { e += 1 }
        return (s, e)
    }

    private func sentence(atPosition pos: Int) -> Sentence {
        guard pos >= 0 && pos < items.count else { return Sentence(parts: [], rects: []) }
        let b = bounds(pos)
        return sentence(from: b.start, to: b.end)
    }

    private func sentence(from s: Int, to e: Int) -> Sentence {
        let it = items

        var lineRects: [Int: CGRect] = [:]
        var parts: [SpeechPart] = []
        var words: [[SpokenWord]] = []
        var buf: [String] = []
        var bufRects: [[CGRect]] = []
        var prev: ReadingItem? = nil
        var prevText = false
        /// buf → one text part, with the place of each word in it
        func flush() {
            var text = ""
            var spoken: [SpokenWord] = []
            for (k, piece) in buf.enumerated() {
                let t = readingTrim(piece)
                if t.isEmpty { continue }
                if !text.isEmpty { text += " " }
                spoken.append(SpokenWord(start: text.utf16.count, length: t.utf16.count, rects: bufRects[k]))
                text += t
            }
            if !text.isEmpty {
                parts.append(SpeechPart.text(text))
                words.append(spoken)
            }
            buf = []
            bufRects = []
        }
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
            // a word broken at the end of a line ("kön-" / "nen") is read as one word
            var hyphen = false
            if let pv = prev, pv.li != x.li, pv.word != nil, let wi = x.word, prevText, let last = buf.last,
               last.hasSuffix("-"), last.count > 2, readingStartsLower(page.words[wi].text) {
                hyphen = true
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
                if hyphen && !buf.isEmpty {
                    buf[buf.count - 1] = String(buf[buf.count - 1].dropLast()) + t
                    bufRects[bufRects.count - 1].append(x.rect)
                } else if glue && prevText && !buf.isEmpty {
                    buf[buf.count - 1] += t
                    bufRects[bufRects.count - 1].append(x.rect)
                } else {
                    buf.append(t)
                    bufRects.append([x.rect])
                }
                prevText = true
            } else {
                // an empty gap: the tone
                flush()
                parts.append(SpeechPart.tone)
                words.append([])
                prevText = false
            }
        }
        flush()
        let rects = lineRects.keys.sorted().compactMap { lineRects[$0] }
        return Sentence(parts: parts, rects: rects, words: words)
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
    // (check boxes ☐ are crossed with the pen: no tone in a sentence, not part of the reading order)
    for (k, g) in page.gaps.enumerated() where g.kind != .check {
        all.append(ReadingItem(word: nil, gap: k, rect: g.rect))
    }
    if all.isEmpty { return [] }
    // a photographed double page: the left page first, then the right one (cut-off neighbour text marked)
    let columns = readingColumns(page)
    if columns.cuts.isEmpty { return readingRows(all, page: page, firstRow: 0) }
    var parts = [[ReadingItem]](repeating: [], count: columns.cuts.count + 1)
    for it in all {
        let cx = (it.x0 + it.x1) / 2
        parts[columns.cuts.filter { cx > $0 }.count].append(it)
    }
    var out: [ReadingItem] = []
    for (k, part) in parts.enumerated() where !part.isEmpty {
        var rows = readingRows(part, page: page, firstRow: (out.last?.li ?? -1) + 1)
        for n in rows.indices {
            rows[n].part = k
            rows[n].edge = columns.edge.contains(k)
        }
        out.append(contentsOf: rows)
    }
    return out
}

/// Rows of one page (or one page of a double page), numbered from `firstRow`.
fileprivate func readingRows(_ items: [ReadingItem], page: Page, firstRow: Int) -> [ReadingItem] {
    let all = readingStableSorted(items) { $0.x0 < $1.x0 }

    // words clearly smaller than the print of the page: labels of an icon or picture ("richtig ✓ falsch ✗",
    // "ja nein", "Hollywood" under a star)
    let th = page.textHeight.isFinite && page.textHeight > 1 ? page.textHeight : 0
    let small: CGFloat = th * 0.68
    var segs: [[ReadingItem]] = []
    for it in all {
        readingPlace(&segs, [it], head: it, maxGap: 6, small: small)
    }
    // pieces of one row with more room between them (e.g. around an arrow or a picture);
    // answer lines or writing fields on their own stay a row of their own
    let pieces = readingStableSorted(segs.filter { !$0.isEmpty }) { $0[0].x0 < $1[0].x0 }
    var rows: [[ReadingItem]] = []
    for s in pieces {
        if s.allSatisfy({ $0.gap != nil }) {
            rows.append(s)
        } else {
            readingPlace(&rows, s, head: s[0], maxGap: 25, small: small)
        }
    }
    rows = readingStableSorted(rows.filter { !$0.isEmpty }) { $0[0].cy < $1[0].cy }
    // a row of small labels beside a line of text goes to the end: it must not split the sentence it stands next to
    func isSmall(_ r: [ReadingItem]) -> Bool {
        let ws = r.filter { $0.word != nil }
        return small > 0 && !ws.isEmpty && ws.allSatisfy { $0.h < small }
    }
    let beside: [Bool] = rows.map { r in
        guard isSmall(r) else { return false }
        let y0 = r.map { $0.y0 }.min() ?? 0, y1 = r.map { $0.y1 }.max() ?? 0
        return rows.contains { o in
            !isSmall(o) && o.contains(where: { $0.word != nil }) && o.contains { $0.y0 < y1 && $0.y1 > y0 }
        }
    }
    rows = rows.indices.filter { !beside[$0] }.map { rows[$0] } + rows.indices.filter { beside[$0] }.map { rows[$0] }

    var built: [[ReadingItem]] = []
    for (k, row) in rows.enumerated() {
        var r = readingStableSorted(row) { $0.x0 < $1.x0 }
        let onlyGaps = r.allSatisfy { $0.gap != nil }
        let hs = r.filter { $0.word != nil }.map { $0.h }.sorted()
        let rowH: CGFloat = hs.isEmpty ? 0 : hs[hs.count >> 1]
        let rowX = r[0].x0
        let rowY1 = r[0].y1
        let rowRight = r[r.count - 1].x1
        // (prose has a word space of about half a text height; a wide stretch is a list or two columns)
        let texts = r.compactMap { it -> String? in
            guard let w = it.word, w >= 0, w < page.words.count else { return nil }
            return page.words[w].text
        }
        // (two or more: one at the start alone is a task number, "(5) Schreibe …", whose text may wrap)
        let choice = texts.filter { readingIsChoiceMark($0) }.count >= 2
        for n in r.indices {
            r[n].li = firstRow + k
            r[n].first = (n == 0)
            r[n].rowX = rowX
            r[n].rowY1 = rowY1
            r[n].gapRow = onlyGaps
            r[n].rowRight = rowRight
            r[n].rowWords = texts.count
            r[n].choiceRow = choice
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

/// A photo of an open book: vertical bands without any text split it into its pages (left before right). A column at
/// the photo's edge with cut-off lines is the neighbouring page (`edge`). PDF pages (Hefte) are never split; a
/// worksheet has text across such bands (headings, instructions) and stays one page.
fileprivate func readingColumns(_ page: Page) -> (cuts: [CGFloat], edge: Set<Int>) {
    if page.heft != nil { return ([], []) }
    let ws = page.words.filter { $0.text.contains(where: { $0.isLetter }) && $0.rect.width > 0 && $0.rect.minX.isFinite }
    guard ws.count >= 30 else { return ([], []) }
    let th = max(4, page.textHeight.isFinite && page.textHeight > 1 ? page.textHeight : 20)
    let width = max(1, page.pixelSize.width)
    let binW = max(2, th * 0.25)
    let n = Int((width / binW).rounded(.up)) + 2
    var count = [Int](repeating: 0, count: n)
    // (writing lines and fields count like words: "Möchtest du ____ ein Eis essen?" is one line of one page)
    // (and so do printed boxes and table cells: a table is one page, however wide its columns stand apart)
    let spans = ws.map { $0.rect } + page.gaps.filter { $0.kind != .check }.map { $0.rect } + page.boxes.map { $0.rect }
    for r in spans where r.minX.isFinite && r.maxX.isFinite {
        let a = max(0, Int(r.minX / binW)), b = min(n - 1, Int(r.maxX / binW))
        if a <= b { for k in a...b { count[k] += 1 } }
    }
    let minX = ws.map { $0.rect.minX }.min() ?? 0
    let maxX = ws.map { $0.rect.maxX }.max() ?? width
    // (nothing at all may cross the band: on a book nothing runs over the fold, on a worksheet a single line of text
    // across the page shows it is one page)
    let noise = 0
    var cuts: [CGFloat] = []
    var k = Int(minX / binW) + 1
    let end = min(n - 1, Int(maxX / binW))
    while k < end {
        if count[k] > noise {
            k += 1
            continue
        }
        var e = k
        while e + 1 < end && count[e + 1] <= noise { e += 1 }
        let x0 = CGFloat(k) * binW, x1 = CGFloat(e + 1) * binW
        if x1 - x0 >= th * 2.5 {
            let left = ws.filter { $0.rect.midX < x0 }, right = ws.filter { $0.rect.midX > x1 }
            // a page needs a few lines; a strip of the neighbouring page cut off at the photo's edge only a little
            func enough(_ side: [Word], atEdge: Bool) -> Bool {
                return atEdge ? side.count >= 3 && readingRowCount(side, th) >= 2
                              : side.count >= 8 && readingRowCount(side, th) >= 4
            }
            let leftEdge = (left.map { $0.rect.minX }.min() ?? width) < width * 0.03
            let rightEdge = (right.map { $0.rect.maxX }.max() ?? 0) > width * 0.97
            if enough(left, atEdge: leftEdge), enough(right, atEdge: rightEdge) {
                cuts.append((x0 + x1) / 2)
            }
        }
        k = e + 1
    }
    if cuts.isEmpty { return ([], []) }
    // the neighbouring page: the first or last column, its text running into the photo's edge, not the main page
    var cols = [[Word]](repeating: [], count: cuts.count + 1)
    for w in ws { cols[cuts.filter { w.rect.midX > $0 }.count].append(w) }
    let biggest = cols.indices.max(by: { cols[$0].count < cols[$1].count }) ?? 0
    // (a real page of a double page with a short text is wide and has its lines whole: only a narrow strip or a
    // column with far fewer words counts as the neighbour's rest)
    func strip(_ c: [Word]) -> Bool {
        let span = (c.map { $0.rect.maxX }.max() ?? 0) - (c.map { $0.rect.minX }.min() ?? 0)
        return span < width * 0.3 || c.count * 10 < cols[biggest].count * 3
    }
    var edge = Set<Int>()
    if biggest != 0, let x = cols[0].map({ $0.rect.minX }).min(), x < width * 0.03, strip(cols[0]) { edge.insert(0) }
    let last = cols.count - 1
    if biggest != last, let x = cols[last].map({ $0.rect.maxX }).max(), x > width * 0.97, strip(cols[last]) {
        edge.insert(last)
    }
    return (cuts, edge)
}

/// How many lines of text the words stand in.
fileprivate func readingRowCount(_ ws: [Word], _ th: CGFloat) -> Int {
    let ys = ws.map { $0.rect.midY }.sorted()
    var rows = 0
    var last = -CGFloat.infinity
    for y in ys where y - last > th * 0.6 {
        rows += 1
        last = y
    }
    return rows
}

/// Joins `items` to the row whose last item ends left of `head` at about the same height; close neighbours first.
fileprivate func readingPlace(_ rows: inout [[ReadingItem]], _ items: [ReadingItem], head it: ReadingItem, maxGap: CGFloat,
                              small: CGFloat) {
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
        // words of clearly different size are no line together: the small labels of an icon next to a heading
        // ("richtig ✓ falsch ✗" beside "Fakten-Check", "ja nein" beside "Justus bluffen?")
        // (with a clear space between: a short word like "es" in tight boxes is small too, but sits in the line)
        let otherSize = l.word != nil && it.word != nil && min(l.h, it.h) < small && max(l.h, it.h) > min(l.h, it.h) * 1.6
            && dx > max(l.h, it.h) * 0.6
        if behind || far || otherHeight || tall || otherSize { continue }
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

/// "A" alone, or "a)" / "B." at the start of a line: a task marked with a letter.
fileprivate func readingIsLetterMark(_ t: String) -> Bool {
    let cs = Array(t)
    guard let c = cs.first, "ABCDEFGHabcdefgh".contains(c) else { return false }
    if cs.count == 1 { return c.isUppercase }
    return cs.count == 2 && (cs[1] == ")" || cs[1] == ".")
}

/// "(R)", "(2)", "K)": the mark of an answer to choose (Live Text sometimes loses the opening bracket).
fileprivate func readingIsChoiceMark(_ t: String) -> Bool {
    var cs = Array(t)
    guard cs.count >= 2, cs.count <= 3, cs.last == ")" else { return false }
    cs.removeLast()
    if cs.first == "(" { cs.removeFirst() }
    return cs.count == 1 && (cs[0].isLetter || cs[0].isNumber)
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
/// The first letter is a small one ("gut.", "ter", "»und").
fileprivate func readingStartsLower(_ t: String) -> Bool {
    guard let c = t.first(where: { $0.isLetter }) else { return false }
    return c.isLowercase
}

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

// MARK: - Answer fields: room, writing lines

/// Room for an answer in a table cell or field: from the field's top to the bottom of its box (nil: no box, the
/// field grows freely). (Answers over several writing lines: see `answerLines`.)
func answerRoom(_ a: Answer, in page: Page) -> CGFloat? {
    guard let gid = a.gap, let g = page.gaps.first(where: { $0.id == gid }), g.kind == .box else { return nil }
    let room = g.rect.maxY - a.rect.minY
    return room > 0 ? room : nil
}

extension Page {
    /// The writing lines of an answer over several lines (the gap's own line, then the lines below it), in order;
    /// nil for any other answer. Such an answer is written onto the lines, row by row.
    func answerLines(_ a: Answer) -> [CGRect]? {
        guard let gid = a.gap, let g = gaps.first(where: { $0.id == gid }), let more = g.more, !more.isEmpty
        else { return nil }
        return [g.rect] + more
    }
}

/// Writing line `i` of an answer: the printed lines, then (a long answer) more of them below at the last spacing.
func answerLine(_ lines: [CGRect], _ i: Int) -> CGRect {
    guard let last = lines.last else { return CGRect.zero }
    if i < lines.count { return lines[max(0, i)] }
    let step = lines.count > 1 ? last.maxY - lines[lines.count - 2].maxY : last.height * 2
    return last.offsetBy(dx: 0, dy: max(step, 1) * CGFloat(i - lines.count + 1))
}

/// The field of an answer on writing lines: one band per row (at least one per printed line), as wide as its
/// line, from just under the line above (the first: a text height and a half above its line) down to just under
/// its own line. The bands touch: together one field shaped like the lines (the printed text before the first
/// line stays free).
func answerBands(_ lines: [CGRect], rows: Int, textHeight th: CGFloat) -> [CGRect] {
    guard let first = lines.first else { return [] }
    var out: [CGRect] = []
    var top = first.maxY - th * 1.45
    for i in 0..<max(rows, lines.count) {
        let l = answerLine(lines, i)
        let bottom = max(top + 1, l.maxY + th * 0.15)
        out.append(CGRect(x: l.minX - th * 0.1, y: top, width: l.width + th * 0.2, height: bottom - top))
        top = bottom
    }
    return out
}

/// Distance of the rows when a long answer fills its field (`answerLineLayout`).
func answerRowPitch(_ fontSize: CGFloat) -> CGFloat {
    return fontSize * 1.3
}

/// The field of an answer on writing lines, for tapping (the screen measures the letters, this estimates): the
/// bands over the lines; only an answer too long even at half size, rows filling the whole field, reaches further.
func answerFieldBands(_ text: String, lines: [CGRect], textHeight th: CGFloat) -> [CGRect] {
    var bands = answerBands(lines, rows: lines.count, textHeight: th)
    guard let first = bands.first, let last = bands.last else { return bands }
    let small = th * 1.1 * 0.5
    let pitch = answerRowPitch(small)
    let rows = 1 + max(0, ((last.maxY - first.maxY) / pitch).rounded(.down))
    let width = max(1, bands.map { $0.width }.reduce(0, +) / CGFloat(bands.count) - th * 0.3)
    // (about half a letter height per letter)
    let perRow = max(1, (width / (small * 0.55)).rounded(.down))
    let needed = (CGFloat(readingTrim(text).count) / perRow).rounded(.up)
    if needed > rows {
        bands[bands.count - 1].size.height += (needed - rows) * pitch
    }
    return bands
}

// MARK: - Words of an answer

/// One word of a spoken answer: its place in the answer's text (UTF-16, as NSString and the speech synthesizer count)
/// and where it stands on the page. The places come from the field's layout (`answerWords`, Export.swift).
struct AnswerWord {
    var range: NSRange
    var rect: CGRect
}

/// The words of an answer's text: runs without spaces (punctuation stays with its word).
func answerTokenRanges(_ text: String) -> [NSRange] {
    var out: [NSRange] = []
    var start: String.Index? = nil
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c.isWhitespace || c.isNewline {
            if let s = start {
                out.append(NSRange(s..<i, in: text))
                start = nil
            }
        } else if start == nil {
            start = i
        }
        i = text.index(after: i)
    }
    if let s = start { out.append(NSRange(s..<text.endIndex, in: text)) }
    return out
}

/// The word of an answer under the finger (or just beside it on its row); nil between rows or far off.
func answerWordIndex(_ words: [AnswerWord], at p: CGPoint, textHeight th: CGFloat) -> Int? {
    var best: Int? = nil
    var bd = CGFloat.infinity
    for (k, w) in words.enumerated() {
        let r = w.rect
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        if dy > th * 0.4 || dx > th * 0.6 { continue }
        let d = dx + dy * 2
        if d < bd {
            bd = d
            best = k
        }
    }
    return best
}

/// A word spoken anew replaces a word of an answer: punctuation and quotes around the old word stay; the recogniser's
/// full stop goes; at the start of a sentence a capital, after a small old word a small letter.
func answerReplacement(_ old: String, heard: String, sentenceStart: Bool) -> String {
    var core = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = core.last, ".!?,;:".contains(last) { core.removeLast() }
    if core.isEmpty { return "" }
    let chars = Array(old)
    // (an old "word" of punctuation only, e.g. "-", is replaced as a whole)
    if !chars.contains(where: { $0.isLetter || $0.isNumber }) { return core }
    let leadCount = chars.prefix(while: { !$0.isLetter && !$0.isNumber }).count
    let trailCount = leadCount < chars.count ? chars.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).count : 0
    let lead = String(chars.prefix(leadCount))
    let trail = String(chars.suffix(trailCount))
    if let f = core.first, f.isLetter {
        let rest = String(core.dropFirst())
        if sentenceStart {
            core = String(f).uppercased() + rest
        } else if let firstOld = chars.dropFirst(leadCount).first, firstOld.isLowercase {
            core = String(f).lowercased() + rest
        }
    }
    return lead + core + trail
}
