import SwiftUI
import UIKit
import PencilKit

// Fertig: one picture of the page with everything the child did (marks, answers, pen), in page pixels.
// Handed in as a PDF saved on this iPad ("Abgeben", Handin.swift; teacher's decision, November 2026); a page of a
// Heft hands in the whole Heft. Small AirDrop buttons as an option: this page, the whole Heft, or all pages
// photographed today.

enum Exporter {
    /// Photo → marks (multiplied, so the print stays dark) → answer fields → pen strokes.
    @MainActor static func render(_ c: PageController) -> UIImage {
        let page = c.page
        let size = exportCanvasSize(page: page, image: c.image)
        let th = exportTextHeight(page)
        let reading = c.reading

        var marks: [(rect: CGRect, color: UIColor)] = []
        for m in page.marks {
            if let r = reading.markRect(m) {
                marks.append((rect: r, color: m.color.fill))
            }
        }
        let pen = exportDrawingImage(page.drawing, size: size)
        let photo = c.image

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let full = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            cg.fill(full)
            photo.draw(in: full)

            cg.saveGState()
            cg.setBlendMode(.multiply)
            for m in marks {
                let radius = min(m.rect.height * 0.2, max(4, th * 0.2))
                let path = UIBezierPath(roundedRect: m.rect, cornerRadius: radius)
                cg.setFillColor(m.color.cgColor)
                cg.addPath(path.cgPath)
                cg.fillPath()
            }
            cg.restoreGState()

            for a in page.answers {
                if let lines = page.answerLines(a) {
                    exportDrawLinedAnswer(a, lines: lines, textHeight: th,
                                          marks: answerMarkPaint(a, in: page, textHeight: th), in: cg)
                } else {
                    exportDrawAnswer(a, textHeight: th, limit: answerRoom(a, in: page),
                                     marks: answerMarkPaint(a, in: page, textHeight: th), plain: page.blank == true,
                                     in: cg)
                }
            }

            if let p = pen {
                p.draw(in: full)
            }
        }
    }
}

extension Exporter {
    /// All pages of a Heft with their answers as one PDF (one page each, A4, upright or across like the page),
    /// in a temporary folder. Pages not open are loaded for this only.
    @MainActor static func heftPDF(_ heft: Heft, app: AppState) async -> URL? {
        return await pagesPDF(heft.pages, title: heft.title, folder: "Heft", app: app)
    }

    /// The pages photographed today (not those of a Heft), oldest first, as one PDF.
    @MainActor static func todayPDF(app: AppState) async -> URL? {
        let ids = app.store.pages.filter { $0.heft == nil && Calendar.current.isDateInToday($0.created) }
            .sorted { $0.created < $1.created }.map { $0.id }
        if ids.count < 2 { return nil }
        return await pagesPDF(ids, title: "Hörblatt " + exportDay(Date()), folder: "Heute", app: app)
    }

    /// How many pages were photographed today (the button "Alle von heute" needs at least two).
    @MainActor static func todayCount(app: AppState) -> Int {
        return app.store.pages.filter { $0.heft == nil && Calendar.current.isDateInToday($0.created) }.count
    }

    /// The finished page (as rendered for Fertig) as a one-page PDF.
    @MainActor static func pagePDF(_ picture: UIImage, title: String) -> URL? {
        guard let jpg = picture.jpegData(compressionQuality: 0.8) else { return nil }
        let name = (title.isEmpty ? "Seite" : title) + " " + exportDay(Date())
        return writePDF([jpg], name: name, folder: "Seite")
    }

    /// Pages with their answers as one PDF; each export gets a folder of its own (they are made at the same time).
    @MainActor static func pagesPDF(_ ids: [UUID], title: String, folder: String, app: AppState) async -> URL? {
        // JPEG keeps the file small enough for AirDrop
        var pictures: [Data] = []
        for id in ids {
            var c = app.openController(id)
            if c == nil, let page = app.store.loadPage(id), let image = app.store.loadImage(id) {
                c = PageController(page: page, image: image, app: app)
            }
            guard let pc = c else { continue }
            if let jpg = render(pc).jpegData(compressionQuality: 0.8) {
                pictures.append(jpg)
            }
            // (the Fertig view keeps moving meanwhile)
            await Task.yield()
        }
        return writePDF(pictures, name: title, folder: folder)
    }

