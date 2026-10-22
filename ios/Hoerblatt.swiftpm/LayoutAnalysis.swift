import Foundation
import CoreGraphics

// Finds answer lines (gaps), printed boxes, writing fields, grey squares and tables in the page picture itself.
// Port of analyzeLayout and of the word clean-up in buildDoc (index.html, the tested web version); the comments
// name the JS part each piece comes from. Pure Swift on raw pixels, runs off the main actor; a few seconds is fine.

struct LayoutResult {
    var gaps: [Gap]
    /// ids = index.
    var boxes: [PrintedBox]
    /// Word id → box index.
    var wordBox: [Int: Int]
    /// Word ids to leave out (letter salad in writing fields, words read twice, unsure coloured handwriting …).
    var dropped: Set<Int>
    /// Typical height of the printed text in pixels.
    var textHeight: CGFloat
    /// Extra, optional to use: the input words after clean-up (same ids and order as the input, dropped ones
    /// included). Rects may be corrected (a box much taller than its line, a box stretched over a gap line),
    /// a word followed by a lone "." gets the "." (the sentence ends there), `box` is set from `wordBox`.
    var words: [Word] = []
}

enum LayoutAnalysis {
    static func analyze(_ image: PixelImage, words: [Word]) -> LayoutResult {
        let W = image.width, H = image.height
        guard W >= 16, H >= 16, image.gray.count >= W * H, image.rgba.count >= W * H * 4 else {
            // nothing to analyse: keep the words as they are
            let heights = words.map { Double($0.rect.height) }.sorted()
            let typical: Double = heights.isEmpty ? 20 : heights[heights.count >> 1]
            return LayoutResult(gaps: [], boxes: [], wordBox: [:], dropped: [], textHeight: CGFloat(typical), words: words)
        }
        // buildDoc: clean the recognised words first
        let prep = laPrepare(words, image)
        let hs = prep.words.map { $0.y1 - $0.y0 }.sorted()
        let mh: Double = hs.isEmpty ? Double(H) * 0.022 : hs[hs.count >> 1]   // typical text height

        // analyzeLayout: brightness sums, ink, lines
        let gray = image.gray
        let sums = laIntegral(gray, W, H)
        let ink = laInkMap(gray: gray, S: sums, W: W, H: H, r: max(8, laRound(mh * 0.8)))
        let segs = laLineSegments(gray: gray, W: W, H: H, mh: mh)
        let engine = LAEngine(W: W, H: H, gray: gray, S: sums, ink: ink, mh: mh, words: prep.words)
        engine.run(hSegs: segs.h, vSegs: segs.v)
        engine.finishDoc(punct: prep.punct)
        return engine.result(input: words, dropped: prep.dropped)
    }
}

// MARK: - Small helpers

/// tokensOf → plausible: drop letter salad from drawings. Thresholds were tuned for tesseract's confidences;
/// set to false if Vision's coarse confidences drop good words.
fileprivate let laCheckPlausible = true

fileprivate func laSafeInt(_ v: Double) -> Int {
    if !v.isFinite { return 0 }
    return Int(min(max(v, -1e12), 1e12))
}
/// Math.round
fileprivate func laRound(_ v: Double) -> Int { return laSafeInt((v + 0.5).rounded(.down)) }
fileprivate func laRoundD(_ v: Double) -> Double { return (v + 0.5).rounded(.down) }
fileprivate func laCeil(_ v: Double) -> Int { return laSafeInt(v.rounded(.up)) }
fileprivate func laFloor(_ v: Double) -> Int { return laSafeInt(v.rounded(.down)) }
/// JS `v | 0`
fileprivate func laTrunc(_ v: Double) -> Int { return laSafeInt(v.rounded(.towardZero)) }

