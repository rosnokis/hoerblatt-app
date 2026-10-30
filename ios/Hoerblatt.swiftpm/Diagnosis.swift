import Foundation
import UIKit
import PDFKit

// Fehlersuche: a JSON file about the open page for the developer – the words with their places, boxes, gaps and
// the sentences as they are read; for a page of a Heft also what PDFKit gives for each character of the PDF page.
// Only printed text of the page is in it: no answers, marks or pen strokes.

enum Diagnosis {
    @MainActor static func file(for c: PageController, app: AppState) -> URL? {
        let page = c.page
        var out: [String: Any] = [
            "format": "hoerblatt-diagnose-1",
            "created": ISO8601DateFormatter().string(from: Date()),
            "title": page.title,
            "pixelSize": [diagRound(page.pixelSize.width), diagRound(page.pixelSize.height)],
            "imagePixels": [c.image.cgImage?.width ?? 0, c.image.cgImage?.height ?? 0],
            "textHeight": diagRound(page.textHeight)
        ]
        out["words"] = page.words.map { w -> [String: Any] in
            var d: [String: Any] = ["i": w.id, "t": w.text, "r": diagRect(w.rect), "line": w.line,
                                    "conf": diagRound(CGFloat(w.confidence))]
            if let b = w.box { d["box"] = b }
            return d
        }
        out["boxes"] = page.boxes.map { ["i": $0.id, "r": diagRect($0.rect)] as [String: Any] }
        out["gaps"] = page.gaps.map { g -> [String: Any] in
            var d: [String: Any] = ["kind": g.kind.rawValue, "r": diagRect(g.rect), "inText": g.inText,
                                    "ends": g.endsSentence]
            if let h = g.head { d["head"] = h }
            return d
        }
        // every sentence once, as the Satz button reads it ("*" = tone)
        let reading = c.reading
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

        if let heftId = page.heft, let h = app.store.heft(heftId) {
            let titles: [String] = h.pages.map { pid in app.store.pages.first(where: { $0.id == pid })?.title ?? "?" }
            let heftInfo: [String: Any] = ["title": h.title, "total": h.pageTotal, "numbers": h.pageNumbers,
                                           "lastPage": h.lastPage, "thisPage": h.number(of: page.id) ?? -1,
                                           "titles": titles]
            out["heft"] = heftInfo
            if let n = page.heftPage, let doc = PDFDocument(url: app.store.heftPDFURL(heftId)),
               let pdfPage = doc.page(at: n) {
                out["pdf"] = diagPDF(pdfPage)
            }
        }

        guard JSONSerialization.isValidJSONObject(out),
              let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Hoerblatt-Diagnose", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let name = "Hoerblatt-Diagnose-" + page.title.replacingOccurrences(of: " ", with: "-") + ".json"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }
}

/// What PDFKit says about the page: its text, and each character's place from a selection and from characterBounds
/// (PDF points, origin bottom-left), plus the words PDFText makes of it.
@MainActor fileprivate func diagPDF(_ page: PDFPage) -> [String: Any] {
    let box = page.bounds(for: .mediaBox)
    var d: [String: Any] = ["mediaBox": diagRect(box), "rotation": page.rotation]
    let text = page.string ?? ""
    d["string"] = text
    let ns = text as NSString
    var chars: [[Any]] = []
    for j in 0..<ns.length {
        let c = ns.substring(with: NSRange(location: j, length: 1))
        var sel: [Double] = []
        if let s = page.selection(for: NSRange(location: j, length: 1)) {
            sel = diagRect(s.bounds(for: page))
        }
        chars.append([j, c, sel, diagRect(page.characterBounds(at: j))])
    }
    d["chars"] = chars
    let k = 2400 / max(1, max(box.width, box.height))
    d["pdfTextWords"] = (PDFText.words(page, scale: k) ?? []).map { ["t": $0.text, "r": diagRect($0.rect)] as [String: Any] }
    // the lines as PDFKit selects them
    if let all = page.selection(for: box) {
        d["lines"] = all.selectionsByLine().map { ["t": $0.string ?? "", "r": diagRect($0.bounds(for: page))] as [String: Any] }
    }
    return d
}

fileprivate func diagRound(_ v: CGFloat) -> Double {
    if !v.isFinite { return -1 }
    return (Double(v) * 10).rounded() / 10
}

fileprivate func diagRect(_ r: CGRect) -> [Double] {
    if r.isNull || r.isInfinite { return [] }
    return [diagRound(r.minX), diagRound(r.minY), diagRound(r.width), diagRound(r.height)]
}