    /// JPEG pictures → PDF (A4, upright or across like each picture) in Temp/Hoerblatt-Abgabe/<folder>/.
    @MainActor static func writePDF(_ pictures: [Data], name: String, folder: String) -> URL? {
        if pictures.isEmpty { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Hoerblatt-Abgabe", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let url = dir.appendingPathComponent(exportFileName(name) + ".pdf")

        let upright = CGRect(x: 0, y: 0, width: 595, height: 842)
        let across = CGRect(x: 0, y: 0, width: 842, height: 595)
        let renderer = UIGraphicsPDFRenderer(bounds: upright)
        do {
            try renderer.writePDF(to: url) { ctx in
                for data in pictures {
                    guard let picture = UIImage(data: data) else { continue }
                    let s = picture.size
                    guard s.width > 0, s.height > 0 else { continue }
                    let sheet = s.width > s.height ? across : upright
                    ctx.beginPage(withBounds: sheet, pageInfo: [:])
                    let k = min(sheet.width / s.width, sheet.height / s.height)
                    let w = s.width * k
                    let h = s.height * k
                    picture.draw(in: CGRect(x: (sheet.width - w) / 2, y: (sheet.height - h) / 2, width: w, height: h))
                }
            }
        } catch {
            return nil
        }
        return url
    }
}

// MARK: - Fertig view

/// Big preview, first a yellow thumb "Gezeigt" (the teacher has seen it, can be switched off), then the big blue
/// "Abgeben" (PDF saved into the teacher's folder on this iPad, `HandinFolder`), small AirDrop buttons as an option;
/// back arrow. Spoken on appearing.
struct FinishView: View {
    @ObservedObject var app: AppState
    let image: UIImage
    /// The child has shown the picture to the teacher (thumb tapped); only then sharing is offered.
    @State private var shown = false
    /// What became of "Abgeben" (nil: not handed in yet).
    @State private var handedIn: HandinResult? = nil

    private var canShare: Bool { shown || !app.settings.showTeacherFirst }

