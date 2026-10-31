import Foundation
import UIKit
import Combine

// The Mappe: every photographed page with everything the child did on it, kept only on this device.
// Documents/Mappe/<uuid>/{page.json, image.jpg, thumb.jpg}, the list in Documents/Mappe/index.json.
// Errors are ignored quietly: a missing file means a missing page, never a crash.
// Deleted pages and Hefte go to the Papierkorb (Documents/Mappe/Papierkorb/<page uuid>/…, list in trash.json) and are
// deleted for good after 30 days; only the teacher sees it (Einstellungen).

/// An entry of the Papierkorb: one page, or a whole Heft with its pages.
struct TrashItem: Codable, Identifiable, Hashable {
    /// The page's id, or the Heft's id.
    var id: UUID
    var deleted: Date
    var title: String
    /// A whole Heft (its page folders are in the Papierkorb too, its PDF if it was still being read).
    var heft: Heft? = nil
    /// Page folders in the Papierkorb.
    var pages: [UUID]
    /// A single page that belonged to a Heft, and its PDF page there.
    var fromHeft: UUID? = nil
    var heftNumber: Int? = nil
}

@MainActor final class PageStore: ObservableObject {
    /// Newest first.
    @Published private(set) var pages: [PageInfo] = []
    /// Newest first (Documents/Mappe/hefte.json).
    @Published private(set) var hefte: [Heft] = []
    /// The Papierkorb, newest first.
    @Published private(set) var trash: [TrashItem] = []

    /// Days a deleted page stays in the Papierkorb.
    static let trashDays = 30

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
        // the Papierkorb keeps only entries whose pages are still there; old ones go for good
        let bin = folder.appendingPathComponent("Papierkorb", isDirectory: true)
        let items = storeRead([TrashItem].self, from: bin.appendingPathComponent("trash.json")) ?? []
        trash = items.filter { item in
            item.pages.contains { fm.fileExists(atPath: bin.appendingPathComponent($0.uuidString, isDirectory: true).path) }
        }
        purgeOldTrash()
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

