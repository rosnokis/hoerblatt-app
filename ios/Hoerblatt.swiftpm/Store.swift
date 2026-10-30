import Foundation
import UIKit
import Combine

// The Mappe: every photographed page with everything the child did on it, kept only on this device.
// Documents/Mappe/<uuid>/{page.json, image.jpg, thumb.jpg}, the list in Documents/Mappe/index.json.
// Errors are ignored quietly: a missing file means a missing page, never a crash.

@MainActor final class PageStore: ObservableObject {
    /// Newest first.
    @Published private(set) var pages: [PageInfo] = []
    /// Newest first (Documents/Mappe/hefte.json).
    @Published private(set) var hefte: [Heft] = []

    private let folder: URL
    /// Thumbnails in memory; NSCache lets the system drop them when memory gets short.
    private let thumbs = NSCache<NSUUID, UIImage>()

    init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        var dir = docs.appendingPathComponent("Mappe", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        // photos and answers stay on this device (teacher's decision): no iCloud backup of the Mappe
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        folder = dir
        thumbs.countLimit = 150
        let scan = storeScan(dir)
        pages = scan.pages
        if scan.changed {
            storeWrite(scan.pages, to: dir.appendingPathComponent("index.json"))
        }
        // a Heft keeps only pages that are still there
        let present = Set(scan.pages.map { $0.id })
        var books = storeRead([Heft].self, from: dir.appendingPathComponent("hefte.json")) ?? []
        for i in books.indices {
            books[i].keepPages { present.contains($0) }
        }
        hefte = books.filter { !$0.pages.isEmpty }
    }

    // MARK: - Hefte

    func addHeft(_ heft: Heft) {
        hefte.removeAll { $0.id == heft.id }
        hefte.insert(heft, at: 0)
        writeHefte()
    }

    /// A page read in the background goes into its place in the Heft.
    func addHeftPage(_ heftId: UUID, page pageId: UUID, number: Int) {
        guard let i = hefte.firstIndex(where: { $0.id == heftId }) else { return }
        hefte[i].insert(pageId, number: number)
        writeHefte()
    }

    /// The PDF of a Heft, kept until all its pages are read (also after the app was closed).
    func heftPDFURL(_ id: UUID) -> URL {
        return folder.appendingPathComponent("hefte-pdf", isDirectory: true).appendingPathComponent(id.uuidString + ".pdf")
    }

    func saveHeftPDF(_ data: Data, _ id: UUID) {
        let url = heftPDFURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: nil)
        try? data.write(to: url, options: .atomic)
    }

    func deleteHeftPDF(_ id: UUID) {
        try? FileManager.default.removeItem(at: heftPDFURL(id))
    }

    func heft(_ id: UUID) -> Heft? {
        return hefte.first(where: { $0.id == id })
    }

    /// The Heft a page belongs to (nil: a single page).
    func heft(containing pageId: UUID) -> Heft? {
        return hefte.first(where: { $0.pages.contains(pageId) })
    }

    /// Remembers the page last opened in its Heft (the Heft opens there next time).
    func noteOpened(_ pageId: UUID) {
        guard let i = hefte.firstIndex(where: { $0.pages.contains(pageId) }),
              let k = hefte[i].pages.firstIndex(of: pageId), hefte[i].lastPage != k else { return }
        hefte[i].lastPage = k
        writeHefte()
    }

    /// The Heft with all its pages.
    func deleteHeft(_ id: UUID) {
        guard let h = heft(id) else { return }
        for p in h.pages {
            try? FileManager.default.removeItem(at: pageFolder(p))
            thumbs.removeObject(forKey: p as NSUUID)
        }
        let gone = Set(h.pages)
        deleteHeftPDF(id)
        hefte.removeAll { $0.id == id }
        pages.removeAll { gone.contains($0.id) }
        writeHefte()
        writeIndex()
    }

    /// Stores a newly recognised page and puts it first in the list.
    func add(page: Page, image: UIImage) {
        let dir = pageFolder(page.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let upright = storeUpright(image)
        if let data = upright.jpegData(compressionQuality: 0.85) {
            try? data.write(to: dir.appendingPathComponent("image.jpg"), options: .atomic)
        }
        if let thumb = storeMakeThumb(upright) {
            if let data = thumb.jpegData(compressionQuality: 0.8) {
                try? data.write(to: dir.appendingPathComponent("thumb.jpg"), options: .atomic)
            }
            thumbs.setObject(thumb, forKey: page.id as NSUUID)
        }
        // page.json last: a folder without it is an unfinished page and is not listed
        storeWrite(page, to: dir.appendingPathComponent("page.json"))
        pages.removeAll { $0.id == page.id }
        pages.insert(PageInfo(id: page.id, title: page.title, created: page.created, heft: page.heft), at: 0)
        writeIndex()
    }

    /// Writes the page (answers, marks, drawing …); the list only changes when the title did.
    func save(_ page: Page) {
        let dir = pageFolder(page.id)
        // a page deleted meanwhile (e.g. still open on the other half) stays deleted
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        storeWrite(page, to: dir.appendingPathComponent("page.json"))
        if let i = pages.firstIndex(where: { $0.id == page.id }), pages[i].title != page.title {
            pages[i].title = page.title
            writeIndex()
        }
    }

    func loadPage(_ id: UUID) -> Page? {
        return storeRead(Page.self, from: pageFolder(id).appendingPathComponent("page.json"))
    }

    /// The page image, scale 1 and upright (it was stored that way).
    func loadImage(_ id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: pageFolder(id).appendingPathComponent("image.jpg")) else { return nil }
        return UIImage(data: data, scale: 1)
    }

    /// About 300 px on the long side; made again from the page image when thumb.jpg is missing.
    /// For a Heft: its first page.
    func thumbnail(_ id: UUID) -> UIImage? {
        if let h = heft(id), let first = h.pages.first { return thumbnail(first) }
        if let cached = thumbs.object(forKey: id as NSUUID) { return cached }
        let url = pageFolder(id).appendingPathComponent("thumb.jpg")
        var thumb: UIImage? = nil
        if let data = try? Data(contentsOf: url) {
            thumb = UIImage(data: data, scale: 1)
        }
        if thumb == nil, let image = loadImage(id), let made = storeMakeThumb(image) {
            thumb = made
            if let data = made.jpegData(compressionQuality: 0.8) {
                try? data.write(to: url, options: .atomic)
            }
        }
        if let t = thumb {
            thumbs.setObject(t, forKey: id as NSUUID)
        }
        return thumb
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: pageFolder(id))
        thumbs.removeObject(forKey: id as NSUUID)
        pages.removeAll { $0.id == id }
        writeIndex()
        if let i = hefte.firstIndex(where: { $0.pages.contains(id) }) {
            hefte[i].keepPages { $0 != id }
            if hefte[i].pages.isEmpty {
                deleteHeftPDF(hefte[i].id)
                hefte.remove(at: i)
            }
            writeHefte()
        }
    }

    func deleteAll() {
        let fm = FileManager.default
        // empty the folder but keep it (it carries the no-backup flag)
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        thumbs.removeAllObjects()
        pages = []
        hefte = []
        writeIndex()
        writeHefte()
    }

    // MARK: - Files

    private func pageFolder(_ id: UUID) -> URL {
        return folder.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func writeIndex() {
        storeWrite(pages, to: folder.appendingPathComponent("index.json"))
    }

    private func writeHefte() {
        storeWrite(hefte, to: folder.appendingPathComponent("hefte.json"))
    }
}