    var body: some View {
        let picture = SwiftUI.Image(uiImage: image)
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                Button(action: {
                    app.speaker.stop()
                    app.finishImage = nil
                }) {
                    HStack(spacing: 10) {
                        SwiftUI.Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 28, weight: .bold))
                        Text("Zurück")
                            .font(.title3.weight(.semibold))
                    }
                    .foregroundColor(ExportStyle.slate)
                    .padding(.horizontal, 22)
                    .frame(height: 64)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().stroke(ExportStyle.slate, lineWidth: 3))
                }
                .buttonStyle(ExportPressStyle())
                .accessibilityLabel(Text("Zurück zum Blatt"))
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    SwiftUI.Image(systemName: "checkmark.square.fill")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Fertig")
                        .font(.title.weight(.bold))
                }
                .foregroundColor(ExportStyle.blue)
                Spacer(minLength: 0)
                // (same width as the back button, so the title stays in the middle)
                Color.clear
                    .frame(width: 150, height: 64)
            }

            picture
                .resizable()
                .scaledToFit()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.12), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
                // (pressing long on the picture shares too, once the teacher has seen it)
                .contextMenu {
                    if canShare, app.settings.airDrop, let url = app.finishPagePDF {
                        ShareLink(item: url, preview: SharePreview("Hörblatt", image: picture)) {
                            SwiftUI.Label("Teilen mit AirDrop", systemImage: "airdrop")
                        }
                    }
                }
                .accessibilityLabel(Text("Das fertige Blatt"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !canShare {
                // first step: show the picture to the teacher, then the thumb
                Button(action: {
                    shown = true
                    app.say("Tippe auf Abgeben.")
                }) {
                    HStack(spacing: 16) {
                        SwiftUI.Image(systemName: "hand.thumbsup.fill")
                            .font(.system(size: 40, weight: .bold))
                        Text("Gezeigt")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(ExportStyle.ink)
                    .padding(.horizontal, 48)
                    .frame(minWidth: 300)
                    .frame(height: 96)
                    .background(Capsule().fill(ExportStyle.thumb))
                    .overlay(Capsule().stroke(ExportStyle.ink, lineWidth: 3))
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(ExportPressStyle())
                .accessibilityLabel(Text("Der Lehrkraft gezeigt"))
            } else {
                // handing in = a PDF saved on the iPad (teacher's folder); AirDrop only as an option below
                VStack(spacing: 16) {
                    handinButton
                    if app.settings.airDrop {
                        airDropRow
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ExportStyle.background.ignoresSafeArea())
        .onAppear {
            if canShare {
                app.say("Fertig. Tippe auf Abgeben.")
            } else {
                app.say("Fertig. Zeig das Bild deiner Lehrkraft. Dann tippe auf den Daumen.")
            }
        }
    }

    /// What "Abgeben" saves: a Heft page hands in the whole Heft, a photographed page itself.
    private var handinSource: URL? {
        return app.finishHeft != nil ? app.finishHeftPDF : app.finishPagePDF
    }

    /// The big blue "Abgeben"; once saved a green "Abgegeben" (one hand-in per Fertig).
    @ViewBuilder
    private var handinButton: some View {
        if let result = handedIn, result != .failed {
            HStack(spacing: 16) {
                SwiftUI.Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40, weight: .bold))
                Text("Abgegeben")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 48)
            .frame(minWidth: 320)
            .frame(height: 104)
            .background(Capsule().fill(ExportStyle.green))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Abgegeben"))
        } else if let url = handinSource {
            Button(action: { handIn(url) }) {
                HStack(spacing: 16) {
                    SwiftUI.Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 40, weight: .bold))
                    Text("Abgeben")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 48)
                .frame(minWidth: 320)
                .frame(height: 104)
                .background(Capsule().fill(ExportStyle.blue))
                .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(ExportPressStyle())
            .accessibilityLabel(Text("Abgeben: als PDF auf dem iPad speichern"))
        } else {
            waiting("Abgeben …", caption: app.finishHeft != nil ? "Das Heft wird vorbereitet" : "Die Seite wird vorbereitet")
        }
    }

    private func handIn(_ url: URL) {
        let result = app.handin.save(url, title: app.finishTitle)
        handedIn = result
        switch result {
        case .folder, .app:
            app.say("Abgegeben. Gut gemacht!")
        case .failed:
            app.say("Das Speichern hat nicht geklappt. Frag deine Lehrkraft.")
        }
    }

    /// Optional: small AirDrop buttons (this page, the whole Heft, all pages of today).
    private var airDropRow: some View {
        HStack(spacing: 14) {
            SwiftUI.Image(systemName: "airdrop")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(ExportStyle.slate)
                .accessibilityHidden(true)
            if let heft = app.finishHeft {
                smallShare(app.finishPagePDF, title: "Diese Seite", symbol: "doc.fill", preview: "Hörblatt")
                smallShare(app.finishHeftPDF, title: "Ganzes Heft", symbol: "book.fill", preview: heft.title)
            } else {
                smallShare(app.finishPagePDF, title: "Diese Seite", symbol: "doc.fill", preview: "Hörblatt")
                if app.finishTodayCount >= 2 {
                    smallShare(app.finishTodayPDF, title: "Alle von heute", symbol: "square.stack.fill",
                               preview: "Alle Seiten von heute")
                }
            }
        }
    }

    /// A small white share button with the AirDrop sign; a spinner while its PDF is still being made.
    @ViewBuilder
    private func smallShare(_ url: URL?, title: String, symbol: String, preview: String) -> some View {
        if let url = url {
            ShareLink(item: url, preview: SharePreview(preview)) {
                HStack(spacing: 8) {
                    SwiftUI.Image(systemName: symbol)
                    Text(title)
                    SwiftUI.Image(systemName: "airdrop")
                }
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(ExportStyle.blue)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().stroke(ExportStyle.blue.opacity(0.5), lineWidth: 2))
            }
            .buttonStyle(ExportPressStyle())
            .accessibilityLabel(Text(title + " mit AirDrop senden"))
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text(title)
            }
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundColor(ExportStyle.slate)
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(Capsule().fill(Color.white))
            .accessibilityLabel(Text(title + " wird vorbereitet"))
        }
    }

    /// A PDF still being made: a grey button with a spinner.
    private func waiting(_ title: String, caption: String) -> some View {
        HStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.4)
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
        }
        .foregroundColor(ExportStyle.slate)
        .padding(.horizontal, 36)
        .frame(minWidth: 260)
        .frame(height: 96)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().stroke(ExportStyle.slate.opacity(0.4), lineWidth: 3))
        .accessibilityLabel(Text(caption))
    }
}