fileprivate func laCGRect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CGRect {
    return CGRect(x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
}

fileprivate enum LAText {
    static let short: Set<String> = ["er", "es", "du", "im", "in", "an", "am", "um", "zu", "ab", "ob", "so", "da", "wo", "ja"]

    static func matches(_ t: String, _ pattern: String, ignoreCase: Bool = false) -> Bool {
        var opts: String.CompareOptions = [.regularExpression]
        if ignoreCase { opts.insert(.caseInsensitive) }
        return t.range(of: pattern, options: opts) != nil
    }
    /// speakable: has a letter or digit and is not only "____"
    static func speakable(_ t: String) -> Bool {
        let hasAlnum = t.contains(where: { $0.isLetter || $0.isNumber })
        return hasAlnum && !t.allSatisfy({ $0 == "_" })
    }
    /// cleanWord: punctuation at both ends removed
    static func cleanWord(_ t: String) -> String {
        let chars = Array(t)
        var a = 0
        var b = chars.count
        while a < b && !(chars[a].isLetter || chars[a].isNumber) { a += 1 }
        while b > a && !(chars[b - 1].isLetter || chars[b - 1].isNumber) { b -= 1 }
        return String(chars[a..<b])
    }
    static func core(_ t: String) -> String { return cleanWord(t).lowercased() }
    /// wordLike: looks like a normal German word
    static func wordLike(_ t: String) -> Bool {
        if !matches(t, #"^[„"‚]?[A-ZÄÖÜa-zäöüß][a-zäöüß]{2,}[.,!?:;"“‘]?$"#) { return false }
        if !matches(t, "[aeiouäöüy]", ignoreCase: true) { return false }
        return !matches(t, #"(.)\1\1"#, ignoreCase: true)
    }
    /// plausible: drawings produce letter salad like "EN EEE AN" or "0000"
    static func plausible(_ t: String, _ cf: Double) -> Bool {
        let c = cleanWord(t)
        if matches(c, #"^\d+([.,:]\d+)?$"#) {
            let need: Double = c.count < 2 ? 75 : 50
            return cf >= need && !matches(c, #"(\d)\1\1|^0\d"#)
        }
        if matches(c, "^[A-ZÄÖÜ]{2,}$") { return cf >= 85 }
        if c.count < 2 { return cf >= 75 }
        if cf >= 50 { return true }
        return wordLike(t) || (short.contains(c.lowercased()) && cf >= 20)
    }
    static func isDigits(_ t: String) -> Bool {
        return !t.isEmpty && t.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 })
    }
}

// MARK: - Working types

fileprivate struct LARect {
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double
    /// writing field (Lineatur)
    var lin: Bool = false
    /// grey filled square
    var square: Bool = false
}

/// JS word {t, x0, y0, x1, y1, li, cf, bx, junk, col, end}
fileprivate struct LAWord {
    var id: Int
    var t: String
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double
    var li: Int
    /// 0…100
    var cf: Double
    var bx: Int = -1
    var junk: Bool = false
    /// ink colour differs from the usual print (example answer in coloured handwriting)
    var col: Bool = false
    var end: Bool = false

    var cy: Double { return (y0 + y1) / 2 }
    var r: LARect { return LARect(x0: x0, y0: y0, x1: x1, y1: y1) }
}

/// A traced line piece: u along the line, v = a + b·u across it.
fileprivate struct LASeg {
    var u0: Int
    var u1: Int
    var a: Double
    var b: Double
}

fileprivate struct LAHLine {
    var x0: Double
    var x1: Double
    var y: Double
    var a: Double
    var b: Double
    func at(_ x: Double) -> Double { return a + b * x }
}

fileprivate struct LAVLine {
    var y0: Double
    var y1: Double
    var x: Double
}

fileprivate struct LATable {
    var x0: Double
    var x1: Double
    var y0: Double
    var y1: Double
    var cols: [Double]
    var rows: [Double]
    var head: [String]
}

/// JS gap {x0, x1, y, h, li, y0?, head?, sq?, end?}
fileprivate struct LAGapItem {
    var x0: Double
    var x1: Double
    /// the line (for a box: its bottom)
    var y: Double
    var h: Double
    var li: Int
    /// li found (JS li >= 0): the gap stands within a line of text
    var hasLi: Bool
    /// set for a box gap
    var y0: Double?
    var head: String?
    var square: Bool
    var end: Bool
}

fileprivate struct LAInk {
    var br: Double
    var gr: Double
}

fileprivate struct LAPrepared {
    /// sorted by line, then x
    var words: [LAWord]
    var dropped: Set<Int>
    /// lone punctuation ("." after a gap)
    var punct: [LAWord]
}

fileprivate func laMostlyIn(_ w: LARect, _ b: LARect) -> Bool {
    let ww = min(w.x1, b.x1) - max(w.x0, b.x0)
    let hh = min(w.y1, b.y1) - max(w.y0, b.y0)
    if ww <= 0 || hh <= 0 { return false }
    return ww * hh > 0.6 * (w.x1 - w.x0) * (w.y1 - w.y0)
}

fileprivate func laInBox(_ w: LARect, _ b: LARect) -> Bool {
    let cx = (w.x0 + w.x1) / 2, cy = (w.y0 + w.y1) / 2
    return cx > b.x0 && cx < b.x1 && cy > b.y0 && cy < b.y1
}

// MARK: - buildDoc: word clean-up

/// buildDoc → inkOf: mean colour of the ink of a word (pixels clearly darker than the word's box on average)
fileprivate func laInkOf(_ t: LAWord, _ img: PixelImage) -> LAInk? {
    let W = img.width, H = img.height
    let x0 = max(0, laFloor(t.x0)), x1 = min(W, laCeil(t.x1))
    let y0 = max(0, laFloor(t.y0)), y1 = min(H, laCeil(t.y1))
    if x1 <= x0 || y1 <= y0 { return nil }
    var sum = 0, cnt = 0, n = 0, r = 0, g = 0, b = 0
    img.rgba.withUnsafeBufferPointer { px in
        for y in y0..<y1 {
            for x in x0..<x1 {
                let k = (y * W + x) * 4
                sum += Int(px[k]) + Int(px[k + 1]) + Int(px[k + 2])
                cnt += 1
            }
        }
        let lim = Double(sum) / Double(max(1, cnt)) * 0.75
        for y in y0..<y1 {
            for x in x0..<x1 {
                let k = (y * W + x) * 4
                let pr = Int(px[k]), pg = Int(px[k + 1]), pb = Int(px[k + 2])
                if Double(pr + pg + pb) < lim {
                    n += 1
                    r += pr
                    g += pg
                    b += pb
                }
            }
        }
    }
    if n <= 4 { return nil }
    return LAInk(br: Double(b - r) / Double(n), gr: Double(g - r) / Double(n))
}

fileprivate func laPrepare(_ input: [Word], _ img: PixelImage) -> LAPrepared {
    var dropped = Set<Int>()
    var punct: [LAWord] = []
    var ws: [LAWord] = []
    for w in input {
        let rc = w.rect
        let x0 = Double(rc.minX), y0 = Double(rc.minY), x1 = Double(rc.maxX), y1 = Double(rc.maxY)
        if !(x0.isFinite && y0.isFinite && x1.isFinite && y1.isFinite) {
            dropped.insert(w.id)
            continue
        }
        let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lw = LAWord(id: w.id, t: t, x0: x0, y0: y0, x1: x1, y1: y1, li: w.line, cf: Double(w.confidence) * 100)
        if !LAText.speakable(t) {
            // tokensOf: lone punctuation is kept aside, a "." after a word or gap ends the sentence
            dropped.insert(w.id)
            if !t.isEmpty && lw.cf >= 20 { punct.append(lw) }
            continue
        }
        if laCheckPlausible && !LAText.plausible(t, lw.cf) {
            dropped.insert(w.id)
            continue
        }
        ws.append(lw)
    }

    // a box much taller than the others on its line gets the line's height
    var byLi: [Int: [Int]] = [:]
    for i in ws.indices { byLi[ws[i].li, default: []].append(i) }
    for (_, idx) in byLi where idx.count >= 3 {
        let m = idx.count >> 1
        let hs = idx.map { ws[$0].y1 - ws[$0].y0 }.sorted()
        let y0s = idx.map { ws[$0].y0 }.sorted()
        let y1s = idx.map { ws[$0].y1 }.sorted()
        for i in idx where ws[i].y1 - ws[i].y0 > hs[m] * 1.7 {
            ws[i].y0 = y0s[m]
            ws[i].y1 = y1s[m]
        }
    }

    // a box squeezed to a few pixels is dropped
    var sized: [LAWord] = []
    for w in ws {
        if w.x1 - w.x0 > 3 && w.y1 - w.y0 > 3 { sized.append(w) } else { dropped.insert(w.id) }
    }

    // a word read twice: keep the surer one (only the same word, or a large overlap, is a repeat)
    let order = sized.indices.sorted { p, q in sized[p].cf != sized[q].cf ? sized[p].cf > sized[q].cf : p < q }
    var kept: [LAWord] = []
    for i in order {
        let t = sized[i]
        let a = (t.x1 - t.x0) * (t.y1 - t.y0)
        var hit = -1
        for n in kept.indices {
            let k = kept[n]
            let ow = min(k.x1, t.x1) - max(k.x0, t.x0)
            let oh = min(k.y1, t.y1) - max(k.y0, t.y0)
            if ow <= 0 || oh <= 0 { continue }
            let ka = (k.x1 - k.x0) * (k.y1 - k.y0)
            let o = ow * oh
            if o > 0.5 * max(a, ka) || (o > 0.3 * min(a, ka) && LAText.core(k.t) == LAText.core(t.t)) {
                hit = n
                break
            }
        }
        if hit < 0 {
            kept.append(t)
            continue
        }
        dropped.insert(t.id)
        // keep "freundlich." over "freundlich"
        if LAText.core(kept[hit].t) == LAText.core(t.t) && t.t.count > kept[hit].t.count { kept[hit].t = t.t }
    }

    // example answers are often printed in coloured handwriting: an unsure word whose ink differs in colour
    // from the usual print is left out; coloured words that stay are marked (never a heading)
    var inks: [LAInk?] = []
    for w in kept { inks.append(laInkOf(w, img)) }
    let ok = inks.compactMap { $0 }
    let brs = ok.map { $0.br }.sorted(), grs = ok.map { $0.gr }.sorted()
    let mbr: Double = brs.isEmpty ? 0 : brs[brs.count >> 1]
    let mgr: Double = grs.isEmpty ? 0 : grs[grs.count >> 1]
    var all: [LAWord] = []
    for k in kept.indices {
        var w = kept[k]
        if let c = inks[k] {
            let dx = c.br - mbr, dy = c.gr - mgr
            w.col = (dx * dx + dy * dy).squareRoot() > 40
        }
        if w.cf < 80 && w.col {
            dropped.insert(w.id)
            continue
        }
        all.append(w)
    }
    let sortedIdx = all.indices.sorted { p, q in
        if all[p].li != all[q].li { return all[p].li < all[q].li }
        if all[p].x0 != all[q].x0 { return all[p].x0 < all[q].x0 }
        return p < q
    }
    let words = sortedIdx.map { all[$0] }
    return LAPrepared(words: words, dropped: dropped, punct: punct)
}

// MARK: - analyzeLayout: pixel maps

/// Summed brightness table (W+1)×(H+1). Wrapping arithmetic: a box sum is exact even if the total overflows.
fileprivate func laIntegral(_ gray: [UInt8], _ W: Int, _ H: Int) -> [UInt32] {
    let w1 = W + 1
    var sums = [UInt32](repeating: 0, count: w1 * (H + 1))
    sums.withUnsafeMutableBufferPointer { s in
        gray.withUnsafeBufferPointer { g in
            for y in 0..<H {
                var row: UInt32 = 0
                let gy = y * W, s0 = y * w1, s1 = (y + 1) * w1
                for x in 0..<W {
                    row = row &+ UInt32(g[gy + x])
                    s[s1 + x + 1] = s[s0 + x + 1] &+ row
                }
            }
        }
    }
    return sums
}

/// ink = clearly darker than the surroundings, so shadows and tinted paper do not count
fileprivate func laInkMap(gray: [UInt8], S: [UInt32], W: Int, H: Int, r: Int) -> [UInt8] {
    let w1 = W + 1
    var ink = [UInt8](repeating: 0, count: W * H)
    ink.withUnsafeMutableBufferPointer { o in
        gray.withUnsafeBufferPointer { g in
            S.withUnsafeBufferPointer { s in
                for y in 0..<H {
                    let ya = max(0, y - r), yb = min(H, y + r + 1)
                    for x in 0..<W {
                        let xa = max(0, x - r), xb = min(W, x + r + 1)
                        let sum = s[yb * w1 + xb] &- s[ya * w1 + xb] &- s[yb * w1 + xa] &+ s[ya * w1 + xa]
                        let mean = Double(sum) / Double((xb - xa) * (yb - ya))
                        let v = Double(g[y * W + x])
                        if v < mean * 0.8 && mean - v > 18 { o[y * W + x] = 1 }
                    }
                }
            }
        }
    }
    return ink
}

/// Thin printed lines are often light grey: a pixel clearly darker than both pixels a few rows above and below
/// lies on a horizontal line (and with left/right on a vertical one), whatever the lighting. Then trace both.
fileprivate func laLineSegments(gray: [UInt8], W: Int, H: Int, mh: Double) -> (h: [LASeg], v: [LASeg]) {
    let k = max(3, laRound(mh * 0.12))
    var ridgeH = [UInt8](repeating: 0, count: W * H)
    var ridgeV = [UInt8](repeating: 0, count: W * H)
    if H > 2 * k && W > 2 * k {
        ridgeH.withUnsafeMutableBufferPointer { rh in
            ridgeV.withUnsafeMutableBufferPointer { rv in
                gray.withUnsafeBufferPointer { g in
                    let kW = k * W
                    for y in k..<(H - k) {
                        let row = y * W
                        for x in k..<(W - k) {
                            let i = row + x
                            let v = Int(g[i]) + 10
                            if v < Int(g[i - kW]) && v < Int(g[i + kW]) { rh[i] = 1 }
                            if v < Int(g[i - k]) && v < Int(g[i + k]) { rv[i] = 1 }
                        }
                    }
                }
            }
        }
    }
    let minLen = mh * 1.1
    let hSegs = laTrace(ridgeH, W: W, H: H, horiz: true, minLen: minLen, mh: mh)
    let vSegs = laTrace(ridgeV, W: W, H: H, horiz: false, minLen: minLen, mh: mh)
    return (h: hSegs, v: vSegs)
}

/// analyzeLayout → trace: follow ridge pixels along a row (or column), allowing a slight slant and tiny breaks;
/// keep long straight runs
fileprivate func laTrace(_ ridge: [UInt8], W: Int, H: Int, horiz: Bool, minLen: Double, mh: Double) -> [LASeg] {
    let U = horiz ? W : H, V = horiz ? H : W
    guard U >= 2, V >= 3, ridge.count >= W * H else { return [] }
    let su = horiz ? 1 : W, sv = horiz ? W : 1     // pixel index = u * su + v * sv
    let maxGap = max(3, laRound(mh * 0.12))
    let maxDev = max(2.5, mh * 0.08)
    var seen = [UInt8](repeating: 0, count: W * H)
    var vs = [Int](repeating: 0, count: U)
    var out: [LASeg] = []
    ridge.withUnsafeBufferPointer { ink in
        seen.withUnsafeMutableBufferPointer { sn in
            vs.withUnsafeMutableBufferPointer { vb in
                for v in 1..<(V - 1) {
                    for u in 0..<(U - 1) {
                        let i0 = u * su + v * sv
                        if ink[i0] == 0 || sn[i0] != 0 { continue }
                        var cu = u, cv = v, gap = 0, last = u, n = 0
                        while cu < U - 1 {
                            let nu = cu + 1
                            var nv = -1
                            if ink[nu * su + cv * sv] != 0 {
                                nv = cv
                            } else if cv > 0 && ink[nu * su + (cv - 1) * sv] != 0 {
                                nv = cv - 1
                            } else if cv < V - 1 && ink[nu * su + (cv + 1) * sv] != 0 {
                                nv = cv + 1
                            }
                            cu = nu
                            if nv < 0 {
                                gap += 1
                                if gap > maxGap { break }
                                vb[n] = cv
                                n += 1
                                continue
                            }
                            gap = 0
                            cv = nv
                            last = cu
                            vb[n] = cv
                            n += 1
                            sn[cu * su + cv * sv] = 1
                            if cv > 0 { sn[cu * su + (cv - 1) * sv] = 1 }
                            if cv < V - 1 { sn[cu * su + (cv + 1) * sv] = 1 }
                        }
                        let m = last - u
                        if m < 2 || Double(m) < minLen { continue }
                        // straight line v = a + b·k through the steps
                        let md = Double(m)
                        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
                        for k in 0..<m {
                            let kd = Double(k), vk = Double(vb[k])
                            sx += kd
                            sy += vk
                            sxx += kd * kd
                            sxy += kd * vk
                        }
                        let den = md * sxx - sx * sx
                        if den == 0 { continue }
                        let b = (md * sxy - sx * sy) / den
                        let a = (sy - b * sx) / md
                        // (up to about 6°: photos taken at an angle tilt lines near the page edge)
                        if abs(b) > 0.1 { continue }
                        var dev = 0.0
                        for k in 0..<m { dev = max(dev, abs(Double(vb[k]) - a - b * Double(k))) }
                        // (long lines on a bent page are slightly curved)
                        if dev > max(maxDev, md * 0.012) { continue }
                        out.append(LASeg(u0: u, u1: last, a: a - b * Double(u + 1), b: b))
                    }
                }
            }
        }
    }
    return laMerge(laMerge(out, mh: mh), mh: mh)
}

/// analyzeLayout → merge: pieces of one line (thick lines give several traces, breaks give several pieces) become one
fileprivate func laMerge(_ segs: [LASeg], mh: Double) -> [LASeg] {
    // longest first (stable, like JS sort)
    let order = segs.indices.sorted { p, q in
        let lp = segs[p].u1 - segs[p].u0
        let lq = segs[q].u1 - segs[q].u0
        return lp != lq ? lp > lq : p < q
    }
    let tolV = max(4, mh * 0.18), join = max(8, mh * 0.4)
    var out: [LASeg] = []
    for i in order {
        let s = segs[i]
        let um = Double(s.u0 + s.u1) / 2
        var hit = -1
        for n in out.indices {
            let t = out[n]
            if Double(s.u0) > Double(t.u1) + join || Double(s.u1) < Double(t.u0) - join { continue }
            let x = min(max(um, Double(t.u0)), Double(t.u1))
            if abs((t.a + t.b * x) - (s.a + s.b * x)) <= tolV {
                hit = n
                break
            }
        }
        if hit >= 0 {
            out[hit].u0 = min(out[hit].u0, s.u0)
            out[hit].u1 = max(out[hit].u1, s.u1)
        } else {
            out.append(s)
        }
    }
    return out
}

/// analyzeLayout (grey squares): pixels a bit darker than the paper around them but no ink, on a half-size grid
fileprivate func laFillMap(gray: [UInt8], ink: [UInt8], S: [UInt32], W: Int, H: Int, R: Int) -> [UInt8] {
    let w2 = W >> 1, h2 = H >> 1, w1 = W + 1
    var fill = [UInt8](repeating: 0, count: w2 * h2)
    fill.withUnsafeMutableBufferPointer { f in
        gray.withUnsafeBufferPointer { g in
            ink.withUnsafeBufferPointer { k in
                S.withUnsafeBufferPointer { s in
                    for y in 0..<h2 {
                        let ya = max(0, y * 2 - R), yb = min(H, y * 2 + R + 1)
                        for x in 0..<w2 {
                            let xa = max(0, x * 2 - R), xb = min(W, x * 2 + R + 1)
                            let i = y * 2 * W + x * 2
                            let sum = s[yb * w1 + xb] &- s[ya * w1 + xb] &- s[yb * w1 + xa] &+ s[ya * w1 + xa]
                            let mean = Double(sum) / Double((xb - xa) * (yb - ya))
                            let v = Double(g[i])
                            if k[i] == 0 && v < mean * 0.93 && v > mean * 0.62 { f[y * w2 + x] = 1 }
                        }
                    }
                }
            }
        }
    }
    return fill
}

// MARK: - analyzeLayout: lines → frames, boxes, tables, gaps

fileprivate final class LAEngine {
    let W: Int
    let H: Int
    let gray: [UInt8]
    let S: [UInt32]
    let ink: [UInt8]
    /// typical text height
    let mh: Double
    let tol: Double
    var words: [LAWord]
    var hz: [LAHLine] = []
    var vt: [LAVLine] = []
    var frames: [LARect] = []
    var boxes: [LARect] = []
    var boxGaps: [LARect] = []
    var tables: [LATable] = []
    /// indices into hz that are table lines
    var gridH = Set<Int>()
    var wordMask: [UInt8] = []
    var gaps: [LAGapItem] = []

    init(W: Int, H: Int, gray: [UInt8], S: [UInt32], ink: [UInt8], mh: Double, words: [LAWord]) {
        self.W = W
        self.H = H
        self.gray = gray
        self.S = S
        self.ink = ink
        self.mh = mh
        self.tol = max(mh * 0.7, Double(W) * 0.012)
        self.words = words
    }

    func run(hSegs: [LASeg], vSegs: [LASeg]) {
        makeLines(hSegs, vSegs)
        cutWideWords()
        findWritingFields()
        findSideFrames()
        findTopBottomFrames()
        assignFrames()
        findGreySquares()
        findTables()
        buildWordMask()
        findLineGaps()
        addBoxGaps()
        findDots()
        sortGaps()
    }

    func boxMean(_ xa: Int, _ xb: Int, _ ya: Int, _ yb: Int) -> Double {
        let w1 = W + 1
        let s = S[yb * w1 + xb] &- S[ya * w1 + xb] &- S[yb * w1 + xa] &+ S[ya * w1 + xa]
        let area = (xb - xa) * (yb - ya)
        return area > 0 ? Double(s) / Double(area) : 0
    }

    func maxY1(_ idx: [Int]) -> Double {
        var m = -Double.infinity
        for i in idx { m = max(m, words[i].y1) }
        return m
    }

    func minY0(_ idx: [Int]) -> Double {
        var m = Double.infinity
        for i in idx { m = min(m, words[i].y0) }
        return m
    }

    /// hz, vt (vertical strokes inside recognised words are letters like "l", not sides of a box or frame)
    func makeLines(_ hSegs: [LASeg], _ vSegs: [LASeg]) {
        for s in hSegs {
            let mid = Double(s.u0 + s.u1) / 2
            hz.append(LAHLine(x0: Double(s.u0), x1: Double(s.u1), y: s.a + s.b * mid, a: s.a, b: s.b))
        }
        for s in vSegs {
            let mid = Double(s.u0 + s.u1) / 2
            let x = s.a + s.b * mid
            var inWord = false
            for w in words where x > w.x0 - 2 && x < w.x1 + 2 && mid > w.y0 && mid < w.y1 {
                inWord = true
                break
            }
            if !inWord { vt.append(LAVLine(y0: Double(s.u0), y1: Double(s.u1), x: x)) }
        }
    }

    /// "____ nichts" read as one wide word: cut the box back to about the width its letters need,
    /// on the side away from the line
    func cutWideWords() {
        for i in words.indices {
            let w = words[i]
            let h = w.y1 - w.y0
            let need = Double(LAText.cleanWord(w.t).count) * h * 0.6 + h * 0.3
            if w.x1 - w.x0 < need * 1.5 { continue }
            let lo = w.y1 - h * 0.5, hi = w.y1 + h * 0.6
            var found: LAHLine? = nil
            for s in hz where s.y > lo && s.y < hi && s.x0 < w.x1 && s.x1 > w.x0 {
                found = s
                break
            }
            guard let line = found else { continue }
            if line.x1 < w.x1 - need * 0.5 {
                words[i].x0 = max(w.x0, w.x1 - need)
            } else if line.x0 > w.x0 + need * 0.5 {
                words[i].x1 = min(w.x1, w.x0 + need)
            }
        }
    }

    func vNear(_ x: Double, _ ya: Double, _ yb: Double, _ part: Double) -> Bool {
        let need = (yb - ya) * part
        for v in vt {
            if abs(v.x - x) >= tol { continue }
            let overlap = min(v.y1, yb) - max(v.y0, ya)
            if overlap >= need { return true }
        }
        return false
    }

    /// edge: how much of [xa, xb] horizontal lines between ya and yb cover, and their mean height
    func edge(_ xa: Double, _ xb: Double, _ ya: Double, _ yb: Double) -> (c: Double, y: Double) {
        var c = 0.0, ys = 0.0
        for s in hz {
            if s.y < ya || s.y > yb { continue }
            let o = min(s.x1, xb) - max(s.x0, xa)
            if o > 0 {
                c += o
                ys += s.y * o
            }
        }
        let cover = min(1, c / (xb - xa))
        return (c: cover, y: c != 0 ? ys / c : 0)
    }

    /// writing fields (Lineatur), found first: three or more lines of the same width close above each other,
    /// often without visible sides
    func findWritingFields() {
        let byY = hz.indices.sorted { p, q in hz[p].y != hz[q].y ? hz[p].y < hz[q].y : p < q }
        var used = Set<Int>()
        for ai in byY {
            if used.contains(ai) { continue }
            let a = hz[ai]
            var chain = [ai]
            for bi in byY {
                let l = chain[chain.count - 1]
                let dy = hz[bi].y - hz[l].y
                if bi == l || used.contains(bi) || dy < mh * 0.2 { continue }
                if dy > mh * 1.6 || chain.count >= 5 { break }
                // evenly spaced (a field's lines), not the next field below
                if chain.count > 1 {
                    let step = hz[chain[1]].y - hz[chain[0]].y
                    if abs(dy - step) > step * 0.6 { continue }
                }
                if abs(hz[bi].x0 - a.x0) < tol && abs(hz[bi].x1 - a.x1) < tol { chain.append(bi) }
            }
            let y0 = hz[chain[0]].y, y1 = hz[chain[chain.count - 1]].y
            if chain.count < 3 || y1 - y0 < mh * 0.7 || y1 - y0 > mh * 3 { continue }
            for c in chain { used.insert(c) }
            var x0 = Double.infinity, x1 = -Double.infinity
            for c in chain {
                x0 = min(x0, hz[c].x0)
                x1 = max(x1, hz[c].x1)
            }
            let overlaps = frames.contains(where: { $0.x0 < x1 - tol && $0.x1 > x0 + tol && $0.y0 < y1 && $0.y1 > y0 })
            if overlaps { continue }
            frames.append(LARect(x0: x0, y0: y0, x1: x1, y1: y1, lin: true))
        }
    }

    /// boxes: a left and a right side of about the same height around one or two lines of text, with enough of
    /// the top and bottom edge seen; photos of slightly bent pages often lose parts of the edges
    func findSideFrames() {
        let sides = vt.indices.filter { vt[$0].y1 - vt[$0].y0 <= mh * 4 }
            .sorted { p, q in vt[p].x != vt[q].x ? vt[p].x < vt[q].x : p < q }
        var taken = Set<Int>()
        for ls in sides {
            if taken.contains(ls) { continue }
            let L = vt[ls]
            for rs in sides {
                let R = vt[rs]
                if R.x - L.x < mh * 0.6 || taken.contains(rs) { continue }
                if abs(R.y0 - L.y0) > tol || abs(R.y1 - L.y1) > tol { continue }
                let ya = min(L.y0, R.y0), yb = max(L.y1, R.y1)
                // another side in between means these are two boxes side by side
                var between = false
                for os in sides where os != ls && os != rs {
                    let v = vt[os]
                    if v.x <= L.x + mh || v.x >= R.x - mh { continue }
                    let overlap = min(v.y1, yb) - max(v.y0, ya)
                    if overlap > (yb - ya) * 0.5 {
                        between = true
                        break
                    }
                }
                if between { break }
                let t = edge(L.x, R.x, ya - tol, ya + tol * 0.5)
                let b = edge(L.x, R.x, yb - tol * 0.5, yb + tol)
                if max(t.c, b.c) < 0.4 || t.c + b.c < 0.6 { continue }
                let y0 = t.c >= 0.15 ? t.y : ya - mh * 0.25
                let y1 = b.c >= 0.15 ? b.y : yb + mh * 0.25
                if y1 - y0 > mh * 4 { continue }
                let overlaps = frames.contains(where: { $0.x0 < R.x - tol && $0.x1 > L.x + tol && $0.y0 < y1 - tol && $0.y1 > y0 + tol })
                if overlaps { continue }
                taken.insert(ls)
                taken.insert(rs)
                frames.append(LARect(x0: L.x, y0: y0, x1: R.x, y1: y1))
                break
            }
        }
    }

    /// or a top and a bottom line of about the same width, with at least some of the sides
    func findTopBottomFrames() {
        for T in hz {
            for B in hz {
                let dy = B.y - T.y
                if dy < mh * 1.2 || dy > mh * 3.8 { continue }
                if abs(B.x0 - T.x0) > tol || abs(B.x1 - T.x1) > tol { continue }
                let x0 = min(T.x0, B.x0), x1 = max(T.x1, B.x1)
                let overlaps = frames.contains(where: { $0.x0 < x1 && $0.x1 > x0 && $0.y0 < B.y && $0.y1 > T.y })
                if overlaps { continue }
                if vNear(x0, T.y, B.y, 0.3) && vNear(x1, T.y, B.y, 0.3) {
                    frames.append(LARect(x0: x0, y0: T.y, x1: x1, y1: B.y))
                }
            }
        }
    }

    /// words into frames (a printed box leaves room around its words); empty frames become box gaps
    func assignFrames() {
        for f in frames {
            // (in a writing field, an unsure word is letter salad from the lines)
            if f.lin {
                for i in words.indices where words[i].cf < 75 && laMostlyIn(words[i].r, f) { words[i].junk = true }
            }
            // a word belongs into a frame only if most of it lies inside ("▢ift" is often read as one word with the box)
            var inside: [Int] = []
            for i in words.indices where words[i].bx < 0 && !words[i].junk && laMostlyIn(words[i].r, f) { inside.append(i) }
            if inside.isEmpty { continue }
            var tallest = 0.0
            for i in inside { tallest = max(tallest, words[i].y1 - words[i].y0) }
            if f.y1 - f.y0 < 1.3 * tallest { continue }
            for i in inside { words[i].bx = boxes.count }
            boxes.append(LARect(x0: laRoundD(f.x0), y0: laRoundD(f.y0), x1: laRoundD(f.x1), y1: laRoundD(f.y1)))
        }
        // empty boxes are gaps as well: a small box inside or after a word ("▢ielen", "Sand▢rand") or a writing field
        for f in frames {
            if f.y1 - f.y0 < mh * 0.7 { continue }
            if words.contains(where: { !$0.junk && laMostlyIn($0.r, f) }) { continue }
            boxGaps.append(LARect(x0: f.x0, y0: f.y0, x1: f.x1, y1: f.y1))
        }
    }

    /// grey filled squares stand for a missing letter or punctuation mark ("fragt▢", "▢Hast du heute Zeit▢▢")
    func findGreySquares() {
        let gray = self.gray
        // brightness of the paper: the brightness most pixels inside the recognised words' area have
        var hist = [Int](repeating: 0, count: 256)
        for w in words {
            let ye = laCeil(min(Double(H), w.y1)), xe = laCeil(min(Double(W), w.x1))
            var y = max(0, laTrunc(w.y0))
            while y < ye {
                var x = max(0, laTrunc(w.x0))
                while x < xe {
                    hist[Int(gray[y * W + x])] += 1
                    x += 3
                }
                y += 3
            }
        }
        let tot = Double(hist.reduce(0, +))
        var paperLevel = 200
        var acc = 0
        var lv = 255
        while lv >= 0 {
            acc += hist[lv]
            if Double(acc) > tot * 0.3 {
                paperLevel = lv
                break
            }
            lv -= 1
        }

        let R = max(10, laRound(mh * 2))
        let w2 = W >> 1, h2 = H >> 1
        if w2 < 2 || h2 < 2 { return }
        let fill = laFillMap(gray: gray, ink: ink, S: S, W: W, H: H, R: R)
        var seen = [UInt8](repeating: 0, count: w2 * h2)
        var stack: [Int] = []
        for k0 in 0..<(w2 * h2) {
            if fill[k0] == 0 || seen[k0] != 0 { continue }
            var x0 = W, x1 = 0, y0 = H, y1 = 0, n = 0
            seen[k0] = 1
            stack.append(k0)
            while let k = stack.popLast() {
                let x = k % w2, y = k / w2
                n += 1
                x0 = min(x0, x)
                x1 = max(x1, x)
                y0 = min(y0, y)
                y1 = max(y1, y)
                if x > 0 && fill[k - 1] != 0 && seen[k - 1] == 0 { seen[k - 1] = 1; stack.append(k - 1) }
                if x < w2 - 1 && fill[k + 1] != 0 && seen[k + 1] == 0 { seen[k + 1] = 1; stack.append(k + 1) }
                if y > 0 && fill[k - w2] != 0 && seen[k - w2] == 0 { seen[k - w2] = 1; stack.append(k - w2) }
                if y < h2 - 1 && fill[k + w2] != 0 && seen[k + w2] == 0 { seen[k + w2] = 1; stack.append(k + w2) }
            }
            let bw = Double((x1 - x0 + 1) * 2), bh = Double((y1 - y0 + 1) * 2)
            let tooSmall = bw < mh * 0.35 || bh < mh * 0.35
            let tooBig = bw > mh * 1.6 || bh > mh * 1.6
            let notSquare = bw > bh * 2 || bh > bw * 2
            if tooSmall || tooBig || notSquare { continue }
            if Double(n * 4) < bw * bh * 0.75 { continue }
            let sq = LARect(x0: Double(x0 * 2), y0: Double(y0 * 2), x1: Double(x1 * 2 + 2), y1: Double(y1 * 2 + 2), square: true)
            // only on bright paper (not on cloth or a shadow beside the page), next to text, and not inside a word
            let cx = (x0 * 2 + x1 * 2 + 2) >> 1, cyy = (y0 * 2 + y1 * 2 + 2) >> 1
            let xa = max(0, cx - R), xb = min(W, cx + R + 1), ya = max(0, cyy - R), yb = min(H, cyy + R + 1)
            if boxMean(xa, xb, ya, yb) < Double(paperLevel) * 0.8 { continue }
            if words.contains(where: { laMostlyIn(sq, $0.r) }) { continue }
            let cyD = Double(cyy)
            let nearText = words.contains(where: { abs($0.cy - cyD) < mh * 0.8 && max(sq.x0 - $0.x1, $0.x0 - sq.x1) < mh * 1.5 })
            if !nearText { continue }
            boxGaps.append(sq)
        }
    }

    /// a real grid line crosses another one somewhere in its middle; the edges of a box only meet at its corners
    func crosses(_ v: LAVLine, _ h: LAHLine) -> Bool {
        let y = h.at(v.x)
        let nearX = v.x > h.x0 - tol && v.x < h.x1 + tol
        let nearY = y > v.y0 - tol && y < v.y1 + tol
        if !(nearX && nearY) { return false }
        let t = tol * 1.5
        return (v.x > h.x0 + t && v.x < h.x1 - t) || (y > v.y0 + t && y < v.y1 - t)
    }

    /// tables: long vertical lines crossed by long horizontal ones. Columns lie between the vertical lines (and the
    /// ends of the horizontal ones), rows between the horizontal lines (and the ends of the vertical ones);
    /// the top row is the header
    func findTables() {
        // (very long lines are page or book edges, not table lines)
        var LV: [Int] = []
        for i in vt.indices {
            let len = vt[i].y1 - vt[i].y0
            if len > mh * 2.5 && len < Double(H) * 0.45 { LV.append(i) }
        }
        var LH: [Int] = []
        for i in hz.indices {
            let len = hz[i].x1 - hz[i].x0
            if len > mh * 4 && len < Double(W) * 0.9 { LH.append(i) }
        }
        let nV = LV.count, nH = LH.count
        if nV < 2 || nH < 1 { return }
        // union-find over the lines: nodes 0..<nV are LV, nV..< are LH
        var up = Array(0..<(nV + nH))
        func root(_ a0: Int) -> Int {
            var a = a0
            while up[a] != a { a = up[a] }
            return a
        }
        for hj in 0..<nH {
            for vj in 0..<nV where crosses(vt[LV[vj]], hz[LH[hj]]) {
                let rv = root(vj)
                let rh = root(nV + hj)
                up[rv] = rh
            }
        }
        var order: [Int] = []
        var known = Set<Int>()
        var groupV: [Int: [Int]] = [:]
        var groupH: [Int: [Int]] = [:]
        for n in 0..<(nV + nH) {
            let r = root(n)
            if !known.contains(r) {
                known.insert(r)
                order.append(r)
            }
            if n < nV { groupV[r, default: []].append(LV[n]) } else { groupH[r, default: []].append(LH[n - nV]) }
        }
        let tolerance = tol
        func merged(_ vals: [Double]) -> [Double] {
            var out: [Double] = []
            for v in vals.sorted() where out.isEmpty || v - out[out.count - 1] > tolerance { out.append(v) }
            return out
        }
        for r in order {
            let gv = groupV[r] ?? [], gh = groupH[r] ?? []
            if gv.count < 2 || gh.isEmpty { continue }
            var hx0 = Double.infinity, hx1 = -Double.infinity, vy0 = Double.infinity, vy1 = -Double.infinity
            for i in gh {
                hx0 = min(hx0, hz[i].x0)
                hx1 = max(hx1, hz[i].x1)
            }
            for i in gv {
                vy0 = min(vy0, vt[i].y0)
                vy1 = max(vy1, vt[i].y1)
            }
            let cols = merged(gv.map { vt[$0].x } + [hx0, hx1])
            let rows = merged(gh.map { hz[$0].y } + [vy0, vy1])
            if cols.count < 3 || rows.count < 3 { continue }
            // a table has rows of a few text lines at most (long page borders or a book's edge do not make one)
            var tallRow = false
            for k in 1..<rows.count where rows[k] - rows[k - 1] > mh * 12 { tallRow = true }
            if tallRow { continue }
            for i in gh { gridH.insert(i) }
            var head: [String] = []
            for c in 0..<(cols.count - 1) {
                let cell = LARect(x0: cols[c], y0: rows[0], x1: cols[c + 1], y1: rows[1])
                let inHead = words.indices.filter { laInBox(words[$0].r, cell) }
                let sortedHead = inHead.sorted { p, q in words[p].x0 != words[q].x0 ? words[p].x0 < words[q].x0 : p < q }
                head.append(sortedHead.map { words[$0].t }.joined(separator: " "))
            }
            let hasHead = head.contains(where: { !$0.isEmpty })
            for ri in 0..<(rows.count - 1) {
                for ci in 0..<(cols.count - 1) {
                    let cell = LARect(x0: cols[ci], y0: rows[ri], x1: cols[ci + 1], y1: rows[ri + 1])
                    if cell.x1 - cell.x0 < mh * 1.5 || cell.y1 - cell.y0 < mh * 0.8 { continue }
                    let inside = words.indices.filter { words[$0].bx < 0 && laInBox(words[$0].r, cell) }
                    if !inside.isEmpty {
                        // a faint row line may be missing: words on clearly separate lines in one cell become separate cells
                        let byTop = inside.sorted { p, q in words[p].y0 != words[q].y0 ? words[p].y0 < words[q].y0 : p < q }
                        var lines: [[Int]] = []
                        for i in byTop {
                            if let g = lines.last, words[i].y0 < maxY1(g) + mh * 0.5 {
                                lines[lines.count - 1].append(i)
                            } else {
                                lines.append([i])
                            }
                        }
                        for k in 0..<lines.count {
                            let g = lines[k]
                            var top = cell.y0, bot = cell.y1
                            if k > 0 { top = (maxY1(lines[k - 1]) + minY0(g)) / 2 }
                            if k < lines.count - 1 { bot = (maxY1(g) + minY0(lines[k + 1])) / 2 }
                            for i in g { words[i].bx = boxes.count }
                            boxes.append(LARect(x0: laRoundD(cell.x0), y0: laRoundD(top), x1: laRoundD(cell.x1), y1: laRoundD(bot)))
                        }
                    } else if !(ri == 0 && hasHead) {
                        // an empty cell is a gap (its heading is read when it is tapped)
                        if words.contains(where: { laInBox($0.r, cell) }) { continue }
                        if boxGaps.contains(where: { laInBox($0, cell) }) { continue }
                        let m = mh * 0.15
                        boxGaps.append(LARect(x0: cell.x0 + m, y0: cell.y0 + m, x1: cell.x1 - m, y1: cell.y1 - m))
                    }
                }
            }
            tables.append(LATable(x0: cols[0], x1: cols[cols.count - 1], y0: rows[0], y1: rows[rows.count - 1],
                                  cols: cols, rows: rows, head: head))
        }
    }

    /// headOf: what belongs in an empty box – the header of its table column, or the heading above a column of
    /// writing fields
    func headOf(_ b: LARect) -> String {
        let cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2
        if let t = tables.first(where: { cx > $0.x0 && cx < $0.x1 && cy > $0.rows[1] - tol && cy < $0.y1 }) {
            for c in 0..<(t.cols.count - 1) where cx > t.cols[c] && cx < t.cols[c + 1] { return t.head[c] }
        }
        if b.square || b.x1 - b.x0 < mh * 2 { return "" }
        let col = frames.filter { abs($0.x0 - b.x0) < tol && abs($0.x1 - b.x1) < tol }
        if col.count < 3 { return "" }
        // the heading sits above the first row of the whole group of columns (some fields may be filled in or missed)
        var cy0 = Double.infinity, cy1 = -Double.infinity
        for o in col {
            cy0 = min(cy0, o.y0)
            cy1 = max(cy1, o.y1)
        }
        var topY = Double.infinity
        for o in frames {
            let same = frames.filter { abs($0.x0 - o.x0) < tol && abs($0.x1 - o.x1) < tol }
            if same.count < 3 { continue }
            var lo = Double.infinity, hi = -Double.infinity
            for q in same {
                lo = min(lo, q.y0)
                hi = max(hi, q.y1)
            }
            if lo < cy1 && hi > cy0 { topY = min(topY, o.y0) }
        }
        if !topY.isFinite { return "" }
        // (the nearest printed words above the column, not words written into one of the fields)
        // search as far up as about two rows of fields (photos taken at an angle stretch the distances)
        let ys = col.map { $0.y0 }.sorted()
        var steps: [Double] = []
        for k in 1..<ys.count { steps.append(ys[k] - ys[k - 1]) }
        steps.sort()
        let midStep: Double = steps.isEmpty ? 0 : steps[steps.count >> 1]
        let reach = max(mh * 4, midStep * 2.5)
        var above: [Int] = []
        for i in words.indices {
            let w = words[i]
            let wcx = (w.x0 + w.x1) / 2
            if !(w.y1 <= topY + mh * 0.3 && w.y1 > topY - reach) { continue }
            if !(wcx > b.x0 - mh && wcx < b.x1 + mh) { continue }
            if w.col || w.junk { continue }
            if frames.contains(where: { laMostlyIn(w.r, $0) }) { continue }
            if w.cf < 60 && !LAText.wordLike(w.t) { continue }
            // an unsure word right at the top of the fields is a handwritten example in a missed field, not the heading
            if !(w.cf >= 60 || w.y1 < topY - mh * 0.5) { continue }
            above.append(i)
        }
        if above.isEmpty { return "" }
        let low = maxY1(above)
        let line = above.filter { words[$0].y1 > low - mh * 0.6 }
            .sorted { p, q in words[p].x0 != words[q].x0 ? words[p].x0 < words[q].x0 : p < q }
            .map { words[$0].t }
        let notNumbers = line.filter { !LAText.isDigits($0) }
        return (notNumbers.isEmpty ? line : notNumbers).joined(separator: " ")
    }

    /// recognised words (with a small margin), so their ink does not count as drawing or as a dot
    func buildWordMask() {
        var mask = [UInt8](repeating: 0, count: W * H)
        for w in words {
            let xs = max(0, laFloor(w.x0) - 3)
            let xe = min(W, laCeil(w.x1) + 3)
            if xe <= xs { continue }
            var y = max(0, laFloor(w.y0) - 3)
            let ye = laCeil(min(Double(H), w.y1 + 3))
            while y < ye {
                let row = y * W
                for x in xs..<xe { mask[row + x] = 1 }
                y += 1
            }
        }
        wordMask = mask
    }

    /// paper: mean brightness of the paper (no ink) in a strip
    func paper(_ x0: Double, _ x1: Double, _ ya: Double, _ yb: Double) -> Double {
        let ink = self.ink, gray = self.gray
        let xs = max(0, laRound(x0)), xe = laCeil(min(Double(W), x1))
        let ye = laCeil(min(Double(H), yb))
        var y = max(0, laRound(ya))
        var n = 0, k = 0
        while y < ye {
            var x = xs
            while x < xe {
                let i = y * W + x
                if ink[i] == 0 {
                    n += 1
                    k += Int(gray[i])
                }
                x += 3
            }
            y += 2
        }
        return n > 0 ? Double(k) / Double(n) : 0
    }

    /// busy: ink density in a strip, not counting recognised words
    func busy(_ x0: Double, _ x1: Double, _ ya: Double, _ yb: Double) -> Double {
        let ink = self.ink, mask = self.wordMask
        let xs = max(0, laRound(x0)), xe = laCeil(min(Double(W), x1))
        let ye = laCeil(min(Double(H), yb))
        var y = max(0, laRound(ya))
        var n = 0, k = 0
        while y < ye {
            var x = xs
            while x < xe {
                let i = y * W + x
                if mask[i] == 0 {
                    n += 1
                    k += Int(ink[i])
                }
                x += 2
            }
            y += 2
        }
        return n > 0 ? Double(k) / Double(n) : 0
    }

    /// gaps: the other lines, unless they belong to a frame, underline a word, sit in a drawing or above all text
    func findLineGaps() {
        var top = 0.0
        if !words.isEmpty {
            top = Double.infinity
            for w in words { top = min(top, w.y0) }
        }
        let Wd = Double(W)
        for si in hz.indices {
            let s = hz[si]
            let len = s.x1 - s.x0
            // (short lines are edges of small boxes, not answer lines)
            if len < max(mh * 3, Wd * 0.035) || len > Wd * 0.97 { continue }
            if s.y < top - mh || gridH.contains(si) { continue }
            if tables.contains(where: { s.y > $0.y0 - tol && s.y < $0.y1 + tol && s.x1 > $0.x0 && s.x0 < $0.x1 }) { continue }
            if frames.contains(where: { s.y > $0.y0 - tol && s.y < $0.y1 + tol && s.x1 > $0.x0 && s.x0 < $0.x1 }) { continue }
            if vNear(s.x0, s.y - mh * 0.5, s.y + mh * 0.5, 0.3) || vNear(s.x1, s.y - mh * 0.5, s.y + mh * 0.5, 0.3) { continue }
            // an underline: words sitting on the line cover most of it
            var anyOver = false
            var oMin = Double.infinity, oMax = -Double.infinity
            for w in words {
                if w.x1 <= s.x0 || w.x0 >= s.x1 { continue }
                let wh = w.y1 - w.y0
                if s.y > w.y1 - wh * 0.35 && s.y < w.y1 + wh * 0.6 {
                    anyOver = true
                    oMin = min(oMin, w.x0)
                    oMax = max(oMax, w.x1)
                }
            }
            if anyOver && oMax - oMin > len * 0.75 { continue }
            // a line in a drawing has other ink around it
            if busy(s.x0, s.x1, s.y - mh * 1.1, s.y - mh * 0.15) > 0.06 { continue }
            if busy(s.x0, s.x1, s.y + mh * 0.2, s.y + mh * 0.9) > 0.06 { continue }
            // the edge of a grey band or coloured area: the paper is darker on one side than on the other
            let pa = paper(s.x0, s.x1, s.y - mh * 0.5, s.y - mh * 0.15)
            let pb = paper(s.x0, s.x1, s.y + mh * 0.15, s.y + mh * 0.5)
            if abs(pa - pb) > 14 { continue }
            // which text line does it belong to? the closest word sitting on about the same baseline
            var li = -1, found = false, h = mh, bd = Double.infinity
            for w in words {
                let wh = w.y1 - w.y0
                if s.y < w.y1 - wh * 0.4 || s.y > w.y1 + wh * 0.9 { continue }
                let d = max(s.x0 - w.x1, w.x0 - s.x1, 0)
                if d < wh * 4 && d < bd {
                    bd = d
                    li = w.li
                    found = true
                    h = min(wh, mh * 1.3)
                }
            }
            // a short line on its own is decoration, an answer line is long
            if !found && len < Wd * 0.2 { continue }
            gaps.append(LAGapItem(x0: laRoundD(s.x0), x1: laRoundD(s.x1), y: laRoundD(s.y), h: laRoundD(h),
                                  li: li, hasLi: found, y0: nil, head: nil, square: false, end: false))
        }
    }

    /// box gaps: inside a line of text (a word right next to it on the same height) they are part of the sentence
    func addBoxGaps() {
        for b in boxGaps {
            let h = b.y1 - b.y0, cy = (b.y0 + b.y1) / 2
            var li = -1, found = false, bd = Double.infinity
            for w in words {
                let wh = w.y1 - w.y0
                if abs(w.cy - cy) > max(wh, h) * 0.6 { continue }
                let d = max(b.x0 - w.x1, w.x0 - b.x1, 0)
                if d < mh * 2 && d < bd {
                    bd = d
                    li = w.li
                    found = true
                }
            }
            // a box with a heading (table cell, writing field in a column) stands alone, whatever is written next to it
            let touching = words.contains(where: { abs($0.cy - cy) < h * 0.6 && max(b.x0 - $0.x1, $0.x0 - b.x1) < mh * 0.3 })
            let head = touching ? "" : headOf(b)
            gaps.append(LAGapItem(x0: laRoundD(b.x0), x1: laRoundD(b.x1), y: laRoundD(b.y1), h: laRoundD(h),
                                  li: head.isEmpty ? li : -1, hasLi: head.isEmpty ? found : false,
                                  y0: laRoundD(b.y0), head: head.isEmpty ? nil : head, square: b.square, end: false))
        }
    }

    /// a "." right after a line ends the sentence; the text recognition often misses such small dots.
    /// Look at the ink just right of the line: a dot is small and round, a comma is taller, quotes sit high
    func findDots() {
        let ink = self.ink, mask = self.wordMask
        for gi in gaps.indices where gaps[gi].y0 == nil {
            let g = gaps[gi]
            var x0 = W, x1 = -1, y0 = H, y1 = -1
            let ye = laCeil(min(Double(H), g.y + mh * 0.6))
            let xs = max(0, laRound(g.x1 + mh * 0.12))
            let xe = laCeil(min(Double(W), g.x1 + mh * 0.8))
            var y = max(0, laRound(g.y - mh * 0.8))
            while y < ye {
                var x = xs
                while x < xe {
                    let i = y * W + x
                    if ink[i] != 0 && mask[i] == 0 {
                        x0 = min(x0, x)
                        x1 = max(x1, x)
                        y0 = min(y0, y)
                        y1 = max(y1, y)
                    }
                    x += 1
                }
                y += 1
            }
            if x1 < 0 { continue }
            let bw = Double(x1 - x0 + 1), bh = Double(y1 - y0 + 1)
            let small = bw <= mh * 0.3 && bh <= mh * 0.3
            let dotLike = bh < bw * 1.6 && Double(y0) > g.y - mh * 0.45
            if small && dotLike { gaps[gi].end = true }
        }
    }

    func sortGaps() {
        let old = gaps
        let order = old.indices.sorted { p, q in
            if old[p].y != old[q].y { return old[p].y < old[q].y }
            if old[p].x0 != old[q].x0 { return old[p].x0 < old[q].x0 }
            return p < q
        }
        gaps = order.map { old[$0] }
    }

    /// buildDoc, after analyzeLayout: sentence ends from lone dots, and "dienen ____ als Nahrung" goes on
    func finishDoc(punct: [LAWord]) {
        // (letter salad read into an empty writing field is dropped)
        let live = words.indices.filter { !words[$0].junk }
        // a lone "." (often right after a gap) ends the sentence of whatever stands before it
        for p in punct {
            if !LAText.matches(p.t, #"[.!?]\W?$"#) || LAText.matches(p.t, #"[_\-–—]"#) || p.t.count > 3 { continue }
            // a gap line read as "____." – that dot is checked in the picture instead
            if gaps.contains(where: { $0.x0 < p.x1 && $0.x1 > p.x0 && abs($0.y - p.y1) < mh }) { continue }
            var bx = -Double.infinity, bestWord = -1, bestGap = -1
            for i in live {
                let w = words[i]
                if w.li == p.li && w.x1 <= p.x0 + 4 && w.x1 > bx {
                    bx = w.x1
                    bestWord = i
                }
            }
            for gi in gaps.indices {
                let g = gaps[gi]
                if !g.hasLi || g.li != p.li { continue }
                if g.x0 < p.x1 && g.x1 <= p.x1 + mh && g.x1 > bx {
                    bx = g.x1
                    bestGap = gi
                }
            }
            if bestGap >= 0 {
                gaps[bestGap].end = true
            } else if bestWord >= 0 {
                words[bestWord].end = true
            }
        }
        // "dienen ____ als Nahrung": a word in small letters right after a gap means the sentence goes on
        for gi in gaps.indices {
            let g = gaps[gi]
            let left = g.x1 - mh * 0.3, right = g.x1 + mh * 2.5
            for i in live {
                let w = words[i]
                if w.x0 > left && w.x0 < right && g.y > w.y0 && g.y < w.y1 + mh * 0.9 {
                    if LAText.matches(w.t, "^[a-zäöüß]") { gaps[gi].end = false }
                    break
                }
            }
        }
    }

    func result(input: [Word], dropped prepDropped: Set<Int>) -> LayoutResult {
        var dropped = prepDropped
        for w in words where w.junk { dropped.insert(w.id) }
        // boxes whose only words were letter salad are left out; the rest are numbered anew
        var used = Set<Int>()
        for w in words where !w.junk && w.bx >= 0 { used.insert(w.bx) }
        var newIndex: [Int: Int] = [:]
        var outBoxes: [PrintedBox] = []
        for i in boxes.indices where used.contains(i) {
            let b = boxes[i]
            newIndex[i] = outBoxes.count
            outBoxes.append(PrintedBox(id: outBoxes.count, rect: laCGRect(b.x0, b.y0, b.x1, b.y1)))
        }
        var wordBox: [Int: Int] = [:]
        var byId: [Int: LAWord] = [:]
        for w in words {
            byId[w.id] = w
            if !w.junk && w.bx >= 0, let n = newIndex[w.bx] { wordBox[w.id] = n }
        }

        var outGaps: [Gap] = []
        for g in gaps {
            let kind: GapKind
            let rect: CGRect
            if let y0 = g.y0 {
                kind = .box
                rect = laCGRect(g.x0, y0, g.x1, g.y)
            } else {
                // the line is the bottom edge, one text height above it is where the answer is written
                kind = .line
                rect = laCGRect(g.x0, g.y - g.h, g.x1, g.y)
            }
            outGaps.append(Gap(id: UUID(), kind: kind, rect: rect, head: g.head, endsSentence: g.end, inText: g.hasLi))
        }

        var outWords = input
        for i in outWords.indices {
            guard let w = byId[outWords[i].id], !dropped.contains(w.id) else { continue }
            outWords[i].rect = laCGRect(w.x0, w.y0, w.x1, w.y1)
            if w.end && !LAText.matches(w.t, "[.!?]$") {
                outWords[i].text = w.t + "."
            } else {
                outWords[i].text = w.t
            }
            outWords[i].box = wordBox[w.id]
        }
        return LayoutResult(gaps: outGaps, boxes: outBoxes, wordBox: wordBox, dropped: dropped,
                            textHeight: CGFloat(mh), words: outWords)
    }
}