// MARK: - Helpers (no actor state)

// Dates keep the default strategy. A stray NaN in a rectangle would make JSONEncoder throw and the
// whole page unsaveable, so such numbers are written as strings.
fileprivate func storeWrite<T: Encodable>(_ value: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    guard let data = try? encoder.encode(value) else { return }
    try? data.write(to: url, options: .atomic)
}

fileprivate func storeRead<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return try? decoder.decode(type, from: data)
}

/// The list as saved, without entries whose page is gone, plus pages whose entry got lost
/// (e.g. the app stopped between writing page.json and index.json). `changed`: the list must be written again.
fileprivate func storeScan(_ folder: URL) -> (pages: [PageInfo], changed: Bool) {
    let fm = FileManager.default
    let saved = storeRead([PageInfo].self, from: folder.appendingPathComponent("index.json"))
    var onDisk = Set<UUID>()
    let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names {
        guard let id = UUID(uuidString: name) else { continue }
        let json = folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("page.json")
        if fm.fileExists(atPath: json.path) {
            onDisk.insert(id)
        }
    }
    var result: [PageInfo] = []
    var seen = Set<UUID>()
    let savedList: [PageInfo] = saved ?? []
    for info in savedList {
        if onDisk.contains(info.id) && !seen.contains(info.id) {
            result.append(info)
            seen.insert(info.id)
        }
    }
    var found: [PageInfo] = []
    for id in onDisk {
        if seen.contains(id) { continue }
        let url = folder.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("page.json")
        if let page = storeRead(Page.self, from: url) {
            found.append(PageInfo(id: id, title: page.title, created: page.created, heft: page.heft))
        }
    }
    if !found.isEmpty {
        result.append(contentsOf: found)
        result.sort { $0.created > $1.created }
    }
    let changed: Bool
    if let s = saved {
        changed = s != result
    } else {
        changed = true
    }
    return (result, changed)
}

/// Upright, scale 1: the stored image must match the page's pixel coordinates.
@MainActor fileprivate func storeUpright(_ image: UIImage) -> UIImage {
    if image.imageOrientation == .up && image.scale == 1 { return image }
    let size = CGSize(width: (image.size.width * image.scale).rounded(),
                      height: (image.size.height * image.scale).rounded())
    guard size.width > 0, size.height > 0 else { return image }
    return storeRender(image, size: size)
}

@MainActor fileprivate func storeMakeThumb(_ image: UIImage) -> UIImage? {
    let w = image.size.width * image.scale
    let h = image.size.height * image.scale
    guard w > 0, h > 0 else { return nil }
    let k = min(1, 300 / max(w, h))
    let size = CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
    return storeRender(image, size: size)
}

@MainActor fileprivate func storeRender(_ image: UIImage, size: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { ctx in
        let rect = CGRect(origin: .zero, size: size)
        UIColor.white.setFill()
        ctx.fill(rect)
        image.draw(in: rect)
    }
}