// MARK: - Helpers

/// Colours of the picture card (fixed, the same in dark mode).
fileprivate enum ExportStyle {
    static let blue = Color(red: 37.0 / 255, green: 99.0 / 255, blue: 235.0 / 255)
    static let teal = Color(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255)
    static let slate = Color(red: 71.0 / 255, green: 85.0 / 255, blue: 105.0 / 255)
    static let background = Color(red: 238.0 / 255, green: 241.0 / 255, blue: 236.0 / 255)
    static let ink = Color(red: 30.0 / 255, green: 41.0 / 255, blue: 59.0 / 255)
    static let thumb = Color(red: 253.0 / 255, green: 230.0 / 255, blue: 138.0 / 255)
    static let green = Color(red: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255)
}

/// Answer fields look as on the screen (PageCanvas): light purple, purple edge, blue rounded writing.
fileprivate enum ExportPalette {
    static var purple: UIColor { return UIColor(red: 124 / 255, green: 58 / 255, blue: 237 / 255, alpha: 1) }
    static var answerInk: UIColor { return UIColor(red: 0.11, green: 0.25, blue: 0.69, alpha: 1) }
    static var answerBackground: UIColor { return UIColor(red: 237 / 255, green: 233 / 255, blue: 254 / 255, alpha: 0.92) }
}

fileprivate struct ExportPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The Heft's title as a file name ("Ermittlerheft Klasse 4.pdf").
/// "2.11.2026" for file names (no child's name in them, only the page and the day).
fileprivate func exportDay(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "d.M.yyyy"
    return f.string(from: date)
}

fileprivate func exportFileName(_ title: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
    let cleaned = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "Heft" : cleaned
}

/// The page's pixel size; the image's own size if the stored one is unusable.
fileprivate func exportCanvasSize(page: Page, image: UIImage) -> CGSize {
    let w = page.pixelSize.width
    let h = page.pixelSize.height
    if w.isFinite && h.isFinite && w >= 1 && h >= 1 {
        return CGSize(width: w.rounded(), height: h.rounded())
    }
    let iw = max(1, (image.size.width * image.scale).rounded())
    let ih = max(1, (image.size.height * image.scale).rounded())
    return CGSize(width: iw, height: ih)
}

/// Same fallback as the reading order when the analysis found no text height.
fileprivate func exportTextHeight(_ page: Page) -> CGFloat {
    let th = page.textHeight
    if th.isFinite && th > 1 { return th }
    return max(12, page.pixelSize.height * 0.024)
}

@MainActor fileprivate func exportAnswerFont(_ size: CGFloat) -> UIFont {
    return answerUIFont(size)
}

