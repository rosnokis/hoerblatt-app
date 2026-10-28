import SwiftUI
import UIKit

// Word lens (Markieren): the finger held still on a word opens it big, letter by letter. Swiping over the
// letter tiles marks exactly these letters ("ab" in "abschreiben", "Sp" in "Spinne"); the photo of the word
// above shows where the mark lands on the page.

// MARK: - Letters and their places on the page

enum WordLetters {
    /// The letters shown in the lens: the word without punctuation at its edges.
    static func letters(_ text: String) -> [String] {
        return Reading.cleanWord(text).map { String($0) }
    }

    /// x positions in page pixels of the edges around the lens letters (one more than letters).
    /// Estimated from the letter widths of a print font, then moved to the lightest column of the photo
    /// nearby (the white between two letters). Empty when the word has no letters.
    static func edges(word w: Word, image: UIImage, pixelSize: CGSize) -> [CGFloat] {
        let chars = Array(w.text)
        let count = letters(w.text).count
        guard count > 0, w.rect.width > 0,
              let first = chars.firstIndex(where: { $0.isLetter || $0.isNumber }),
              first + count <= chars.count else { return [] }

        // widths of all characters (punctuation too: it takes room in the word's box)
        let font = UIFont.systemFont(ofSize: 100)
        var cum: [CGFloat] = [0]
        for ch in chars {
            let width = (String(ch) as NSString).size(withAttributes: [.font: font]).width
            cum.append((cum.last ?? 0) + max(1, width))
        }
        let total = max(1, cum.last ?? 1)

        // the ink of the word, column by column
        var left = w.rect.minX
        var right = w.rect.maxX
        var columns: [CGFloat]? = nil
        var scale: CGFloat = 1
        var cropX: CGFloat = 0
        if let cg = image.cgImage, pixelSize.width >= 1 {
            scale = CGFloat(cg.width) / pixelSize.width
            let r = CGRect(x: w.rect.minX * scale, y: w.rect.minY * scale,
                           width: w.rect.width * scale, height: w.rect.height * scale)
                .integral
                .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            if !r.isNull, r.width >= 4, r.height >= 2, let ink = columnInk(cg, r) {
                columns = ink
                cropX = r.minX
                // tight around the ink: the box from the text recognition has some room at its ends
                if let a = ink.firstIndex(where: { $0 > 0 }), let b = ink.lastIndex(where: { $0 > 0 }), b > a {
                    left = (cropX + CGFloat(a)) / scale
                    right = (cropX + CGFloat(b + 1)) / scale
                }
            }
        }

        var est: [CGFloat] = []
        for k in 0...count {
            est.append(left + (right - left) * cum[first + k] / total)
        }
        guard let ink = columns, count > 1 else { return est }

        // inner edges to the lightest column nearby (ties: the nearest)
        var out = est
        for k in 1..<count {
            let letterWidth = (est[k + 1] - est[k - 1]) / 2
            let c0 = max(0, min(ink.count - 1, Int((est[k] * scale - cropX).rounded())))
            let radius = max(1, Int((letterWidth * scale * 0.35).rounded()))
            var best = c0
            var bestValue = CGFloat.infinity
            for x in max(0, c0 - radius)...min(ink.count - 1, c0 + radius) {
                let value = ink[x] + CGFloat(abs(x - c0)) * 0.01
                if value < bestValue {
                    bestValue = value
                    best = x
                }
            }
            out[k] = (cropX + CGFloat(best) + 0.5) / scale
        }
        for k in 1...count where out[k] <= out[k - 1] + 0.5 {
            // letters in the wrong order: the estimate is safer
            return est
        }
        return out
    }

    /// Part of the page image around a word (page pixels), for the lens.
    static func crop(_ image: UIImage, rect: CGRect, pixelSize: CGSize) -> UIImage? {
        guard let cg = image.cgImage, pixelSize.width >= 1 else { return nil }
        let scale = CGFloat(cg.width) / pixelSize.width
        let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !r.isNull, r.width >= 1, r.height >= 1, let part = cg.cropping(to: r) else { return nil }
        return UIImage(cgImage: part)
    }

