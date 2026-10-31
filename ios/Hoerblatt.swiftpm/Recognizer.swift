import Foundation
import UIKit
import Vision
import ImageIO
import CoreGraphics
import CoreImage

// Photo → page. The picture is drawn upright (a page photographed sideways is turned), read with Vision (the same
// recognition as Live Text, on the device, no upload), then LayoutAnalysis finds gaps, boxes and tables in the pixels.
// Everything here is plain CoreGraphics and Vision, so it runs off the main actor.

/// The stored page picture (upright, scale 1) and the page read from it.
struct Analysis {
    var image: UIImage
    /// New id, empty answers and marks, `drawing == Data()`.
    var page: Page
}

enum Recognizer {
    /// Takes a few seconds. `progress` (0…1, message for the waiting screen) is called on any thread.
    /// `textWords`: the words of a PDF page that has its own text, in pixels of `input` (upright, scale 1, long side
    /// at most 2400): then nothing is turned or read, only the layout is analysed.
    /// `cleanPage`: a page drawn from a PDF (tables may be as tall as the page).
    static func analyze(_ input: UIImage, textWords: [Word]? = nil, cleanPage: Bool = false,
                        progress: @escaping (Double, String) -> Void) async -> Analysis {
        progress(0.02, "Das Foto wird vorbereitet …")
        guard let source = rcCGImage(input),
              let base = rcDraw(source, orientation: input.imageOrientation, maxSide: 2400) else {
            return rcEmptyAnalysis(input)
        }

        var cg = base
        let tokens: [Word]
        var fromText = false
        if let given = textWords, base.width == source.width, base.height == source.height {
            tokens = given
            fromText = true
        } else {
            // a page photographed sideways is turned upright first
            progress(0.06, "Das Foto wird ausgerichtet …")
            let turns = rcUprightTurns(base)
            if turns != 0, let turned = rcDraw(base, orientation: rcOrientation(turns), maxSide: 2400) {
                cg = turned
            }
            progress(0.15, "Das Blatt wird gelesen …")
            tokens = rcRecognize(cg, progress: progress)
        }

        progress(0.88, "Lücken und Kästen werden gesucht …")
        var words: [Word] = []
        var gaps: [Gap] = []
        var boxes: [PrintedBox] = []
        var textHeight = rcMedianHeight(tokens)
        if let pixels = PixelImage(cgImage: cg) {
            let layout = LayoutAnalysis.analyze(pixels, words: tokens, cleanPage: fromText || cleanPage)
            // LayoutResult.words (optional extra): the same words cleaned up – corrected rects, a lone "." moved
            // onto the word before it. Same ids and order as the input, so it can stand in for it.
            let cleaned = layout.words.count == tokens.count ? layout.words : tokens
            for b in layout.boxes {
                boxes.append(PrintedBox(id: boxes.count, rect: b.rect, cell: b.cell))
            }
            // ids are counted anew (id == index), box references follow
            for w in cleaned where !layout.dropped.contains(w.id) && rcHasLetterOrDigit(w.text) {
                var n = w
                n.id = words.count
                n.box = nil
                if let b = layout.wordBox[w.id], b >= 0, b < boxes.count { n.box = b }
                words.append(n)
            }
            gaps = layout.gaps
            if layout.textHeight.isFinite && layout.textHeight > 1 { textHeight = layout.textHeight }
        } else {
            for w in tokens where rcHasLetterOrDigit(w.text) {
                var n = w
                n.id = words.count
                words.append(n)
            }
        }

        let size = CGSize(width: cg.width, height: cg.height)
        let title = rcTitle(words, textHeight: textHeight, pageHeight: size.height)
        var page = Page(id: UUID(), created: Date(), title: title, pixelSize: size, textHeight: textHeight,
                        words: words, gaps: gaps, boxes: boxes, answers: [], marks: [], drawing: Data())
        page.visionWords = tokens
        progress(1, "Fertig")
        return Analysis(image: UIImage(cgImage: cg, scale: 1, orientation: .up), page: page)
    }
}