/// One answer field: width as stored (at least two letters), grows downwards with the text (as on the screen).
@MainActor fileprivate func exportDrawAnswer(_ a: Answer, textHeight th: CGFloat, limit: CGFloat?,
                                             marks: [(rect: CGRect, color: MarkColor)], plain: Bool = false,
                                             in cg: CGContext) {
    // (the text exactly as the field shows it: the marks' places are counted in it)
    let text = a.text
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
    let r = a.rect
    guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return }

    // (smaller in a table cell or field, so a long answer still fits – as on the screen)
    let fontSize = answerFontSize(text, width: r.width, limit: limit, textHeight: th, font: exportAnswerFont)
    let padX = th * 0.15
    let padY = th * 0.06
    let width = max(r.width, th * 2)
    let innerWidth = max(1, width - 2 * padX)

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let writing = answerAttributed(text, font: exportAnswerFont(fontSize), color: ExportPalette.answerInk,
                                   paragraph: paragraph)
    let measured = writing.boundingRect(with: CGSize(width: innerWidth, height: CGFloat.greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    let textHeight = max(ceil(measured.height), fontSize * 1.25)
    let height = max(r.height, th * 1.5, textHeight + 2 * padY)
    let field = CGRect(x: r.minX, y: r.minY, width: width, height: height)

    let line = max(2, th * 0.06)
    let radius = min(th * 0.3, height / 2)
    let path = UIBezierPath(roundedRect: field.insetBy(dx: line / 2, dy: line / 2), cornerRadius: radius)
    // (the writing of an empty sheet: no field drawn)
    if !plain {
        cg.saveGState()
        cg.setFillColor(ExportPalette.answerBackground.cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()
        cg.setStrokeColor(ExportPalette.purple.cgColor)
        cg.setLineWidth(line)
        cg.addPath(path.cgPath)
        cg.strokePath()
        cg.restoreGState()
    }

    exportDrawMarks(marks, textHeight: th, in: cg)
    // (in the middle of its field; the writing of an empty sheet from the top)
    let textRect = CGRect(x: field.minX + padX, y: field.minY + (plain ? padY : max(padY, (height - textHeight) / 2)),
                          width: innerWidth, height: textHeight)
    writing.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
}

/// An answer over several writing lines: one field shaped like the lines, each row of text on its line.
@MainActor fileprivate func exportDrawLinedAnswer(_ a: Answer, lines: [CGRect], textHeight th: CGFloat,
                                                  marks: [(rect: CGRect, color: MarkColor)], in cg: CGContext) {
    let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return }
    let layout = answerLineLayout(text, lines: lines, textHeight: th, font: exportAnswerFont)
    let path = answerBandsPath(layout.bands)
    cg.saveGState()
    cg.setFillColor(ExportPalette.answerBackground.cgColor)
    cg.addPath(path.cgPath)
    cg.fillPath()
    cg.setStrokeColor(ExportPalette.purple.cgColor)
    cg.setLineWidth(max(2, th * 0.06))
    cg.setLineJoin(.round)
    cg.addPath(path.cgPath)
    cg.strokePath()
    cg.restoreGState()
    exportDrawMarks(marks, textHeight: th, in: cg)
    let font = exportAnswerFont(layout.fontSize)
    for row in layout.rows {
        answerAttributed(row.text, font: font, color: ExportPalette.answerInk).draw(at: row.origin)
    }
}

/// The pen strokes as an image of the whole page. Drawn in light mode: PencilKit would turn dark ink light otherwise.
@MainActor fileprivate func exportDrawingImage(_ data: Data, size: CGSize) -> UIImage? {
    if data.isEmpty { return nil }
    guard let drawing = try? PKDrawing(data: data) else { return nil }
    if drawing.strokes.isEmpty { return nil }
    var result: UIImage? = nil
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
        result = drawing.image(from: CGRect(origin: .zero, size: size), scale: 1)
    }
    return result
}

// MARK: - Answer size (screen and picture)

/// An answer over several writing lines (screen and finished picture use the same): its rows of text and the
/// field around them (`answerBands`).
struct AnswerLineLayout {
    var fontSize: CGFloat
    /// Each row of text and where it is drawn (top left corner, as `draw(at:)` takes it).
    var rows: [(text: String, origin: CGPoint)]
    var bands: [CGRect]
    var frame: CGRect { return bands.reduce(CGRect.null) { $0.union($1) } }
}

