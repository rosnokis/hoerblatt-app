import Foundation
#if canImport(UIKit)
import CoreGraphics
import UIKit
#endif
// (without UIKit – the Linux test build in tools/linuxtest – the colours and the CGImage reading are left out)

// Shared data of the Hörblatt. Every position on a page is in pixels of the stored page image
// (upright, scale 1), origin top-left, y downwards.

/// One recognised word.
struct Word: Codable, Identifiable, Hashable {
    /// Index in `Page.words` (kept equal to the index).
    var id: Int
    var text: String
    var rect: CGRect
    /// Line number from the text recognition (rows are rebuilt from geometry in `Reading`).
    var line: Int
    /// Index into `Page.boxes` when the word stands in a printed box.
    var box: Int?
    /// 0…1 from the text recognition.
    var confidence: Float
}

enum GapKind: String, Codable {
    /// A writing line. `rect` spans the line from left to right; its bottom edge is the line itself,
    /// its height one text height above it (where the answer is written).
    case line
    /// An empty frame, a writing field, a grey square or dot: `rect` is the field itself.
    case box
}

/// A place where the child answers (shown in purple, a short tone in a sentence).
struct Gap: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: GapKind
    var rect: CGRect
    /// Read aloud when the empty gap is tapped (column heading of a table cell or a field group, e.g. "Nomen").
    var head: String?
    /// A full stop printed right after the gap ends the sentence.
    var endsSentence: Bool
    /// The gap stands within a line of text (false: a line on its own, e.g. for writing a whole sentence).
    var inText: Bool
}

/// A printed box (frame) around one or more words; its words are read together.
struct PrintedBox: Codable, Identifiable, Hashable {
    /// Index in `Page.boxes`.
    var id: Int
    var rect: CGRect
    /// A cell of a table: Wort reads the single word, Satz the whole cell (nil = an ordinary printed box).
    var cell: Bool? = nil
}

/// What the child said (or typed) for a gap or anywhere on the page.
struct Answer: Codable, Identifiable, Hashable {
    var id: UUID
    /// Where the field sits.
    var rect: CGRect
    /// The gap it answers, if any.
    var gap: UUID?
    var text: String
}

enum MarkColor: String, Codable, CaseIterable, Identifiable {
    case gelb, gruen, blau, orange
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gelb: return "Gelb"
        case .gruen: return "Grün"
        case .blau: return "Blau"
        case .orange: return "Orange"
        }
    }
    #if canImport(UIKit)
    /// Swatch in the tool tray.
    var swatch: UIColor {
        switch self {
        case .gelb: return UIColor(red: 0.98, green: 0.80, blue: 0.08, alpha: 1)
        case .gruen: return UIColor(red: 0.29, green: 0.87, blue: 0.50, alpha: 1)
        case .blau: return UIColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1)
        case .orange: return UIColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1)
        }
    }
    /// Highlighter fill on the page (see-through).
    var fill: UIColor { swatch.withAlphaComponent(0.5) }
    #endif
}

/// A highlighter mark on a word, or with `from`/`to` only on part of it.
struct Mark: Codable, Identifiable, Hashable {
    var id: UUID
    /// Index into `Page.words`.
    var word: Int
    var color: MarkColor
    /// Part of the word, as x positions in page pixels (both nil: the whole word).
    var from: CGFloat?
    var to: CGFloat?
}

enum PenColor: String, Codable, CaseIterable, Identifiable {
    case blau, rot, schwarz
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blau: return "Blau"
        case .rot: return "Rot"
        case .schwarz: return "Schwarz"
        }
    }
    #if canImport(UIKit)
    var ink: UIColor {
        switch self {
        case .blau: return UIColor(red: 0.11, green: 0.31, blue: 0.85, alpha: 1)
        case .rot: return UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1)
        case .schwarz: return UIColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1)
        }
    }
    #endif
}

