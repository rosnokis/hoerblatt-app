import SwiftUI
import UIKit
import CoreText
import UniformTypeIdentifiers

// Schrift: one typeface for everything the Hörblatt writes itself – answers, Wort-Lupe tiles, Schreibblatt, the
// handed-in PDF, buttons, menus and settings (printed text on photos and PDFs is a picture and stays as it is).
// The teacher chooses it in the settings: the iPad's own font (as before), one of the free fonts that come with the
// app (folder "Schriften", SIL Open Font License / Bitstream Vera + CC BY, licence texts beside them), any other font
// of the iPad, or a font file of their own (copied to Documents/Schriften and registered for this app only).
// A new choice takes effect when the settings close (the screen is built anew, `AppState.fontGeneration`).

/// A font that comes with the app.
struct BuiltInFont: Identifiable {
    let family: String
    let title: String
    let note: String
    var id: String { family }
}

/// A font file the teacher added (Documents/Schriften).
struct OwnFont: Identifiable, Equatable {
    let file: URL
    let family: String
    var id: String { file.lastPathComponent }
}

enum AppFont {
    /// The chosen family, nil: the iPad's own font (San Francisco; answers rounded, as before).
    // (read while drawing, also off the main thread for the PDF; only changed on the main thread)
    nonisolated(unsafe) private(set) static var family: String? = nil

    static let builtIn: [BuiltInFont] = [
        BuiltInFont(family: "Playwrite DE Grund", title: "Grundschrift-Art (Playwrite DE Grund)",
                    note: "Nach dem Vorbild der Grundschrift, wie sie in der Grundschule geschrieben wird."),
        BuiltInFont(family: "OpenDyslexic", title: "OpenDyslexic",
                    note: "Für Kinder mit Lese-Rechtschreib-Schwäche: Buchstaben unten schwerer, kaum zu verwechseln."),
        BuiltInFont(family: "Andika", title: "Andika",
                    note: "Für Leseanfänger: a und g wie mit der Hand geschrieben, I, l und 1 gut zu unterscheiden."),
        BuiltInFont(family: "Lexend", title: "Lexend",
                    note: "Breite, ruhige Buchstaben mit viel Abstand."),
        BuiltInFont(family: "Atkinson Hyperlegible", title: "Atkinson Hyperlegible",
                    note: "Für schlechtes Sehen: ähnliche Buchstaben sehen deutlich verschieden aus.")
    ]

