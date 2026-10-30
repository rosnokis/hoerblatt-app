import Foundation
import UIKit
import PDFKit

// The text a PDF made on a computer carries itself (e.g. a worksheet from Worksheet Crafter or Word): every word
// exactly, with its place on the page, also white writing on a dark table header. A scanned PDF has no such text;
// its pages are read like photos.

enum PDFText {
    /// The words of a page in pixels of a picture of the page drawn upright with `scale` pixels per PDF point
    /// (origin top-left). nil: the page is turned, or has hardly any text of its own (a scan).
    @MainActor static func words(_ page: PDFPage, scale k: CGFloat) -> [Word]? {
        guard ((page.rotation % 360) + 360) % 360 == 0, let text = page.string, k > 0 else { return nil }
        let box = page.bounds(for: .mediaBox)
        let ns = text as NSString
        let n = ns.length

        // runs of characters between spaces (and between symbols like ☐ that are not read)
        var pieces: [(text: String, rect: CGRect)] = []
        var i = 0
        while i < n {
            if pdfTextSeparates(ns.character(at: i)) {
                i += 1
                continue
            }
            var e = i
            while e < n && !pdfTextSeparates(ns.character(at: e)) { e += 1 }
            if let piece = pdfTextPiece(page, ns, i, e, box: box, scale: k) {
                pieces.append(piece)
            }
            i = e
        }
        let readable = pieces.filter { pdfTextHasLetter($0.text) }
        if readable.count < 3 { return nil }

        // text lines from the places (the PDF's own order can jump between columns)
        let heights = readable.map { $0.rect.height }.sorted()
        let typical = max(1, heights[heights.count / 2])
        let byPlace = pieces.sorted { a, b in
            if abs(a.rect.midY - b.rect.midY) > typical * 0.5 { return a.rect.midY < b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
        var words: [Word] = []
        var line = 0
        var lineMid: CGFloat = -1_000_000
        for p in byPlace {
            if abs(p.rect.midY - lineMid) > typical * 0.5 {
                if !words.isEmpty { line += 1 }
                lineMid = p.rect.midY
            }
            words.append(Word(id: words.count, text: p.text, rect: p.rect, line: line, box: nil, confidence: 1))
        }
        return words
    }
}

// MARK: - Helpers

/// Spaces, and symbols that stand on their own: check boxes, smileys, stars, arrows.
fileprivate func pdfTextSeparates(_ c: unichar) -> Bool {
    switch c {
    case 0x20, 0x09, 0x0A, 0x0D, 0xA0, 0x2002...0x200B, 0x202F, 0x3000:
        return true
    case 0x2190...0x21FF, 0x2500...0x27BF, 0x2B00...0x2BFF:
        // arrows, boxes ☐ ☑ ☒, smileys ☺ ☹, stars ★ ☆, ticks ✓ ✗
        return true
    default:
        return false
    }
}

/// One word from the characters lo..<hi: dotted lines glued to it ("dass……") are cut off, ligatures written out.
/// nil: nothing readable is left (a dotted writing line alone, dashes) – except a lone sentence mark.
@MainActor fileprivate func pdfTextPiece(_ page: PDFPage, _ ns: NSString, _ lo: Int, _ hi: Int,
                                         box: CGRect, scale k: CGFloat) -> (text: String, rect: CGRect)? {
    var a = lo
    var b = hi
    // dots and "…" at the ends belong to a writing line, not to the word (a single "." after it stays)
    while a < b && pdfTextIsDot(ns.character(at: a)) { a += 1 }
    var trailing = 0
    var t = b
    while t > a && pdfTextIsDot(ns.character(at: t - 1)) {
        trailing += 1
        t -= 1
    }
    if trailing >= 2 || (trailing == 1 && ns.character(at: b - 1) == 0x2026) { b = t }
    if a >= b { return nil }

    var text = ns.substring(with: NSRange(location: a, length: b - a))
    for (lig, plain) in [("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"), ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl")] {
        text = text.replacingOccurrences(of: lig, with: plain)
    }
    let lone = text == "." || text == "!" || text == "?"
    if !pdfTextHasLetter(text) && !lone { return nil }

    var union = CGRect.null
    for j in a..<b {
        let r = page.characterBounds(at: j)
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite, r.height > 0 else { continue }
        union = union.isNull ? r : union.union(r)
    }
    guard !union.isNull, union.width > 0 else { return nil }
    let rect = CGRect(x: (union.minX - box.minX) * k, y: (box.maxY - union.maxY) * k,
                      width: union.width * k, height: union.height * k)
    return (text: text, rect: rect)
}

fileprivate func pdfTextIsDot(_ c: unichar) -> Bool {
    return c == 0x2E || c == 0x2026
}

fileprivate func pdfTextHasLetter(_ t: String) -> Bool {
    return t.contains(where: { $0.isLetter || $0.isNumber })
}
