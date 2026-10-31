import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// What a tap reads – the same for the page (PageController) and the self test, and on Linux for the test build
// (tools/linuxtest). Only Foundation/CoreGraphics here: no UIKit, no speaking.

/// What one tap reads, and what lights up meanwhile.
struct Utterance {
    var parts: [SpeechPart]
    var rects: [CGRect]

    /// As one line of text, "*" for the tone.
    var text: String {
        return parts.map { part -> String in
            switch part {
            case .text(let t): return t
            case .tone: return "*"
            }
        }.joined(separator: " ")
    }
}

/// What lies under the finger (answers aside): a word (index in `page.words`), a gap, or nothing.
enum TapTarget: Equatable {
    case word(Int)
    case gap(Int)
    case nothing
}

extension Reading {
    /// A word first; a gap where there is no word; then a word just next to the finger.
    func target(at p: CGPoint) -> TapTarget {
        var wordId = wordAt(p, loose: false)
        let gapIndex: Int? = wordId == nil ? gapAt(p) : nil
        if wordId == nil && gapIndex == nil { wordId = wordAt(p, loose: true) }
        if let k = gapIndex, k >= 0, k < page.gaps.count { return .gap(k) }
        if let wid = wordId, let i = page.words.firstIndex(where: { $0.id == wid }) { return .word(i) }
        return .nothing
    }

    /// The words of a printed box as one text.
    func boxText(_ bx: Int) -> String {
        return hearingTrim(boxWords(bx).map { $0.text }.joined(separator: " "))
    }

    func boxRect(_ bx: Int) -> CGRect? {
        guard bx >= 0 && bx < page.boxes.count else { return nil }
        return page.boxes[bx].rect
    }

    func isCell(_ bx: Int) -> Bool {
        guard bx >= 0 && bx < page.boxes.count else { return false }
        return page.boxes[bx].cell == true
    }

    /// Wort on word `i`: a word in a printed box reads the whole box (`wholeBox`), unless it is a table cell or
    /// the same word was tapped just before (`again`).
    func hearWord(_ i: Int, boxesTogether: Bool, again: Bool) -> (utterance: Utterance, wholeBox: Bool) {
        let w = page.words[i]
        if boxesTogether, !again, let bx = w.box, !isCell(bx), let frame = boxRect(bx) {
            let text = boxText(bx)
            if !text.isEmpty { return (Utterance(parts: [.text(text)], rects: [frame]), true) }
        }
        let clean = Reading.cleanWord(w.text)
        return (Utterance(parts: [.text(clean.isEmpty ? w.text : clean)], rects: [w.rect]), false)
    }

    /// Satz on word `i`: the sentence around it; a word in a printed box or table cell reads the box.
    func hearSentence(_ i: Int) -> Utterance {
        let w = page.words[i]
        if let bx = w.box, let frame = boxRect(bx) {
            let text = boxText(bx)
            if !text.isEmpty { return Utterance(parts: [.text(text)], rects: [frame]) }
        }
        let s = sentence(atWord: w.id)
        return Utterance(parts: s.parts, rects: s.rects)
    }

    /// A tapped gap: an empty table cell or writing field says its column heading ("Nomen");
    /// otherwise the answer in it, the tone, or (Satz) the whole sentence.
    func hearGap(_ k: Int, wholeSentence: Bool) -> Utterance {
        let g = page.gaps[k]
        let said = answerText(onGap: k)
        let head = hearingTrim(g.head ?? "")
        if said.isEmpty && !head.isEmpty { return Utterance(parts: [.text(head)], rects: [g.rect]) }
        if wholeSentence {
            let s = sentence(atGap: k)
            return Utterance(parts: s.parts, rects: s.rects)
        }
        if !said.isEmpty { return Utterance(parts: [.text(said)], rects: [g.rect]) }
        return Utterance(parts: [.tone], rects: [g.rect])
    }
}