    /// The Heft with all its pages (into the Papierkorb).
    func deleteHeft(_ id: UUID) {
        guard let h = heft(id) else { return }
        let moved = moveToTrash(h.pages)
        for p in h.pages {
            // (a page that could not be moved is deleted, as before)
            if !moved.contains(p) { try? FileManager.default.removeItem(at: pageFolder(p)) }
            thumbs.removeObject(forKey: p as NSUUID)
        }
        if !moved.isEmpty {
            // a Heft still being read keeps its PDF, so the reading can go on after restoring it
            let pdf = heftPDFURL(id)
            if FileManager.default.fileExists(atPath: pdf.path) {
                try? FileManager.default.moveItem(at: pdf, to: trashPDF(id))
            }
            trash.insert(TrashItem(id: id, deleted: Date(), title: h.title, heft: h, pages: moved), at: 0)
            writeTrash()
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

    /// A page into the Papierkorb (`toTrash` false: for good, e.g. a page read for a Heft deleted meanwhile).
    func delete(_ id: UUID, toTrash: Bool = true) {
        let info = pages.first(where: { $0.id == id })
        let owner = hefte.first(where: { $0.pages.contains(id) })
        var moved: [UUID] = []
        if toTrash, info != nil { moved = moveToTrash([id]) }
        if moved.isEmpty {
            try? FileManager.default.removeItem(at: pageFolder(id))
        } else {
            trash.insert(TrashItem(id: id, deleted: Date(), title: info?.title ?? "Seite", pages: moved,
                                   fromHeft: owner?.id, heftNumber: owner?.number(of: id)), at: 0)
            writeTrash()
        }
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

    /// Every Heft and page into the Papierkorb (each its own entry, to be restored one by one).
    func deleteAll() {
        for h in hefte { deleteHeft(h.id) }
        for info in pages { delete(info.id) }
        thumbs.removeAllObjects()
        pages = []
        hefte = []
        writeIndex()
        writeHefte()
    }

    // MARK: - Papierkorb

    /// Days until the entry is deleted for good (0: today).
    func daysLeft(_ item: TrashItem) -> Int {
        let end = item.deleted.addingTimeInterval(Double(PageStore.trashDays) * 86_400)
        return max(0, Int((end.timeIntervalSinceNow / 86_400).rounded(.up)))
    }

    /// The picture of the entry (a Heft: its first page).
    func trashThumbnail(_ item: TrashItem) -> UIImage? {
        guard let first = item.pages.first else { return nil }
        let dir = trashFolder.appendingPathComponent(first.uuidString, isDirectory: true)
        if let data = try? Data(contentsOf: dir.appendingPathComponent("thumb.jpg")) { return UIImage(data: data, scale: 1) }
        return nil
    }

    /// Back into the Mappe with all answers; a Heft as a whole, a page of a Heft into its Heft (if that is still there).
    func restore(_ itemId: UUID) {
        guard let k = trash.firstIndex(where: { $0.id == itemId }) else { return }
        let item = trash[k]
        let fm = FileManager.default
        var back: [UUID] = []
        for p in item.pages {
            let from = trashFolder.appendingPathComponent(p.uuidString, isDirectory: true)
            let to = pageFolder(p)
            if fm.fileExists(atPath: to.path) { continue }
            if (try? fm.moveItem(at: from, to: to)) != nil,
               fm.fileExists(atPath: to.appendingPathComponent("page.json").path) {
                back.append(p)
            }
        }
        let have = Set(back)
        if var h = item.heft {
            if fm.fileExists(atPath: trashPDF(h.id).path) {
                try? fm.createDirectory(at: heftPDFURL(h.id).deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: nil)
                try? fm.moveItem(at: trashPDF(h.id), to: heftPDFURL(h.id))
            }
            h.keepPages { have.contains($0) }
            if !h.pages.isEmpty && heft(h.id) == nil { hefte.insert(h, at: 0) }
        }
        for p in back {
            guard var page = loadPage(p) else { continue }
            if item.heft == nil, page.heft != nil {
                // a single page of a Heft: back into its Heft, or a page of its own when the Heft is gone
                if let hid = item.fromHeft, let n = item.heftNumber, let i = hefte.firstIndex(where: { $0.id == hid }) {
                    hefte[i].insert(p, number: n)
                } else {
                    page.heft = nil
                    page.heftPage = nil
                    storeWrite(page, to: pageFolder(p).appendingPathComponent("page.json"))
                }
            }
            pages.removeAll { $0.id == p }
            pages.append(PageInfo(id: p, title: page.title, created: page.created, heft: page.heft))
        }
        pages.sort { $0.created > $1.created }
        trash.remove(at: k)
        writeTrash()
        writeIndex()
        writeHefte()
    }

    /// Deletes the entry for good.
    func purge(_ itemId: UUID) {
        guard let k = trash.firstIndex(where: { $0.id == itemId }) else { return }
        let item = trash[k]
        for p in item.pages {
            try? FileManager.default.removeItem(at: trashFolder.appendingPathComponent(p.uuidString, isDirectory: true))
        }
        try? FileManager.default.removeItem(at: trashPDF(item.id))
        trash.remove(at: k)
        writeTrash()
    }

    /// Deletes everything in the Papierkorb for good.
    func emptyTrash() {
        try? FileManager.default.removeItem(at: trashFolder)
        trash = []
    }

    /// Entries older than 30 days go for good (when the app starts and when the settings open).
    func purgeOldTrash() {
        let limit = Date().addingTimeInterval(-Double(PageStore.trashDays) * 86_400)
        for item in trash where item.deleted < limit {
            purge(item.id)
        }
    }

    private var trashFolder: URL {
        return folder.appendingPathComponent("Papierkorb", isDirectory: true)
    }

    private func trashPDF(_ heftId: UUID) -> URL {
        return trashFolder.appendingPathComponent(heftId.uuidString + ".pdf")
    }

    /// Moves page folders into the Papierkorb; the ones moved.
    private func moveToTrash(_ ids: [UUID]) -> [UUID] {
        let fm = FileManager.default
        try? fm.createDirectory(at: trashFolder, withIntermediateDirectories: true, attributes: nil)
        var moved: [UUID] = []
        for id in ids {
            let from = pageFolder(id)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = trashFolder.appendingPathComponent(id.uuidString, isDirectory: true)
            try? fm.removeItem(at: to)
            if (try? fm.moveItem(at: from, to: to)) != nil { moved.append(id) }
        }
        return moved
    }

    private func writeTrash() {
        if trash.isEmpty && !FileManager.default.fileExists(atPath: trashFolder.path) { return }
        try? FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true, attributes: nil)
        storeWrite(trash, to: trashFolder.appendingPathComponent("trash.json"))
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
