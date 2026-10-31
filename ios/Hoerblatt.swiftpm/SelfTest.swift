import Foundation
import UIKit

// Selbsttest (Einstellungen → Fehlersuche): goes through the pages of the open Heft (or one photo, or all photos of
// the Mappe) by itself and makes one ZIP for the developer: per page what was read (words, boxes, gaps, sentences),
// every word and gap "tapped" with what Wort and Satz would say, and the page picture. Plus the voice and settings.
// No answers, marks or pen strokes. Heft: the pictures are the PDF pages (no handwriting); photos are the photos as
// taken – they may show handwriting (the settings say so).
// On the developer's computer: tools/linuxtest/selftest.py.

struct SelfTestStatus: Equatable {
    var message: String
    var progress: Double
}

/// What the self test goes through.
enum SelfTestScope {
    /// all pages of a Heft (pages not read yet are read first)
    case heft(UUID)
    /// one photographed page
    case photo(UUID)
    /// all photographed pages of the Mappe (not the pages of Hefte)
    case allPhotos
}

@MainActor enum SelfTest {
    /// Writes the package (a Heft: once it is read completely). nil: nothing could be written.
    static func run(_ scope: SelfTestScope, app: AppState, status: @escaping (SelfTestStatus) -> Void) async -> URL? {
        // the pages to go through: (page id, number in the package, PDF page to draw again)
        var list: [(id: UUID, number: Int, pdfPage: Int?)] = []
        var heftInfo: [String: Any]? = nil
        var heftId: UUID? = nil
        switch scope {
        case .heft(let hid):
            // pages still missing are read first (in the background, as when the child turns pages)
            app.readMissingHeftPages()
            while let h = app.store.heft(hid), !h.unread.isEmpty, app.heftReadingBusy {
                let total = max(1, h.pageTotal)
                status(SelfTestStatus(message: "Heft wird noch gelesen: \(h.pages.count) von \(total) Seiten …",
                                      progress: Double(h.pages.count) / Double(total) * 0.5))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let heft = app.store.heft(hid) else { return nil }
            heftId = hid
            let numbers = heft.pageNumbers
            for k in numbers.indices.sorted(by: { numbers[$0] < numbers[$1] }) {
                list.append((id: heft.pages[k], number: numbers[k] + 1, pdfPage: numbers[k]))
            }
            heftInfo = ["title": heft.title, "total": heft.pageTotal, "read": heft.pages.count,
                        "unread": heft.unread.map { $0 + 1 }]
        case .photo(let pid):
            list = [(id: pid, number: 1, pdfPage: nil)]
        case .allPhotos:
            let photos = app.store.pages.filter { $0.heft == nil }.sorted { $0.created < $1.created }
            for (k, info) in photos.enumerated() {
                list.append((id: info.id, number: k + 1, pdfPage: nil))
            }
        }
        if list.isEmpty { return nil }

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
        // (a Heft used the first half of the bar for reading its missing pages)
        let base: Double = heftId == nil ? 0 : 0.5
        for (step, item) in list.enumerated() {
            let n = item.number
            status(SelfTestStatus(message: "Seite \(n) von \(list.count) wird geprüft …",
                                  progress: base + (1 - base) * Double(step) / Double(list.count)))
            // (let the screen show the progress between pages)
            await Task.yield()
            guard let stored = app.store.loadPage(item.id) else { continue }
            var page = stored
            page.answers = []
            page.marks = []
            page.drawing = Data()
            let reading = Reading(page: page)
            var d = PageReport.dict(page, reading: reading)
            d["number"] = n
            d["kind"] = item.pdfPage == nil ? "foto" : "pdf"
            // Vision's own words (before the layout analysis), to replay the page exactly
            if let raw = stored.visionWords {
                d["vision"] = raw.map { w -> [String: Any] in
                    ["t": w.text, "r": hearingRect(w.rect), "line": w.line, "conf": hearingRound(CGFloat(w.confidence))]
                }
            }
            d["taps"] = PageReport.taps(page, reading: reading, boxesTogether: app.settings.boxesTogether)
            let name = String(format: "seite-%02d.jpg", n)
            // a PDF page drawn again (the very pixels that were read); else the stored picture (photos, turned pages)
            var picture: UIImage? = nil
            if let hid = heftId, let pn = item.pdfPage, let drawn = app.heftPagePicture(hid, number: pn), let cg = drawn.cgImage,
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
            "pages": pages
        ]
        if let h = heftInfo {
            out["heft"] = h
        } else {
            out["fotos"] = list.count
        }
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