    /// Where added font files are kept.
    static var ownFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Schriften", isDirectory: true)
    }

    nonisolated(unsafe) private static var registered = false

    /// Registers the app's fonts and the teacher's own (once, at the start).
    static func registerAll() {
        if registered { return }
        registered = true
        for url in bundledFiles() + ownFiles() { register(url) }
    }

    /// Uses this family from now on (nil, or a family the iPad does not have: the iPad's own font).
    /// Returns whether anything changed.
    @discardableResult
    static func use(_ wanted: String?) -> Bool {
        let fam = wanted.flatMap { available($0) ? $0 : nil }
        if fam == family { return false }
        family = fam
        return true
    }

    /// Navigation bar titles in the chosen typeface (bars made from now on).
    @MainActor static func styleBars() {
        let nav = UINavigationBar.appearance()
        if family != nil {
            nav.titleTextAttributes = [.font: ui(17, weight: .semibold)]
            nav.largeTitleTextAttributes = [.font: ui(34, weight: .bold)]
        } else {
            nav.titleTextAttributes = nil
            nav.largeTitleTextAttributes = nil
        }
    }

    /// Whether the iPad (with the fonts registered here) knows this family.
    static func available(_ family: String) -> Bool {
        return face(family, size: 12, bold: false) != nil
    }

    /// The chosen font in this size (bold from semibold on); without a choice: the system font.
    static func ui(_ size: CGFloat, weight: UIFont.Weight = .regular, rounded: Bool = false) -> UIFont {
        if let fam = family, let f = face(fam, size: size, bold: weight.rawValue >= UIFont.Weight.semibold.rawValue) { return f }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if rounded, let d = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: d, size: size) }
        return base
    }

    /// A face of this family (bold if it has one), nil if the iPad does not know the family.
    static func face(_ family: String, size: CGFloat, bold: Bool) -> UIFont? {
        var d = UIFontDescriptor(fontAttributes: [.family: family])
        if bold, let b = d.withSymbolicTraits(.traitBold) { d = b }
        let f = UIFont(descriptor: d, size: size)
        if f.familyName == family { return f }
        // (bold asked, but the family has none: its regular face)
        let r = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: family]), size: size)
        return r.familyName == family ? r : nil
    }

    // MARK: Files

    /// The font files that come with the app (folder "Schriften" in the app; found wherever the build put it).
    static func bundledFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where isFontFile(url) { out.append(url) }
        return out
    }

    static func ownFiles() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: ownFolder, includingPropertiesForKeys: nil)) ?? []
        return items.filter(isFontFile).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isFontFile(_ url: URL) -> Bool {
        return ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased())
    }

    /// The families in a font file (empty: not a font CoreText can read).
    static func families(in url: URL) -> [String] {
        guard let ds = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        var out: [String] = []
        for d in ds {
            if let n = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String, !out.contains(n) {
                out.append(n)
            }
        }
        return out
    }

    /// The teacher's fonts, one entry per family.
    static func ownFonts() -> [OwnFont] {
        var out: [OwnFont] = []
        for url in ownFiles() {
            for fam in families(in: url) where !out.contains(where: { $0.family == fam }) {
                out.append(OwnFont(file: url, family: fam))
            }
        }
        return out
    }

    @discardableResult
    static func register(_ url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // (already registered counts as done)
        return !families(in: url).isEmpty && families(in: url).allSatisfy { available($0) }
    }

    /// Copies a chosen font file into the app and registers it. Returns its families, or a message for the teacher.
    static func add(_ source: URL) -> Result<[String], AppFontError> {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard isFontFile(source) else { return .failure(.notAFont) }
        let fm = FileManager.default
        try? fm.createDirectory(at: ownFolder, withIntermediateDirectories: true, attributes: nil)
        var target = ownFolder.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            target = ownFolder.appendingPathComponent("\(stem) \(n).\(source.pathExtension)")
            n += 1
        }
        do {
            try fm.copyItem(at: source, to: target)
        } catch {
            return .failure(.copy)
        }
        let fams = families(in: target)
        if fams.isEmpty {
            try? fm.removeItem(at: target)
            return .failure(.notAFont)
        }
        register(target)
        return .success(fams)
    }

    /// Removes an added font file (the font stays usable until the app is restarted, CoreText keeps it).
    static func remove(_ font: OwnFont) {
        var error: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(font.file as CFURL, .process, &error)
        try? FileManager.default.removeItem(at: font.file)
    }

    /// Letters a font for German children's work must have.
    static func missingLetters(_ family: String) -> String {
        guard let f = face(family, size: 12, bold: false) else { return "" }
        let ct = f as CTFont
        var missing = ""
        for ch in "äöüÄÖÜß" {
            var units = Array(String(ch).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if !CTFontGetGlyphsForCharacters(ct, &units, &glyphs, units.count) { missing.append(ch) }
        }
        return missing
    }

    /// The iPad's own font families (without the app's and the teacher's).
    static func systemFamilies() -> [String] {
        let mine = Set(builtIn.map(\.family) + ownFonts().map(\.family))
        return UIFont.familyNames.filter { !$0.hasPrefix(".") && !mine.contains($0) }.sorted()
    }

    /// What the settings show as the current choice.
    static func title(of family: String?) -> String {
        guard let fam = family else { return "Schrift des iPads (Standard)" }
        return builtIn.first(where: { $0.family == fam })?.title ?? fam
    }
}

enum AppFontError: Error {
    case notAFont, copy

    var message: String {
        switch self {
        case .notAFont: return "Das ist keine Schriftdatei, die das iPad lesen kann (gesucht: .ttf oder .otf)."
        case .copy: return "Die Datei ließ sich nicht kopieren. Bitte noch einmal versuchen."
        }
    }
}

// MARK: - SwiftUI

extension Font {
    /// A font of the chosen typeface in this size (the system font when none is chosen).
    static func hb(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard AppFont.family != nil else { return .system(size: size, weight: weight, design: design) }
        return Font(AppFont.ui(size, weight: appFontWeight(weight)) as CTFont)
    }

    /// A text style (headline, callout, …) in the chosen typeface; follows the iPad's text size.
    static func hb(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        guard AppFont.family != nil else {
            let f = Font.system(style)
            return weight.map { f.weight($0) } ?? f
        }
        let size = UIFont.preferredFont(forTextStyle: appFontTextStyle(style)).pointSize
        let w = weight ?? (style == .headline ? .semibold : .regular)
        return Font(AppFont.ui(size, weight: appFontWeight(w)) as CTFont)
    }
}

private func appFontWeight(_ w: Font.Weight) -> UIFont.Weight {
    switch w {
    case .ultraLight: return .ultraLight
    case .thin: return .thin
    case .light: return .light
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .heavy: return .heavy
    case .black: return .black
    default: return .regular
    }
}

private func appFontTextStyle(_ s: Font.TextStyle) -> UIFont.TextStyle {
    switch s {
    case .largeTitle: return .largeTitle
    case .title: return .title1
    case .title2: return .title2
    case .title3: return .title3
    case .headline: return .headline
    case .subheadline: return .subheadline
    case .callout: return .callout
    case .footnote: return .footnote
    case .caption: return .caption1
    case .caption2: return .caption2
    default: return .body
    }
}