/// One saved page in the Mappe: the photo's analysis plus everything the child did on it.
struct Page: Codable, Identifiable {
    var id: UUID
    var created: Date
    /// Short name for the Mappe (first words of the heading).
    var title: String
    /// Size of the stored image in pixels.
    var pixelSize: CGSize
    /// Typical height of the printed text in pixels (answer font size, hit tolerances).
    var textHeight: CGFloat
    var words: [Word]
    var gaps: [Gap]
    var boxes: [PrintedBox]
    var answers: [Answer]
    var marks: [Mark]
    /// PencilKit drawing (`PKDrawing.dataRepresentation()`), in page pixel coordinates.
    var drawing: Data
    /// The Heft (a PDF with several pages) this page belongs to, and its place in it (0 = first page).
    var heft: UUID? = nil
    var heftPage: Int? = nil
    /// The words as Vision read them, before the layout analysis (self test: replayed on the developer's computer).
    var visionWords: [Word]? = nil
}

/// Entry of the Mappe list (the page itself is loaded only when opened).
struct PageInfo: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var created: Date
    /// Pages of a Heft are shown in the Mappe as the Heft, not one by one.
    var heft: UUID? = nil
}

/// A PDF read page by page (e.g. an Ermittlerheft filled in over several lessons). Its pages are ordinary pages
/// of the Mappe; the Heft keeps their order and the page last worked on.
struct Heft: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var created: Date
    /// The pages read so far, in the order of the PDF.
    var pages: [UUID]
    /// Index into `pages`.
    var lastPage: Int
    /// The PDF page (0 = first) of each entry of `pages`; nil in Hefte read in one go (then 0, 1, 2 …).
    var numbers: [Int]? = nil
    /// Pages of the PDF; the ones not read yet are read in the background.
    var total: Int? = nil
}

extension Heft {
    var pageNumbers: [Int] {
        if let n = numbers, n.count == pages.count { return n }
        return Array(0..<pages.count)
    }

    var pageTotal: Int { max(total ?? 0, pages.count) }

    /// The page read from PDF page `number` (nil: not read yet).
    func page(number: Int) -> UUID? {
        guard let i = pageNumbers.firstIndex(of: number) else { return nil }
        return pages[i]
    }

    func number(of pageId: UUID) -> Int? {
        guard let i = pages.firstIndex(of: pageId) else { return nil }
        return pageNumbers[i]
    }

    /// PDF pages not read yet, first to last.
    var unread: [Int] {
        let have = Set(pageNumbers)
        return (0..<pageTotal).filter { !have.contains($0) }
    }

    /// Keeps the pages for which `keep` is true (with their numbers).
    mutating func keepPages(_ keep: (UUID) -> Bool) {
        let nums = pageNumbers
        var p: [UUID] = []
        var n: [Int] = []
        for (i, id) in pages.enumerated() where keep(id) {
            p.append(id)
            n.append(nums[i])
        }
        pages = p
        numbers = n
        lastPage = max(0, min(p.count - 1, lastPage))
    }

    /// Puts a newly read page into its place.
    mutating func insert(_ pageId: UUID, number: Int) {
        var nums = pageNumbers
        if nums.contains(number) { return }
        let at = nums.firstIndex(where: { $0 > number }) ?? nums.count
        let current = pages.indices.contains(lastPage) ? pages[lastPage] : nil
        pages.insert(pageId, at: at)
        nums.insert(number, at: at)
        numbers = nums
        // (the page last worked on stays the same)
        if let c = current, let k = pages.firstIndex(of: c) { lastPage = k }
    }
}

/// Piece of something read aloud: text, or the gap tone.
enum SpeechPart: Equatable {
    case text(String)
    case tone
}

enum ToneKind: String, Codable, CaseIterable, Identifiable {
    case glocke, tropfen, holz, pfiff
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glocke: return "Glöckchen"
        case .tropfen: return "Tropfen"
        case .holz: return "Klopfen"
        case .pfiff: return "Zwei Töne"
        }
    }
}

