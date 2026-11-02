import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Abgabe (teacher, November 2026): the finished PDF is saved on the iPad, into a folder the teacher picks once in the
// settings (Dateien-App, e.g. "Auf meinem iPad › Abgaben"). Every hand-in is a new file with date and time in its
// name; a Heft is always saved whole. AirDrop stays as an option.
// As long as no folder is chosen (or it cannot be reached), the PDFs wait in the app's own Documents/Abgaben and move
// into the folder once one is chosen – nothing the child handed in gets lost.

/// What became of a hand-in.
enum HandinResult: Equatable {
    /// In the teacher's folder.
    case folder
    /// In the app's own waiting folder (no folder chosen, or it could not be reached).
    case app
    case failed
}

@MainActor final class HandinFolder: ObservableObject {
    /// Name of the chosen folder (nil: none chosen yet).
    @Published private(set) var folderName: String?
    /// PDFs waiting in the app for a folder.
    @Published private(set) var waitingCount = 0

    private let bookmarkKey = "hoerblatt.abgabe.ordner"
    private let nameKey = "hoerblatt.abgabe.ordnername"

    init() {
        if UserDefaults.standard.data(forKey: bookmarkKey) != nil {
            folderName = UserDefaults.standard.string(forKey: nameKey) ?? "Ordner"
        }
        countWaiting()
    }

    /// The folder picked in the settings: remembered for good (the system's bookmark keeps the permission).
    /// Waiting PDFs move there at once. false: the folder cannot be used.
    func choose(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
        folderName = url.lastPathComponent
        moveWaiting()
        return true
    }

    /// Saves the PDF under "<title> <day> <time>.pdf" (a new file every time).
    func save(_ pdf: URL, title: String) -> HandinResult {
        let name = handinFileName(title, date: Date())
        if let folder = resolve() {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            if handinCopy(pdf, into: folder, name: name) != nil {
                return .folder
            }
        }
        guard let local = waitingFolder() else { return .failed }
        if handinCopy(pdf, into: local, name: name) != nil {
            countWaiting()
            return .app
        }
        return .failed
    }

    /// PDFs saved while no folder could be reached go into the folder (and leave the app).
    func moveWaiting() {
        guard let local = waitingFolder(), let folder = resolve() else {
            countWaiting()
            return
        }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil, options: [])) ?? []
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        for file in files where file.pathExtension.lowercased() == "pdf" {
            let name = file.deletingPathExtension().lastPathComponent
            if handinCopy(file, into: folder, name: name) != nil {
                try? fm.removeItem(at: file)
            }
        }
        countWaiting()
    }

    private func countWaiting() {
        guard let local = waitingFolder() else {
            waitingCount = 0
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil, options: [])) ?? []
        waitingCount = files.filter { $0.pathExtension.lowercased() == "pdf" }.count
    }

    /// The chosen folder (renewing the bookmark when the system says it is old).
    private func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    /// Documents/Abgaben (kept on this iPad only, no iCloud backup – as the Mappe).
    private func waitingFolder() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        var dir = docs.appendingPathComponent("Abgaben", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return nil
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }
}

/// Copies the file into the folder as "<name>.pdf" ("<name> (2).pdf" if that exists). nil: it did not work.
fileprivate func handinCopy(_ source: URL, into folder: URL, name: String) -> URL? {
    let fm = FileManager.default
    var target = folder.appendingPathComponent(name + ".pdf")
    var n = 2
    while fm.fileExists(atPath: target.path) && n < 100 {
        target = folder.appendingPathComponent("\(name) (\(n)).pdf")
        n += 1
    }
    var ok = false
    var failure: NSError? = nil
    // (coordinated: the folder may belong to a file provider, e.g. a cloud folder)
    NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &failure) { url in
        do {
            try fm.copyItem(at: source, to: url)
            ok = true
        } catch {
            ok = false
        }
    }
    return ok && failure == nil ? target : nil
}

/// "Lama-Blatt 2.11.2026 10-15" – the page or Heft, the day and the time; never a child's name.
fileprivate func handinFileName(_ title: String, date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "d.M.yyyy HH-mm"
    let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
    var cleaned = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    if cleaned.isEmpty { cleaned = "Hörblatt" }
    if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) }
    return cleaned + " " + f.string(from: date)
}

// MARK: - Settings

/// Einstellungen → Abgabe: the folder, waiting PDFs, choosing another folder.
struct HandinSettingsSection: View {
    @ObservedObject var handin: HandinFolder
    @State private var picking = false
    @State private var message: String? = nil

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: handin.folderName == nil ? "folder.badge.questionmark" : "folder.fill")
                    .font(.title2)
                    .foregroundColor(handin.folderName == nil ? .orange : Color(red: 15.0 / 255, green: 118.0 / 255,
                                                                                 blue: 110.0 / 255))
                VStack(alignment: .leading, spacing: 2) {
                    Text(handin.folderName ?? "Noch kein Ordner gewählt")
                        .font(.headline)
                    if handin.folderName == nil {
                        Text("Abgaben werden vorerst in der App gesammelt und kommen in den Ordner, sobald einer gewählt ist.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            if handin.waitingCount > 0 {
                Text(handin.waitingCount == 1 ? "1 Abgabe wartet in der App auf den Ordner."
                     : "\(handin.waitingCount) Abgaben warten in der App auf den Ordner.")
                    .font(.callout)
                if handin.folderName != nil {
                    Button("Jetzt in den Ordner legen") {
                        handin.moveWaiting()
                        message = handin.waitingCount == 0 ? "Alle Abgaben liegen jetzt im Ordner."
                            : "Der Ordner ist gerade nicht erreichbar."
                    }
                }
            }
            Button(handin.folderName == nil ? "Ordner wählen …" : "Anderen Ordner wählen …") {
                message = nil
                picking = true
            }
            if let m = message {
                Text(m)
                    .font(.callout)
            }
        } header: {
            Text("Abgabe (PDF speichern)")
        } footer: {
            Text("Bei „Fertig“ tippt das Kind auf „Abgeben“: Die PDF wird in diesem Ordner gespeichert, jedes Mal als neue Datei mit Datum und Uhrzeit im Namen; eine Heftseite gibt immer das ganze Heft ab. Tipp: In der Dateien-App unter „Auf meinem iPad“ einen Ordner „Abgaben“ anlegen und hier wählen. Ein Cloud-Ordner geht auch – dann liegen die PDFs dort.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType.folder]) { result in
            switch result {
            case .success(let url):
                message = handin.choose(url) ? "Ordner gewählt: \(url.lastPathComponent)"
                    : "Dieser Ordner lässt sich nicht verwenden. Bitte einen anderen wählen."
            case .failure:
                message = "Es wurde kein Ordner gewählt."
            }
        }
    }
}