// MARK: - Settings

/// Einstellungen → Schrift: choose the typeface, add font files, other fonts of the iPad.
struct FontSettingsSection: View {
    @Binding var family: String?
    @State private var own: [OwnFont] = AppFont.ownFonts()
    @State private var picking = false
    @State private var message: String? = nil

    var body: some View {
        Section {
            choice(nil, title: "Schrift des iPads (Standard)", note: nil)
            ForEach(AppFont.builtIn) { f in
                choice(f.family, title: f.title, note: f.note)
            }
            ForEach(own) { f in
                choice(f.family, title: f.family, note: "Eigene Schrift (\(f.file.lastPathComponent))")
                    .swipeActions {
                        Button(role: .destructive) {
                            if family == f.family { family = nil }
                            AppFont.remove(f)
                            own = AppFont.ownFonts()
                        } label: {
                            SwiftUI.Label("Entfernen", systemImage: "trash")
                        }
                    }
            }
            NavigationLink {
                FontSystemList(family: $family)
            } label: {
                HStack {
                    SwiftUI.Label("Andere Schrift des iPads …", systemImage: "textformat")
                    Spacer()
                    if let fam = family, !isListed(fam) {
                        Text(fam).foregroundColor(.secondary)
                    }
                }
            }
            Button(action: { picking = true }) {
                SwiftUI.Label("Eigene Schrift hinzufügen …", systemImage: "plus.circle")
            }
            if let m = message {
                Text(m).font(.hb(.callout)).foregroundColor(.orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("So sieht es aus:")
                    .font(.hb(.caption))
                    .foregroundColor(.secondary)
                Text("Der Prinz ritt durch den Wald.\nIl1 ag äöüß ABC 123")
                    .font(sample(26))
                    .foregroundColor(Color(red: 0.11, green: 0.25, blue: 0.69))
                if let fam = family, !AppFont.missingLetters(fam).isEmpty {
                    Text("Achtung: In dieser Schrift fehlen \(AppFont.missingLetters(fam).map(String.init).joined(separator: " ")).")
                        .font(.hb(.callout))
                        .foregroundColor(.orange)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Schrift")
        } footer: {
            Text("Gilt für alles, was das Hörblatt selbst schreibt: Antworten, Wort-Lupe, Schreibblatt, die abgegebene PDF, Knöpfe und diese Einstellungen. Gedruckter Text auf Fotos und PDF-Seiten bleibt, wie er ist. Die neue Schrift erscheint, sobald die Einstellungen geschlossen werden.\n\nEigene Schrift: eine .ttf- oder .otf-Datei aus der Dateien-App wählen (z. B. die Grundschrift des Grundschulverbands, wenn die Schule sie hat – sie darf wegen ihrer Lizenz nicht mit dem Hörblatt mitgeliefert werden). Zum Entfernen nach links wischen. Die mitgelieferten Schriften sind frei (SIL Open Font License bzw. Bitstream-Vera-Lizenz).")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.font], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var added: [String] = []
            var problem: String? = nil
            for url in urls {
                switch AppFont.add(url) {
                case .success(let fams): added += fams
                case .failure(let e): problem = e.message
                }
            }
            own = AppFont.ownFonts()
            if let first = added.first, AppFont.available(first) { family = first }
            message = problem
        }
    }

    private func isListed(_ fam: String) -> Bool {
        return AppFont.builtIn.contains { $0.family == fam } || own.contains { $0.family == fam }
    }

    private func sample(_ size: CGFloat) -> Font {
        guard let fam = family, let f = AppFont.face(fam, size: size, bold: false) else { return .system(size: size) }
        return Font(f as CTFont)
    }

    private func choice(_ fam: String?, title: String, note: String?) -> some View {
        Button(action: { family = fam }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(fam.flatMap { AppFont.face($0, size: 20, bold: false) }.map { Font($0 as CTFont) }
                              ?? .system(size: 20))
                        .foregroundColor(.primary)
                    if let n = note {
                        Text(n).font(.hb(.caption)).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if family == fam {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

/// All font families of the iPad, each shown in itself.
private struct FontSystemList: View {
    @Binding var family: String?
    @State private var search = ""
    private let all = AppFont.systemFamilies()

    var body: some View {
        List(all.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { fam in
            Button(action: { family = fam }) {
                HStack {
                    Text(fam)
                        .font(AppFont.face(fam, size: 20, bold: false).map { Font($0 as CTFont) } ?? .system(size: 20))
                        .foregroundColor(.primary)
                    Spacer()
                    if family == fam {
                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Schrift suchen")
        .navigationTitle("Schriften des iPads")
    }
}