// MARK: - Pictures

/// A picture that cannot be drawn: an empty page (the caller then reports "kaum etwas lesen").
fileprivate func rcEmptyAnalysis(_ input: UIImage) -> Analysis {
    let size = CGSize(width: max(1, (input.size.width * input.scale).rounded()),
                      height: max(1, (input.size.height * input.scale).rounded()))
    let page = Page(id: UUID(), created: Date(), title: "Seite", pixelSize: size, textHeight: 20,
                    words: [], gaps: [], boxes: [], answers: [], marks: [], drawing: Data())
    return Analysis(image: input, page: page)
}

fileprivate func rcCGImage(_ image: UIImage) -> CGImage? {
    if let cg = image.cgImage { return cg }
    // a few sources hand over an image backed by CoreImage only
    if let ci = image.ciImage, !ci.extent.isInfinite, !ci.extent.isEmpty {
        return CIContext(options: nil).createCGImage(ci, from: ci.extent)
    }
    return nil
}

/// k quarter turns clockwise, as UIImage orientation of an upright picture.
fileprivate func rcOrientation(_ k: Int) -> UIImage.Orientation {
    switch k {
    case 1: return .right
    case 2: return .down
    case 3: return .left
    default: return .up
    }
}

/// Draws the pixels as UIImage would show them with `orientation` (`.right` = turned 90° clockwise), long side at
/// most `maxSide`, on white, RGB 8 bit. Plain CoreGraphics: safe on any thread.
fileprivate func rcDraw(_ cg: CGImage, orientation: UIImage.Orientation, maxSide: CGFloat) -> CGImage? {
    let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
    guard sw >= 1, sh >= 1 else { return nil }
    let sideways: Bool
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored: sideways = true
    default: sideways = false
    }
    let uw = sideways ? sh : sw
    let uh = sideways ? sw : sh
    let k = min(1, maxSide / max(uw, uh))
    let w = max(1, Int((uw * k).rounded()))
    let h = max(1, Int((uh * k).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let W = CGFloat(w), H = CGFloat(h)
    ctx.interpolationQuality = .high
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // CoreGraphics has y upwards; these are the usual turns for each UIImage orientation
    var t = CGAffineTransform.identity
    switch orientation {
    case .down, .downMirrored:
        t = t.translatedBy(x: W, y: H).rotated(by: CGFloat.pi)
    case .left, .leftMirrored:
        t = t.translatedBy(x: W, y: 0).rotated(by: CGFloat.pi / 2)
    case .right, .rightMirrored:
        t = t.translatedBy(x: 0, y: H).rotated(by: -CGFloat.pi / 2)
    default:
        break
    }
    switch orientation {
    case .upMirrored, .downMirrored:
        t = t.translatedBy(x: W, y: 0).scaledBy(x: -1, y: 1)
    case .leftMirrored, .rightMirrored:
        t = t.translatedBy(x: H, y: 0).scaledBy(x: -1, y: 1)
    default:
        break
    }
    ctx.concatenate(t)
    if sideways {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: H, height: W))
    } else {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    }
    return ctx.makeImage()
}

// MARK: - Sideways photos

/// How many quarter turns make the text upright: a quick read of a small copy; only if that finds little real text,
/// also sideways (like uprightTurns in index.html).
fileprivate func rcUprightTurns(_ cg: CGImage) -> Int {
    guard let small = rcDraw(cg, orientation: .up, maxSide: 1600) else { return 0 }
    let s0 = rcProbeScore(small)
    if s0 >= 12 { return 0 }
    var best = 0
    var bestScore = s0
    for k in [1, 3] {
        guard let turned = rcDraw(small, orientation: rcOrientation(k), maxSide: 1600) else { continue }
        let sk = rcProbeScore(turned)
        if Double(sk) > Double(bestScore) * 1.5 && sk > bestScore + 3 {
            best = k
            bestScore = sk
        }
    }
    return best
}