/// A short answer stands on the writing lines, as if written by hand (normal size or a little smaller).
/// A longer one fills the whole field row by row, close together, as large as it fits (down to half the size);
/// only beyond that the field grows downwards. (Teacher: much room in the field stayed empty while the writing got
/// tiny and ran over the next gap.)
@MainActor func answerLineLayout(_ text: String, lines: [CGRect], textHeight th: CGFloat,
                                 font: @MainActor (CGFloat) -> UIFont) -> AnswerLineLayout {
    let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map { String($0) }
    var bands = answerBands(lines, rows: lines.count, textHeight: th)
    guard !lines.isEmpty, let first = bands.first, let last = bands.last else {
        return AnswerLineLayout(fontSize: th * 1.1, rows: [], bands: bands)
    }
    let base = th * 1.1
    let padX = th * 0.15

    // on the lines
    var size = base
    while size >= base * 0.8 {
        let f = font(size)
        let rows = answerWrap(words, font: f) { i in answerLine(lines, i).width - 2 * padX }
        if rows.count <= lines.count {
            var placed: [(text: String, origin: CGPoint)] = []
            for (i, row) in rows.enumerated() {
                placed.append((text: row, origin: answerRowOrigin(lines[i], font: f, textHeight: th)))
            }
            return AnswerLineLayout(fontSize: size, rows: placed, bands: bands)
        }
        size *= 0.9
    }

    // filling the field: the first row on the first line, the others close together below it
    size = base
    while true {
        let f = font(size)
        let pitch = answerRowPitch(size)
        // (x range of a row: where all bands it reaches into overlap)
        func span(_ i: Int) -> (x: CGFloat, w: CGFloat) {
            if i == 0 { return (x: first.minX + padX, w: first.width - 2 * padX) }
            let top = first.maxY + CGFloat(i - 1) * pitch
            var x0 = -CGFloat.greatestFiniteMagnitude
            var x1 = CGFloat.greatestFiniteMagnitude
            var any = false
            for b in bands where min(b.maxY, top + pitch) - max(b.minY, top) > pitch * 0.15 {
                x0 = max(x0, b.minX)
                x1 = min(x1, b.maxX)
                any = true
            }
            if !any || x1 <= x0 {
                x0 = last.minX
                x1 = last.maxX
            }
            return (x: x0 + padX, w: x1 - x0 - 2 * padX)
        }
        let rows = answerWrap(words, font: f) { i in span(i).w }
        let bottom = first.maxY + CGFloat(max(0, rows.count - 1)) * pitch
        if bottom <= last.maxY + th * 0.02 || size <= base * 0.5 {
            var placed: [(text: String, origin: CGPoint)] = []
            for (i, row) in rows.enumerated() {
                if i == 0 {
                    placed.append((text: row, origin: answerRowOrigin(lines[0], font: f, textHeight: th)))
                } else {
                    let top = first.maxY + CGFloat(i - 1) * pitch
                    placed.append((text: row, origin: CGPoint(x: span(i).x, y: top + (pitch - f.lineHeight) / 2)))
                }
            }
            // (only a very long answer: the field grows below its last line)
            if bottom > last.maxY {
                bands[bands.count - 1].size.height += bottom + th * 0.1 - last.maxY
            }
            return AnswerLineLayout(fontSize: size, rows: placed, bands: bands)
        }
        size = max(base * 0.5, size * 0.92)
    }
}

/// Words into rows, row `i` at most `width(i)` wide (a word longer than its row stands alone).
@MainActor fileprivate func answerWrap(_ words: [String], font: UIFont, width: (Int) -> CGFloat) -> [String] {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let space = (" " as NSString).size(withAttributes: attributes).width + answerSpaceExtra(font)
    var rows: [String] = []
    var current = ""
    var used: CGFloat = 0
    for w in words {
        let wordWidth = (w as NSString).size(withAttributes: attributes).width
        let room = max(1, width(rows.count))
        if current.isEmpty {
            current = w
            used = wordWidth
        } else if used + space + wordWidth <= room {
            current += " " + w
            used += space + wordWidth
        } else {
            rows.append(current)
            current = w
            used = wordWidth
        }
    }
    if !current.isEmpty { rows.append(current) }
    return rows
}

/// How the answers are written (set from the settings by AppState).
@MainActor enum AnswerStyle {
    /// Room between the words of an answer, as a multiple of a normal space (teacher's slider: the child must see
    /// where a word ends, and tap between two words to put one in).
    static var wordSpacing: CGFloat = 2
}