// MARK: - Report of a page (Fehlersuche, Selbsttest, Linux test build)

enum PageReport {
    /// Words, boxes, gaps and every sentence once, as the diagnosis file shows them.
    static func dict(_ page: Page, reading: Reading) -> [String: Any] {
        var out: [String: Any] = [
            "title": page.title,
            "pixelSize": [hearingRound(page.pixelSize.width), hearingRound(page.pixelSize.height)],
            "textHeight": hearingRound(page.textHeight)
        ]
        out["words"] = page.words.map { w -> [String: Any] in
            var d: [String: Any] = ["i": w.id, "t": w.text, "r": hearingRect(w.rect), "line": w.line,
                                    "conf": hearingRound(CGFloat(w.confidence))]
            if let b = w.box { d["box"] = b }
            return d
        }
        out["boxes"] = page.boxes.map { b -> [String: Any] in
            var d: [String: Any] = ["i": b.id, "r": hearingRect(b.rect)]
            if b.cell == true { d["cell"] = true }
            return d
        }
        out["gaps"] = page.gaps.map { g -> [String: Any] in
            var d: [String: Any] = ["kind": g.kind.rawValue, "r": hearingRect(g.rect), "inText": g.inText,
                                    "ends": g.endsSentence]
            if let h = g.head { d["head"] = h }
            return d
        }
        // every sentence once, as the Satz button reads it ("*" = tone)
        var seen = Set<String>()
        var sentences: [String] = []
        for w in page.words {
            let s = reading.sentence(atWord: w.id).parts.map { part -> String in
                switch part {
                case .text(let t): return t
                case .tone: return "*"
                }
            }.joined(separator: " ")
            if !s.isEmpty && !seen.contains(s) {
                seen.insert(s)
                sentences.append(s)
            }
        }
        out["sentences"] = sentences
        return out
    }

    /// Every word and gap tapped in its middle, with Wort and Satz: what lies there ("w12", "g3", "-") and what
    /// is read ("*" = tone). "wort2": second tap on a word in a box. Answers are left out (`page` without them).
    static func taps(_ page: Page, reading: Reading, boxesTogether: Bool) -> [[String: Any]] {
        func hit(_ p: CGPoint) -> String {
            switch reading.target(at: p) {
            case .word(let i): return "w\(i)"
            case .gap(let k): return "g\(k)"
            case .nothing: return "-"
            }
        }
        var out: [[String: Any]] = []
        for i in page.words.indices {
            let r = page.words[i].rect
            let first = reading.hearWord(i, boxesTogether: boxesTogether, again: false)
            let satz = reading.hearSentence(i)
            // (the area the sentence lights up: a sentence jumping across the page shows as a huge area)
            let area = satz.rects.reduce(CGRect.null) { $0.union($1) }
            var d: [String: Any] = ["w": i, "hit": hit(CGPoint(x: r.midX, y: r.midY)),
                                    "wort": first.utterance.text, "satz": satz.text, "satzArea": hearingRect(area)]
            if first.wholeBox {
                d["wort2"] = reading.hearWord(i, boxesTogether: boxesTogether, again: true).utterance.text
            }
            out.append(d)
        }
        for k in page.gaps.indices {
            let r = page.gaps[k].rect
            out.append(["g": k, "hit": hit(CGPoint(x: r.midX, y: r.midY)),
                        "wort": reading.hearGap(k, wholeSentence: false).text,
                        "satz": reading.hearGap(k, wholeSentence: true).text])
        }
        return out
    }
}

func hearingTrim(_ s: String) -> String {
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func hearingRound(_ v: CGFloat) -> Double {
    if !v.isFinite { return -1 }
    return (Double(v) * 10).rounded() / 10
}

func hearingRect(_ r: CGRect) -> [Double] {
    if r.isNull || r.isInfinite { return [] }
    return [hearingRound(r.minX), hearingRound(r.minY), hearingRound(r.width), hearingRound(r.height)]
}