/// Number of real-looking words in lines running across the picture (`.fast` recognition).
fileprivate func rcProbeScore(_ cg: CGImage) -> Int {
    var observations: [VNRecognizedTextObservation] = []
    for languages in [["de-DE"], ["en-US"]] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = languages
        // no correction: it would turn letter salad from sideways text into words
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        do {
            try VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([request])
            observations = request.results ?? []
            break
        } catch {
            continue
        }
    }
    let W = CGFloat(cg.width), H = CGFloat(cg.height)
    var n = 0
    for obs in observations {
        let b = obs.boundingBox
        // sideways text that Vision still finds runs up and down
        if b.width * W < b.height * H * 1.5 { continue }
        guard let cand = obs.topCandidates(1).first else { continue }
        for piece in cand.string.split(whereSeparator: { $0.isWhitespace }) where rcWordLike(String(piece)) {
            n += 1
        }
    }
    return n
}

// MARK: - Reading

/// Words with their own pixel rectangles. `line` numbers Vision's text lines from top to bottom, `id` == index.
fileprivate func rcRecognize(_ cg: CGImage, progress: @escaping (Double, String) -> Void) -> [Word] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["de-DE"]
    request.usesLanguageCorrection = true
    // small print on a whole page must not be skipped
    request.minimumTextHeight = 1.0 / 150.0
    request.progressHandler = { _, fraction, _ in
        progress(0.15 + 0.7 * min(1, max(0, fraction)), "Das Blatt wird gelesen …")
    }
    var observations: [VNRecognizedTextObservation] = []
    do {
        try VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([request])
        observations = request.results ?? []
    } catch {
        // German not offered (should not happen on iOS 17): read with Vision's default language
        let retry = VNRecognizeTextRequest()
        retry.recognitionLevel = .accurate
        retry.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([retry])
            observations = retry.results ?? []
        } catch {
            observations = []
        }
    }

    let W = CGFloat(cg.width), H = CGFloat(cg.height)
    // top to bottom (Vision: origin bottom-left); rows are rebuilt from the geometry later anyway
    let lines = observations.sorted { a, b in
        if a.boundingBox.maxY != b.boundingBox.maxY { return a.boundingBox.maxY > b.boundingBox.maxY }
        return a.boundingBox.minX < b.boundingBox.minX
    }
    var words: [Word] = []
    for (li, obs) in lines.enumerated() {
        guard let cand = obs.topCandidates(1).first else { continue }
        let s = cand.string
        let lineBox = obs.boundingBox
        // text running up or down (a label along the margin) is not part of the worksheet's lines
        if lineBox.height * H > lineBox.width * W * 2.5 && s.count >= 3 { continue }
        let conf = cand.confidence
        for r in rcPieces(s) {
            let t = String(s[r])
            if rcHasLetterOrDigit(t) {
                if !rcPlausible(t, Double(conf) * 100) { continue }
            } else if !(rcIsSentenceMark(t) && conf >= 0.2) {
                // only a lone "." "!" "?" goes on: LayoutAnalysis uses it for the sentence end and then drops it
                continue
            }
            let rect = rcPixelRect(rcBox(cand, r, text: s, line: lineBox), W, H)
            if !(rect.width >= 1 && rect.height >= 1) { continue }
            words.append(Word(id: words.count, text: t, rect: rect, line: li, box: nil, confidence: conf))
        }
    }
    return words
}