/// The tool in use (tray numbers as on the printed picture card).
enum Mode: String, Codable, CaseIterable {
    case wort, satz, sprechen, markieren, stift, radieren
    /// Spoken when the tool is chosen.
    var announcement: String {
        switch self {
        case .wort: return "Wort vorlesen"
        case .satz: return "Satz vorlesen"
        case .sprechen: return "Antwort sprechen. Tippe auf die Stelle."
        case .markieren: return "Markieren"
        case .stift: return "Stift"
        case .radieren: return "Radiergummi"
        }
    }
}

/// Left or right half when two pages lie side by side.
enum Side: String, Codable {
    case left, right
}

/// Settings for teachers, kept on this device.
struct AppSettings: Codable, Equatable {
    /// Speaking speed, 1 = normal (multiplies the system's default rate).
    var rate: Double = 0.85
    /// Speak the name of a tool when it is chosen, and short messages.
    var announce: Bool = true
    /// Thin outlines around recognised words.
    var outlines: Bool = true
    /// A word in a printed box reads the whole box (second tap on the same word: only the word).
    var boxesTogether: Bool = true
    /// Show gaps in purple.
    var markGaps: Bool = true
    /// The app listens itself; off: answers by keyboard (with its dictation key).
    var mic: Bool = true
    var tone: ToneKind = .glocke
    /// Short picture guide before the camera opens.
    var photoHelp: Bool = true
    var markColor: MarkColor = .gelb
    var penColor: PenColor = .blau
    /// Fertig: first show the picture to the teacher (thumb), only then "Teilen" appears.
    var showTeacherFirst: Bool = true

    private static let key = "hoerblatt.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.key)
        }
    }
}

extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case rate, announce, outlines, boxesTogether, markGaps, mic, tone, photoHelp, markColor, penColor, showTeacherFirst
    }

    /// Settings saved by an older version lack newer keys: those keep their defaults instead of losing all settings.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? rate
        announce = try c.decodeIfPresent(Bool.self, forKey: .announce) ?? announce
        outlines = try c.decodeIfPresent(Bool.self, forKey: .outlines) ?? outlines
        boxesTogether = try c.decodeIfPresent(Bool.self, forKey: .boxesTogether) ?? boxesTogether
        markGaps = try c.decodeIfPresent(Bool.self, forKey: .markGaps) ?? markGaps
        mic = try c.decodeIfPresent(Bool.self, forKey: .mic) ?? mic
        tone = (try? c.decodeIfPresent(ToneKind.self, forKey: .tone)) ?? tone
        photoHelp = try c.decodeIfPresent(Bool.self, forKey: .photoHelp) ?? photoHelp
        markColor = (try? c.decodeIfPresent(MarkColor.self, forKey: .markColor)) ?? markColor
        penColor = (try? c.decodeIfPresent(PenColor.self, forKey: .penColor)) ?? penColor
        showTeacherFirst = try c.decodeIfPresent(Bool.self, forKey: .showTeacherFirst) ?? showTeacherFirst
    }
}

/// Pixels of a page image for the layout analysis (row by row, top row first).
struct PixelImage {
    let width: Int
    let height: Int
    /// 4 bytes per pixel: red, green, blue, alpha.
    let rgba: [UInt8]
    /// 1 byte per pixel: brightness 0 (black) … 255 (white).
    let gray: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
        var g = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(rgba[i * 4]), gr = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            g[i] = UInt8((r * 77 + gr * 150 + b * 29) >> 8)
        }
        self.gray = g
    }

    #if canImport(UIKit)
    /// Draws the image into an RGBA buffer of its own pixel size.
    init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, rgba: buf)
    }
    #endif

    @inline(__always) func lum(_ x: Int, _ y: Int) -> UInt8 { gray[y * width + x] }
}