/// Extra room after each space of an answer written in this font.
@MainActor func answerSpaceExtra(_ font: UIFont) -> CGFloat {
    let space = (" " as NSString).size(withAttributes: [.font: font]).width
    return max(0, (AnswerStyle.wordSpacing - 1) * space)
}

/// The answer's text with its font (and colour), its spaces widened (`AnswerStyle.wordSpacing`). Field, rows on lines,
/// word places and the finished picture all use it, so they agree.
@MainActor func answerAttributed(_ text: String, font: UIFont, color: UIColor? = nil,
                                 paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if let c = color { attributes[.foregroundColor] = c }
    if let p = paragraph { attributes[.paragraphStyle] = p }
    let out = NSMutableAttributedString(string: text, attributes: attributes)
    let extra = answerSpaceExtra(font)
    if extra > 0 {
        let ns = text as NSString
        var from = 0
        while from < ns.length {
            let r = ns.rangeOfCharacter(from: .whitespaces, options: [], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            out.addAttribute(.kern, value: extra, range: r)
            from = r.location + max(1, r.length)
        }
    }
    return out
}

/// Marker colour under the writing of an answer (as on printed words).
@MainActor fileprivate func exportDrawMarks(_ marks: [(rect: CGRect, color: MarkColor)], textHeight th: CGFloat,
                                            in cg: CGContext) {
    if marks.isEmpty { return }
    cg.saveGState()
    cg.setBlendMode(.multiply)
    for m in marks {
        let path = UIBezierPath(roundedRect: m.rect.insetBy(dx: -th * 0.04, dy: -th * 0.04), cornerRadius: th * 0.12)
        cg.setFillColor(m.color.fill.cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()
    }
    cg.restoreGState()
}

/// Where stretches of an answer's text stand on the page (one rect per word they touch), as the field lays them out.
@MainActor func answerRangeRects(_ a: Answer, in page: Page, textHeight th: CGFloat, ranges: [NSRange]) -> [[CGRect]] {
    let words = answerWords(a, in: page, textHeight: th)
    let ns = a.text as NSString
    let size: CGFloat
    if let lines = page.answerLines(a) {
        size = answerLineLayout(a.text, lines: lines, textHeight: th, font: answerUIFont).fontSize
    } else {
        size = answerFontSize(a.text, width: a.rect.width, limit: answerRoom(a, in: page), textHeight: th,
                              font: answerUIFont)
    }
    let attributes: [NSAttributedString.Key: Any] = [.font: answerUIFont(size)]
    return ranges.map { r in
        var out: [CGRect] = []
        for w in words {
            let s = max(r.location, w.range.location)
            let e = min(r.location + r.length, w.range.location + w.range.length)
            if e <= s { continue }
            // (within a word there are no spaces: its letters are as wide as the font makes them)
            let pre = ns.substring(with: NSRange(location: w.range.location, length: s - w.range.location))
            let mid = ns.substring(with: NSRange(location: s, length: e - s))
            let x0 = (pre as NSString).size(withAttributes: attributes).width
            let width = (mid as NSString).size(withAttributes: attributes).width
            out.append(CGRect(x: w.rect.minX + x0, y: w.rect.minY, width: max(1, width), height: w.rect.height))
        }
        return out
    }
}

/// The marker colour on an answer: where each mark stands and its colour.
@MainActor func answerMarkPaint(_ a: Answer, in page: Page, textHeight th: CGFloat) -> [(rect: CGRect, color: MarkColor)] {
    guard let marks = a.marks, !marks.isEmpty else { return [] }
    let rects = answerRangeRects(a, in: page, textHeight: th,
                                 ranges: marks.map { NSRange(location: $0.location, length: $0.length) })
    var out: [(rect: CGRect, color: MarkColor)] = []
    for (k, m) in marks.enumerated() where k < rects.count {
        for r in rects[k] { out.append((rect: r, color: m.color)) }
    }
    return out
}

/// The answers' writing (rounded, semibold), as the field and the finished picture show it.
@MainActor func answerUIFont(_ size: CGFloat) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: .semibold)
    if let rounded = base.fontDescriptor.withDesign(.rounded) {
        return UIFont(descriptor: rounded, size: size)
    }
    return base
}