/// Normalised Vision rectangle (origin bottom-left) → pixels (origin top-left), clamped to the picture.
fileprivate func rcPixelRect(_ bb: CGRect, _ W: CGFloat, _ H: CGFloat) -> CGRect {
    let x0 = max(0, min(W, bb.minX * W)), x1 = max(0, min(W, bb.maxX * W))
    let y0 = max(0, min(H, (1 - bb.maxY) * H)), y1 = max(0, min(H, (1 - bb.minY) * H))
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

/// The word's own box (normalised). Falls back to its share of the line when Vision has none.
fileprivate func rcBox(_ cand: VNRecognizedText, _ r: Range<String.Index>, text s: String, line: CGRect) -> CGRect {
    let total = max(1, s.count)
    let start = s.distance(from: s.startIndex, to: r.lowerBound)
    let len = max(1, s.distance(from: r.lowerBound, to: r.upperBound))
    let share = CGRect(x: line.minX + line.width * CGFloat(start) / CGFloat(total), y: line.minY,
                       width: line.width * CGFloat(len) / CGFloat(total), height: line.height)
    guard let found = try? cand.boundingBox(for: r) else { return share }
    let bb = found.boundingBox
    guard bb.minX.isFinite, bb.minY.isFinite, bb.width.isFinite, bb.height.isFinite,
          bb.width > 0, bb.height > 0 else { return share }
    // the whole line's box for a word that is only part of it
    if len * 10 < total * 6 && bb.width > line.width * 0.9 { return share }
    return bb
}

// MARK: - Words

/// Characters that a printed gap line is read as.
fileprivate let rcGapChars: Set<Character> = ["_", "-", "–", "—", "…"]

/// The pieces of a recognised line as ranges of the line's string: split on spaces, and on "_" (a gap line read
/// into the text: "____nichts", "Sp___ielen" with a box inside the word, "Fell____." with its sentence mark).
fileprivate func rcPieces(_ s: String) -> [Range<String.Index>] {
    var out: [Range<String.Index>] = []
    for sub in s.split(whereSeparator: { $0.isWhitespace || $0 == "_" }) {
        rcTrim(s, sub.startIndex..<sub.endIndex, into: &out)
    }
    return out
}

/// "––nichts", "Fell––.", "|Wort|": a gap line (dashes) or a frame read as part of the word (tokensOf in index.html).
/// Keeps the word's own part, and a sentence mark after the gap as a piece of its own.
fileprivate func rcTrim(_ s: String, _ r: Range<String.Index>, into out: inout [Range<String.Index>]) {
    var lo = r.lowerBound
    var hi = r.upperBound
    // frame edges
    while lo < hi && s[lo] == "|" { lo = s.index(after: lo) }
    while hi > lo && s[s.index(before: hi)] == "|" { hi = s.index(before: hi) }
    // a gap in front of the word (dots before it belong to the gap)
    var a = lo
    while a < hi && (s[a] == "." || s[a] == "…") { a = s.index(after: a) }
    var b = a
    var run = 0
    var underscore = false
    while b < hi && rcGapChars.contains(s[b]) {
        if s[b] == "_" { underscore = true }
        run += 1
        b = s.index(after: b)
    }
    if run >= 2 || underscore { lo = b }
    // a gap after the word, maybe followed by a sentence mark (a single "-" stays: hyphenation)
    var markLo = hi
    if hi > lo {
        let p = s.index(before: hi)
        if ".,!?".contains(s[p]) { markLo = p }
    }
    var c = markLo
    var run2 = 0
    var underscore2 = false
    while c > lo {
        let p = s.index(before: c)
        if !rcGapChars.contains(s[p]) { break }
        if s[p] == "_" { underscore2 = true }
        run2 += 1
        c = p
    }
    if run2 >= 2 || underscore2 {
        if c > lo { out.append(lo..<c) }
        if markLo < hi && s[markLo] != "," { out.append(markLo..<hi) }
    } else if hi > lo {
        out.append(lo..<hi)
    }
}

fileprivate func rcHasLetterOrDigit(_ t: String) -> Bool {
    return t.contains(where: { $0.isLetter || $0.isNumber })
}

fileprivate func rcMatches(_ t: String, _ pattern: String) -> Bool {
    return t.range(of: pattern, options: .regularExpression) != nil
}

/// A lone "." "!" "?" (not "..." – that often marks a gap).
fileprivate func rcIsSentenceMark(_ t: String) -> Bool {
    return rcMatches(t, #"^(\.|!|\?|!\?|\?!)["“”»«‘’]?$"#)
}

/// cleanWord: punctuation at both ends removed.
fileprivate func rcClean(_ t: String) -> String {
    let chars = Array(t)
    var a = 0
    var b = chars.count
    while a < b && !(chars[a].isLetter || chars[a].isNumber) { a += 1 }
    while b > a && !(chars[b - 1].isLetter || chars[b - 1].isNumber) { b -= 1 }
    return String(chars[a..<b])
}

/// wordLike (index.html): looks like a normal German word.
fileprivate func rcWordLike(_ t: String) -> Bool {
    if !rcMatches(t, #"^[„"‚]?[A-ZÄÖÜa-zäöüß][a-zäöüß]{2,}[.,!?:;"“‘]?$"#) { return false }
    if t.range(of: "[aeiouäöüy]", options: [.regularExpression, .caseInsensitive]) == nil { return false }
    return t.range(of: #"(.)\1\1"#, options: [.regularExpression, .caseInsensitive]) == nil
}

fileprivate let rcShortWords: Set<String> = ["er", "es", "du", "im", "in", "an", "am", "um", "zu", "ab", "ob", "so",
                                             "da", "wo", "ja"]

/// plausible (index.html): drawings give letter salad like "EN EEE AN" or "0000". `cf` 0…100.
/// Vision's confidence belongs to the whole line (coarse: about 1, 0.5 or 0.3), so a sure line keeps all its words.
fileprivate func rcPlausible(_ t: String, _ cf: Double) -> Bool {
    let c = rcClean(t)
    if rcMatches(c, #"^\d+([.,:]\d+)?$"#) {
        let need: Double = c.count < 2 ? 75 : 50
        return cf >= need && !rcMatches(c, #"(\d)\1\1|^0\d"#)
    }
    if rcMatches(c, "^[A-ZÄÖÜ]{2,}$") { return cf >= 85 }
    if c.count < 2 { return cf >= 75 }
    if cf >= 50 { return true }
    return rcWordLike(t) || (rcShortWords.contains(c.lowercased()) && cf >= 20)
}

fileprivate func rcMedianHeight(_ words: [Word]) -> CGFloat {
    let hs = words.map { $0.rect.height }.filter { $0.isFinite && $0 > 0 }.sorted()
    if hs.isEmpty { return 20 }
    return hs[hs.count / 2]
}

// MARK: - Title

/// The first 1–4 words of the topmost larger line (a heading) in the upper half, at most 40 characters;
/// otherwise "Seite".
fileprivate func rcTitle(_ words: [Word], textHeight: CGFloat, pageHeight: CGFloat) -> String {
    var byLine: [Int: [Word]] = [:]
    for w in words { byLine[w.line, default: []].append(w) }
    var bestTop = CGFloat.greatestFiniteMagnitude
    var bestLine: [Word] = []
    for (_, ws) in byLine {
        let hs = ws.map { $0.rect.height }.sorted()
        guard !hs.isEmpty, hs[hs.count / 2] >= textHeight * 1.3 else { continue }
        guard ws.contains(where: { w in w.text.filter { $0.isLetter }.count >= 2 }) else { continue }
        let top = ws.map { $0.rect.minY }.min() ?? pageHeight
        if top < pageHeight * 0.5 && top < bestTop {
            bestTop = top
            bestLine = ws
        }
    }
    var parts: [String] = []
    var length = 0
    for w in bestLine.sorted(by: { $0.rect.minX < $1.rect.minX }) {
        let t = rcClean(w.text)
        if t.isEmpty { continue }
        // a task number in front of the heading is left out
        if parts.isEmpty && !t.contains(where: { $0.isLetter }) { continue }
        let add = parts.isEmpty ? t.count : t.count + 1
        if length + add > 40 {
            if parts.isEmpty { parts.append(String(t.prefix(40))) }
            break
        }
        parts.append(t)
        length += add
        if parts.count == 4 { break }
    }
    let title = parts.joined(separator: " ")
    return title.isEmpty ? "Seite" : title
}