    /// Number of dark pixels in each column of `r` (darker than halfway between ink and paper of the word).
    private static func columnInk(_ cg: CGImage, _ r: CGRect) -> [CGFloat]? {
        guard let part = cg.cropping(to: r) else { return nil }
        let w = part.width
        let h = part.height
        guard w >= 4, h >= 2 else { return nil }
        var px = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let sorted = px.sorted()
        let ink = Int(sorted[sorted.count / 20])
        let paper = Int(sorted[sorted.count * 9 / 10])
        // hardly any contrast: no letters to find
        guard paper - ink > 30 else { return nil }
        let mid = UInt8((ink + paper) / 2)
        var cols = [CGFloat](repeating: 0, count: w)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where px[row + x] < mid {
                cols[x] += 1
            }
        }
        return cols
    }
}

// MARK: - The lens on screen

/// Shows the lens of the active page while Markieren is chosen.
struct WordLensHost: View {
    @ObservedObject var app: AppState
    @ObservedObject var controller: PageController

    var body: some View {
        if app.mode == .markieren, let i = controller.lensWord, i >= 0, i < controller.page.words.count,
           !WordLetters.letters(controller.page.words[i].text).isEmpty {
            WordLensView(app: app, controller: controller, word: i)
                .id(i)
        }
    }
}

fileprivate enum LensStyle {
    static let amber = Color(red: 217.0 / 255, green: 119.0 / 255, blue: 6.0 / 255)
    static let orange = Color(red: 234.0 / 255, green: 88.0 / 255, blue: 12.0 / 255)
    static let grey = Color(red: 100.0 / 255, green: 116.0 / 255, blue: 139.0 / 255)
    static let green = Color(red: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255)
    static let ink = Color(red: 30.0 / 255, green: 41.0 / 255, blue: 59.0 / 255)
}

/// Photo of the word, the letter tiles, and below: colours, eraser, hear again, done.
struct WordLensView: View {
    @ObservedObject var app: AppState
    @ObservedObject var controller: PageController
    let word: Int
    /// Letter where the finger came down and the one under it now (nil: no finger on the tiles).
    @State private var dragFrom: Int? = nil
    @State private var dragTo: Int? = nil