/// The words of an answer and where they stand, laid out as the field shows them: on the writing lines
/// (`answerLineLayout`) or wrapped in the field (same font size, width and padding as the text view).
@MainActor func answerWords(_ a: Answer, in page: Page, textHeight th: CGFloat) -> [AnswerWord] {
    let ranges = answerTokenRanges(a.text)
    if ranges.isEmpty { return [] }
    if let lines = page.answerLines(a) {
        let layout = answerLineLayout(a.text, lines: lines, textHeight: th, font: answerUIFont)
        let font = answerUIFont(layout.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let space = (" " as NSString).size(withAttributes: attributes).width + answerSpaceExtra(font)
        var out: [AnswerWord] = []
        var k = 0
        for row in layout.rows {
            var x = row.origin.x
            for (n, w) in row.text.split(separator: " ").enumerated() {
                if n > 0 { x += space }
                let width = (String(w) as NSString).size(withAttributes: attributes).width
                if k < ranges.count {
                    out.append(AnswerWord(range: ranges[k], rect: CGRect(x: x, y: row.origin.y, width: width,
                                                                         height: font.lineHeight)))
                }
                k += 1
                x += width
            }
        }
        return out
    }
    let fontSize = answerFontSize(a.text, width: a.rect.width, limit: answerRoom(a, in: page), textHeight: th,
                                  font: answerUIFont)
    let padX = th * 0.15
    let padY = th * 0.06
    let inner = max(1, max(a.rect.width, th * 2) - 2 * padX)
    let storage = NSTextStorage(attributedString: answerAttributed(a.text, font: answerUIFont(fontSize)))
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: inner, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    let textHeight = max(ceil(used.height), fontSize * 1.25)
    let height = max(a.rect.height, th * 1.5, textHeight + 2 * padY)
    let x0 = a.rect.minX + padX
    let y0 = a.rect.minY + (page.blank == true ? padY : max(padY, (height - textHeight) / 2))
    return ranges.map { r in
        let glyphs = manager.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        let b = manager.boundingRect(forGlyphRange: glyphs, in: container)
        return AnswerWord(range: r, rect: b.offsetBy(dx: x0, dy: y0))
    }
}

/// The outline of touching bands as one shape (steps where the lines start or end at different places).
func answerBandsPath(_ bands: [CGRect]) -> UIBezierPath {
    let path = UIBezierPath()
    guard let first = bands.first else { return path }
    path.move(to: CGPoint(x: first.minX, y: first.minY))
    for b in bands {
        path.addLine(to: CGPoint(x: b.maxX, y: b.minY))
        path.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
    }
    for b in bands.reversed() {
        path.addLine(to: CGPoint(x: b.minX, y: b.maxY))
        path.addLine(to: CGPoint(x: b.minX, y: b.minY))
    }
    path.close()
    path.lineJoinStyle = .round
    return path
}

/// Where a row of an answer starts: its letters stand on the writing line.
@MainActor func answerRowOrigin(_ line: CGRect, font: UIFont, textHeight th: CGFloat) -> CGPoint {
    return CGPoint(x: line.minX + th * 0.15, y: line.maxY - th * 0.1 - font.ascender)
}

/// Font size of an answer: normally 1.1 text heights; in a box (`limit`) smaller, down to half, until the wrapped
/// text fits (teacher: long spoken answers did not fit into the table cells). Beyond that the field grows.
@MainActor func answerFontSize(_ text: String, width: CGFloat, limit: CGFloat?, textHeight th: CGFloat,
                               font: @MainActor (CGFloat) -> UIFont) -> CGFloat {
    let base = th * 1.1
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let room = limit, room > 0, !trimmed.isEmpty else { return base }
    let padX = th * 0.15
    let padY = th * 0.06
    let inner = max(1, max(width, th * 2) - 2 * padX)
    let smallest = base * 0.5
    var size = base
    while true {
        let measured = answerAttributed(trimmed, font: font(size)).boundingRect(
            with: CGSize(width: inner, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let needed = max(ceil(measured.height), size * 1.25) + 2 * padY
        if needed <= room || size <= smallest { return size }
        size = max(smallest, size * 0.9)
    }
}
