import SwiftUI
import UIKit
import PencilKit

// Fertig: one picture of the page with everything the child did (marks, answers, pen), in page pixels.
// It goes to the teacher by AirDrop (an image is enough, no PDF: teacher's decision).

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
                exportDrawAnswer(a, textHeight: th, in: cg)
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
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Hoerblatt-Abgabe", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let url = dir.appendingPathComponent(exportFileName(heft.title) + ".pdf")

        // JPEG keeps the file small enough for AirDrop
        var pictures: [Data] = []
        for id in heft.pages {
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
        if pictures.isEmpty { return nil }

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
/// "Teilen" (→ AirDrop); back arrow. Spoken on appearing.
struct FinishView: View {
    @ObservedObject var app: AppState
    let image: UIImage
    /// The child has shown the picture to the teacher (thumb tapped); only then sharing is offered.
    @State private var shown = false

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
                    if canShare {
                        ShareLink(item: picture, preview: SharePreview("Hörblatt", image: picture)) {
                            SwiftUI.Label("Teilen", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .accessibilityLabel(Text("Das fertige Blatt"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !canShare {
                // first step: show the picture to the teacher, then the thumb
                Button(action: {
                    shown = true
                    app.say(shareHint)
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
            } else if let heft = app.finishHeft {
                // a page of a Heft: this page as a picture, or the whole Heft as a PDF
                HStack(spacing: 24) {
                    ShareLink(item: picture, preview: SharePreview("Hörblatt", image: picture)) {
                        shareLabel("doc.fill", "Diese Seite", ExportStyle.blue)
                    }
                    .buttonStyle(ExportPressStyle())
                    .accessibilityLabel(Text("Diese Seite teilen, dann AirDrop"))
                    if let url = app.finishHeftPDF {
                        ShareLink(item: url, preview: SharePreview(heft.title)) {
                            shareLabel("book.fill", "Ganzes Heft", ExportStyle.teal)
                        }
                        .buttonStyle(ExportPressStyle())
                        .accessibilityLabel(Text("Ganzes Heft teilen, dann AirDrop"))
                    } else {
                        HStack(spacing: 14) {
                            ProgressView()
                                .scaleEffect(1.4)
                            Text("Heft …")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(ExportStyle.slate)
                        .padding(.horizontal, 36)
                        .frame(minWidth: 260)
                        .frame(height: 96)
                        .background(Capsule().fill(Color.white))
                        .overlay(Capsule().stroke(ExportStyle.slate.opacity(0.4), lineWidth: 3))
                        .accessibilityLabel(Text("Das Heft wird vorbereitet"))
                    }
                }
            } else {
                ShareLink(item: picture, preview: SharePreview("Hörblatt", image: picture)) {
                    shareLabel("square.and.arrow.up", "Teilen", ExportStyle.blue)
                }
                .buttonStyle(ExportPressStyle())
                .accessibilityLabel(Text("Teilen, dann AirDrop"))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ExportStyle.background.ignoresSafeArea())
        .onAppear {
            if canShare {
                app.say("Fertig. " + shareHint)
            } else {
                app.say("Fertig. Zeig das Bild deiner Lehrkraft. Dann tippe auf den Daumen.")
            }
        }
    }

    private var shareHint: String {
        if app.finishHeft != nil {
            return "Tippe auf Diese Seite oder auf Ganzes Heft. Dann auf AirDrop."
        }
        return "Tippe auf Teilen und dann auf AirDrop."
    }

    /// The big share button's face.
    private func shareLabel(_ symbol: String, _ title: String, _ color: Color) -> some View {
        HStack(spacing: 16) {
            SwiftUI.Image(systemName: symbol)
                .font(.system(size: 36, weight: .bold))
            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 40)
        .frame(minWidth: 260)
        .frame(height: 96)
        .background(Capsule().fill(color))
        .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
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
    let base = UIFont.systemFont(ofSize: size, weight: .semibold)
    if let rounded = base.fontDescriptor.withDesign(.rounded) {
        return UIFont(descriptor: rounded, size: size)
    }
    return base
}

/// One answer field: width as stored (at least two letters), grows downwards with the text (as on the screen).
@MainActor fileprivate func exportDrawAnswer(_ a: Answer, textHeight th: CGFloat, in cg: CGContext) {
    let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return }
    let r = a.rect
    guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return }

    let fontSize = th * 1.1
    let padX = th * 0.15
    let padY = th * 0.06
    let width = max(r.width, th * 2)
    let innerWidth = max(1, width - 2 * padX)

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: exportAnswerFont(fontSize),
        .foregroundColor: ExportPalette.answerInk,
        .paragraphStyle: paragraph
    ]
    let writing = NSAttributedString(string: text, attributes: attributes)
    let measured = writing.boundingRect(with: CGSize(width: innerWidth, height: CGFloat.greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    let textHeight = max(ceil(measured.height), fontSize * 1.25)
    let height = max(r.height, th * 1.5, textHeight + 2 * padY)
    let field = CGRect(x: r.minX, y: r.minY, width: width, height: height)

    let line = max(2, th * 0.06)
    let radius = min(th * 0.3, height / 2)
    let path = UIBezierPath(roundedRect: field.insetBy(dx: line / 2, dy: line / 2), cornerRadius: radius)
    cg.saveGState()
    cg.setFillColor(ExportPalette.answerBackground.cgColor)
    cg.addPath(path.cgPath)
    cg.fillPath()
    cg.setStrokeColor(ExportPalette.purple.cgColor)
    cg.setLineWidth(line)
    cg.addPath(path.cgPath)
    cg.strokePath()
    cg.restoreGState()

    let textRect = CGRect(x: field.minX + padX, y: field.minY + max(padY, (height - textHeight) / 2),
                          width: innerWidth, height: textHeight)
    writing.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
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