    var body: some View {
        let w = controller.page.words[word]
        let letters = WordLetters.letters(w.text)
        let edges = controller.letterEdges(word)
        let colors = preview(controller.letterColors(word))
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { controller.closeLens() }
            VStack(spacing: 22) {
                if edges.count == letters.count + 1 && colors.count == letters.count {
                    photo(w, edges: edges, colors: colors)
                    tiles(letters, colors: colors)
                }
                buttons
            }
            .padding(24)
            .frame(maxWidth: 900)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(LensStyle.amber, lineWidth: 4))
            .padding(24)
        }
    }

    /// The word as printed, with its marks (where they land on the page).
    @ViewBuilder
    private func photo(_ w: Word, edges: [CGFloat], colors: [MarkColor?]) -> some View {
        let pad = w.rect.height * 0.3
        let area = w.rect.insetBy(dx: -pad, dy: -pad)
        if let img = WordLetters.crop(controller.image, rect: area, pixelSize: controller.page.pixelSize) {
            let shown = area.intersection(CGRect(origin: .zero, size: controller.page.pixelSize))
            SwiftUI.Image(uiImage: img)
                .resizable()
                .aspectRatio(img.size.width / max(1, img.size.height), contentMode: .fit)
                .overlay(
                    SwiftUI.Canvas { ctx, size in
                        let s = size.width / max(1, shown.width)
                        ctx.blendMode = .multiply
                        for k in colors.indices {
                            guard let c = colors[k] else { continue }
                            let r = CGRect(x: (edges[k] - shown.minX) * s, y: (w.rect.minY - shown.minY) * s,
                                           width: (edges[k + 1] - edges[k]) * s, height: w.rect.height * s)
                            ctx.fill(Path(r), with: .color(Color(uiColor: c.fill)))
                        }
                    }
                )
                .frame(maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.12), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }

    /// One big tile per letter; touching or swiping over tiles marks these letters when the finger lifts.
    private func tiles(_ letters: [String], colors: [MarkColor?]) -> some View {
        GeometryReader { g in
            let n = letters.count
            let gap: CGFloat = 8
            let tile = max(20, min(96, (g.size.width - gap * CGFloat(n - 1)) / CGFloat(n)))
            let rowWidth = tile * CGFloat(n) + gap * CGFloat(n - 1)
            let x0 = (g.size.width - rowWidth) / 2
            let letterAt: (CGFloat) -> Int = { x in
                max(0, min(n - 1, Int(((x - x0 + gap / 2) / (tile + gap)).rounded(.down))))
            }
            HStack(spacing: gap) {
                ForEach(0..<n, id: \.self) { k in
                    Text(letters[k])
                        .font(.system(size: min(64, tile * 0.72), weight: .semibold, design: .rounded))
                        .foregroundColor(LensStyle.ink)
                        .frame(width: tile, height: 112)
                        .background(RoundedRectangle(cornerRadius: 14).fill(tileColor(colors[k])))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(LensStyle.ink.opacity(0.3), lineWidth: 2))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragFrom == nil { dragFrom = letterAt(v.startLocation.x) }
                        dragTo = letterAt(v.location.x)
                    }
                    .onEnded { v in
                        let a = dragFrom ?? letterAt(v.startLocation.x)
                        let b = letterAt(v.location.x)
                        dragFrom = nil
                        dragTo = nil
                        controller.markLetters(word: word, from: a, to: b)
                    }
            )
        }
        .frame(height: 112)
        .accessibilityLabel(Text("Buchstaben zum Markieren"))
    }

    private var buttons: some View {
        HStack(spacing: 16) {
            ForEach(MarkColor.allCases) { c in
                Button(action: {
                    app.settings.markColor = c
                    app.announce(c.title)
                }) {
                    ZStack {
                        Circle()
                            .fill(Color(uiColor: c.swatch))
                        Circle()
                            .stroke(app.settings.markColor == c ? LensStyle.ink : Color.black.opacity(0.15),
                                    lineWidth: app.settings.markColor == c ? 4 : 1.5)
                        if app.settings.markColor == c {
                            SwiftUI.Image(systemName: "checkmark")
                                .font(.system(size: 22, weight: .heavy))
                                .foregroundColor(.white)
                                .shadow(color: Color.black.opacity(0.5), radius: 1, x: 0, y: 1)
                        }
                    }
                    .frame(width: 56, height: 56)
                }
                .buttonStyle(LensPressStyle())
                .accessibilityLabel(Text(c.title))
            }
            Spacer(minLength: 8)
            roundButton("speaker.wave.2.fill", LensStyle.orange, "Wort nochmal hören") {
                controller.hearLensWord()
            }
            roundButton("eraser.fill", LensStyle.grey, "Markierung im Wort löschen") {
                controller.clearLetters(word: word)
            }
            roundButton("checkmark", LensStyle.green, "Fertig") {
                controller.closeLens()
            }
        }
    }

    private func roundButton(_ symbol: String, _ color: Color, _ caption: String,
                       _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SwiftUI.Image(systemName: symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(color))
        }
        .buttonStyle(LensPressStyle())
        .accessibilityLabel(Text(caption))
    }

    private func tileColor(_ c: MarkColor?) -> Color {
        guard let c = c else { return Color.white }
        return Color(uiColor: c.swatch)
    }

    /// The letters' colours with the finger's swipe already applied (same rule as `markLetters`).
    private func preview(_ colors: [MarkColor?]) -> [MarkColor?] {
        guard let a = dragFrom, let b = dragTo, !colors.isEmpty else { return colors }
        let lo = max(0, min(a, b))
        let hi = min(colors.count - 1, max(a, b))
        guard lo <= hi else { return colors }
        let c = app.settings.markColor
        let all = (lo...hi).allSatisfy { colors[$0] == c }
        var out = colors
        for k in lo...hi { out[k] = all ? nil : c }
        return out
    }
}

fileprivate struct LensPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
