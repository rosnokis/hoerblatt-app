import Foundation
import UIKit

// Selbsttest (Einstellungen → Fehlersuche): goes through all pages of the open Heft by itself and makes one ZIP for
// the developer: per page what was read (words, boxes, gaps, sentences), every word and gap "tapped" with what Wort
// and Satz would say, and the page picture (the PDF page as drawn for reading). Plus the voice and settings.
// No answers, marks or pen strokes; the pictures are the PDF pages only (no handwriting).
// On the developer's computer: tools/linuxtest/selftest.py.

struct SelfTestStatus: Equatable {
    var message: String
    var progress: Double
}

@MainActor enum SelfTest {
    /// Waits until the Heft is read completely, then writes the package. nil: nothing could be written.
    static func run(heftId: UUID, app: AppState, status: @escaping (SelfTestStatus) -> Void) async -> URL? {
        // pages still missing are read first (in the background, as when the child turns pages)
        app.readMissingHeftPages()
        while let h = app.store.heft(heftId), !h.unread.isEmpty, app.heftReadingBusy {
            let total = max(1, h.pageTotal)
            status(SelfTestStatus(message: "Heft wird noch gelesen: \(h.pages.count) von \(total) Seiten …",
                                  progress: Double(h.pages.count) / Double(total) * 0.5))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let heft = app.store.heft(heftId) else { return nil }

        let fm = FileManager.default
        let stamp = selfTestStamp()
        let root = fm.temporaryDirectory.appendingPathComponent("Hoerblatt-Selbsttest", isDirectory: true)
        try? fm.removeItem(at: root)
        let dir = root.appendingPathComponent("Selbsttest-" + stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return nil
        }

        var pages: [[String: Any]] = []
        let numbers = heft.pageNumbers
        let order = numbers.indices.sorted { numbers[$0] < numbers[$1] }
        for (step, k) in order.enumerated() {
            let n = numbers[k]
            status(SelfTestStatus(message: "Seite \(n + 1) wird geprüft …",
                                  progress: 0.5 + 0.5 * Double(step) / Double(max(1, order.count))))
            // (let the screen show the progress between pages)
            await Task.yield()
            guard let stored = app.store.loadPage(heft.pages[k]) else { continue }
            var page = stored
            page.answers = []
            page.marks = []
            page.drawing = Data()
            let reading = Reading(page: page)
            var d = PageReport.dict(page, reading: reading)
            d["number"] = n + 1
            // Vision's own words (before the layout analysis), to replay the page exactly
            if let raw = stored.visionWords {
                d["vision"] = raw.map { w -> [String: Any] in
                    ["t": w.text, "r": hearingRect(w.rect), "line": w.line, "conf": hearingRound(CGFloat(w.confidence))]
                }
            }
            d["taps"] = PageReport.taps(page, reading: reading, boxesTogether: app.settings.boxesTogether)
            let name = String(format: "seite-%02d.jpg", n + 1)
            // the PDF page drawn again (the very pixels that were read); the stored picture if the page was turned
            var picture: UIImage? = nil
            if let drawn = app.heftPagePicture(heftId, number: n), let cg = drawn.cgImage,
               CGFloat(cg.width) == stored.pixelSize.width, CGFloat(cg.height) == stored.pixelSize.height {
                picture = drawn
            }
            if picture == nil { picture = app.store.loadImage(stored.id) }
            if let picture = picture, let data = picture.jpegData(compressionQuality: 0.9) {
                try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
                d["image"] = name
                if let cg = picture.cgImage { d["imagePixels"] = [cg.width, cg.height] }
            }
            pages.append(d)
        }

        var out: [String: Any] = [
            "format": "hoerblatt-selbsttest-1",
            "created": ISO8601DateFormatter().string(from: Date()),
            "device": ["system": UIDevice.current.systemVersion, "model": UIDevice.current.model] as [String: String],
            "voice": speechVoiceReport(),
            "heft": ["title": heft.title, "total": heft.pageTotal, "read": heft.pages.count,
                     "unread": heft.unread.map { $0 + 1 }] as [String: Any],
            "pages": pages
        ]
        if let data = try? JSONEncoder().encode(app.settings),
           let settings = try? JSONSerialization.jsonObject(with: data) {
            out["settings"] = settings
        }
        guard JSONSerialization.isValidJSONObject(out),
              let json = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        do {
            try json.write(to: dir.appendingPathComponent("selbsttest.json"), options: .atomic)
        } catch {
            return nil
        }
        status(SelfTestStatus(message: "Paket wird gepackt …", progress: 1))
        await Task.yield()
        let zip = root.appendingPathComponent("Hoerblatt-Selbsttest-" + stamp + ".zip")
        if selfTestZip(dir, to: zip) { return zip }
        // (no ZIP: at least the report without pictures)
        return dir.appendingPathComponent("selbsttest.json")
    }
}

/// A folder as a ZIP file: the system packs it when the folder is read "for uploading".
fileprivate func selfTestZip(_ folder: URL, to target: URL) -> Bool {
    var ok = false
    var failure: NSError? = nil
    NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &failure) { packed in
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: packed, to: target)
            ok = true
        } catch {
            ok = false
        }
    }
    return ok && failure == nil
}

fileprivate func selfTestStamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "yyyy-MM-dd-HHmm"
    return f.string(from: Date())
}
