import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Is there a newer version? (Teacher, November 2026: updating should be easier; the school iPad has no Kurzbefehle.)
// The app reads version.json from the public app repository – one small file, nothing is sent from the iPad.
// "Jetzt aktualisieren": the teacher has chosen the folder with the project once (e.g. "Hoerblatt" in the Dateien app,
// the project may sit deeper, e.g. hoerblatt-app-main/ios/Hoerblatt.swiftpm). The app loads the project ZIP, checks
// it (ZipRead.swift), keeps the old version as "Hoerblatt Sicherung (vorige Version)" next to it and writes the new
// files into every "Hoerblatt.swiftpm" found there. Swift Playgrounds builds the new code once the project is closed
// and opened again (a running app cannot replace itself). Fallback: the ZIP with Safari. Switchable
// (`AppSettings.updateCheck`).

/// What the app repository says about its newest version (written by tools/publish-app.sh).
struct RemoteVersion: Codable, Equatable {
    var number: String
    var date: String
    /// What changed lately (the last changes, newest first; versions before 68 show these).
    var notes: [String]? = nil
    /// Every change with the version it came with, newest first.
    var changes: [RemoteChange]? = nil

    /// What is new compared with the installed version: the changes of the offered version and of all versions
    /// in between, newest first. (No list with numbers: the latest changes as before.)
    func newSince(_ installed: Int) -> [RemoteChange] {
        guard let list = changes else {
            return (notes ?? []).map { RemoteChange(number: "", text: $0) }
        }
        return list.filter { (Int($0.number) ?? 0) > installed }
    }
}

struct RemoteChange: Codable, Equatable {
    var number: String
    var text: String
}

@MainActor final class UpdateCheck: ObservableObject {
    // (nonisolated: the file helpers below use them off the main actor)
    nonisolated static let versionURL = URL(string: "https://raw.githubusercontent.com/rosnokis/hoerblatt-app/main/version.json")!
    nonisolated static let zipURL = URL(string: "https://raw.githubusercontent.com/rosnokis/hoerblatt-app/main/Hoerblatt.swiftpm.zip")!
    nonisolated static let downloadURL = URL(string: "https://github.com/rosnokis/hoerblatt-app/raw/main/Hoerblatt.swiftpm.zip")!
    nonisolated static let projectName = "Hoerblatt.swiftpm"
    nonisolated static let backupName = "Hoerblatt Sicherung (vorige Version)"

    @Published private(set) var latest: RemoteVersion? = nil
    @Published private(set) var checking = false
    @Published private(set) var failed = false
    /// The folder with the project (nil: none chosen yet).
    @Published private(set) var folderName: String? = nil
    /// While updating: what happens now.
    @Published private(set) var installing: String? = nil
    /// After updating: the outcome (ok: the new version is in the folder).
    @Published private(set) var installed: (ok: Bool, text: String)? = nil
    private var lastCheck = Date.distantPast

    private let bookmarkKey = "hoerblatt.update.ordner"
    private let nameKey = "hoerblatt.update.ordnername"

    init() {
        if UserDefaults.standard.data(forKey: bookmarkKey) != nil {
            folderName = UserDefaults.standard.string(forKey: nameKey) ?? "Ordner"
        }
    }

    /// The newest version, if it is newer than this one (a development copy without a number never asks).
    var newer: RemoteVersion? {
        guard let l = latest, let n = Int(l.number), let have = Int(BuildInfo.number), n > have else { return nil }
        return l
    }

    /// At most once an hour unless forced (the button in the settings).
    func check(force: Bool = false) {
        if checking { return }
        if !force && Date().timeIntervalSince(lastCheck) < 3600 { return }
        lastCheck = Date()
        checking = true
        failed = false
        Task { @MainActor in
            do {
                let data = try await updateLoad(UpdateCheck.versionURL)
                latest = try JSONDecoder().decode(RemoteVersion.self, from: data)
            } catch {
                failed = true
            }
            checking = false
        }
    }

    /// The folder picked in the settings (remembered with the system's bookmark). false: it cannot be used.
    func choose(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
        folderName = url.lastPathComponent
        installed = nil
        return true
    }

    /// How many projects the chosen folder holds (nil: the folder cannot be reached).
    func projectCount() -> Int? {
        guard let folder = resolve() else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return updateFindProjects(folder).count
    }

    /// Loads the newest project and writes it into the chosen folder.
    func install() {
        guard installing == nil, let v = newer else { return }
        installed = nil
        installing = "Version \(v.number) wird geladen …"
        Task { @MainActor in
            do {
                // (the version in the URL: GitHub's cache must not hand out an older ZIP)
                var parts = URLComponents(url: UpdateCheck.zipURL, resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "v", value: v.number)]
                let data = try await updateLoad(parts.url ?? UpdateCheck.zipURL)
                installing = "Version \(v.number) wird eingespielt …"
                let files = try updateProjectFiles(data, number: v.number)
                guard let folder = resolve() else {
                    throw UpdateError.folder
                }
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                let targets = updateFindProjects(folder)
                if targets.isEmpty { throw UpdateError.noProject }
                for t in targets {
                    try updateWrite(files, into: t)
                }
                installed = (true, targets.count == 1
                    ? "Version \(v.number) ist eingespielt."
                    : "Version \(v.number) ist in \(targets.count) Projekte eingespielt.")
            } catch let e as UpdateError {
                installed = (false, e.text)
            } catch let e as ZipReadError {
                installed = (false, e == .compressed ? "Die geladene Datei hat ein unbekanntes Format."
                    : "Die geladene Datei ist beschädigt. Bitte noch einmal versuchen.")
            } catch {
                installed = (false, "Das Laden hat nicht geklappt (kein Internet?). Bitte später noch einmal versuchen.")
            }
            installing = nil
        }
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
}

enum UpdateError: Error {
    case folder, noProject, wrongVersion, incomplete, write

    var text: String {
        switch self {
        case .folder: return "Der gewählte Ordner ist nicht erreichbar. Bitte den Ordner neu wählen."
        case .noProject: return "Im gewählten Ordner gibt es kein „Hoerblatt.swiftpm“. Bitte den Ordner wählen, in dem das Projekt liegt."
        case .wrongVersion: return "GitHub liefert noch die vorige Fassung. Bitte in ein paar Minuten noch einmal versuchen."
        case .incomplete: return "Die geladene Datei ist unvollständig. Bitte noch einmal versuchen."
        case .write: return "Die neuen Dateien ließen sich nicht schreiben. Die vorige Version liegt als Sicherung daneben."
        }
    }
}

// MARK: - Loading and writing (no actor state)

/// One file from GitHub: no cookies, no cache, only reading.
fileprivate func updateLoad(_ url: URL) async throws -> Data {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 30
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
    return data
}

/// The project's files from the ZIP (paths inside the project), checked: complete and really the announced version.
fileprivate func updateProjectFiles(_ zip: Data, number: String) throws -> [String: Data] {
    let all = try zipReadStored(zip)
    let prefix = UpdateCheck.projectName + "/"
    var files: [String: Data] = [:]
    for (path, data) in all where path.hasPrefix(prefix) {
        files[String(path.dropFirst(prefix.count))] = data
    }
    guard files["Package.swift"] != nil, files["ContentView.swift"] != nil, let info = files["BuildInfo.swift"] else {
        throw UpdateError.incomplete
    }
    guard String(decoding: info, as: UTF8.self).contains("\"\(number)\"") else { throw UpdateError.wrongVersion }
    return files
}

/// Every folder "Hoerblatt.swiftpm" in the chosen folder (it may be the project itself), a few levels deep.
fileprivate func updateFindProjects(_ root: URL) -> [URL] {
    if root.lastPathComponent == UpdateCheck.projectName { return [root] }
    var found: [URL] = []
    func walk(_ dir: URL, _ depth: Int) {
        if depth > 5 || found.count >= 5 { return }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { continue }
            let name = item.lastPathComponent
            if name == UpdateCheck.projectName {
                found.append(item)
            } else if item.pathExtension != "swiftpm" && name != "tess" && name != UpdateCheck.backupName {
                walk(item, depth + 1)
            }
        }
    }
    walk(root, 0)
    return found
}

/// The old project is copied next to it as the backup, then the new files are written over it; Swift files that
/// the new version no longer has are removed (hidden files of Swift Playgrounds stay).
fileprivate func updateWrite(_ files: [String: Data], into project: URL) throws {
    let fm = FileManager.default
    let backup = project.deletingLastPathComponent().appendingPathComponent(UpdateCheck.backupName, isDirectory: true)
    var failure: NSError? = nil
    // (this version is there already, e.g. "Jetzt aktualisieren" tapped twice: the backup of the version before stays)
    let installedInfo = try? Data(contentsOf: project.appendingPathComponent("BuildInfo.swift"))
    let already = installedInfo != nil && installedInfo == files["BuildInfo.swift"]
    if !already {
        var ok = true
        NSFileCoordinator().coordinate(readingItemAt: project, options: [], writingItemAt: backup, options: .forReplacing,
                                       error: &failure) { from, to in
            do {
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            } catch {
                ok = false
            }
        }
        // (without a backup nothing is overwritten)
        if !ok || failure != nil { throw UpdateError.write }
    }
    for (path, data) in files {
        guard zipSafePath(path) else { continue }
        let target = project.appendingPathComponent(path)
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &failure) { url in
            written = (try? data.write(to: url, options: .atomic)) != nil
        }
        if !written || failure != nil { throw UpdateError.write }
    }
    let keep = Set(files.keys)
    if let walker = fm.enumerator(at: project, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
        let base = project.standardizedFileURL.path + "/"
        for case let url as URL in walker where url.pathExtension == "swift" {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            if !keep.contains(rel) { try? fm.removeItem(at: url) }
        }
    }
}

// MARK: - Settings

/// Einstellungen → Installierte Version: switch, "Version N ist verfügbar", what is new, updating.
struct UpdateRows: View {
    @ObservedObject var updates: UpdateCheck
    @Binding var enabled: Bool
    @State private var picking = false
    @State private var folderMessage: String? = nil

    var body: some View {
        Group {
            Toggle("Nach neuer Version suchen", isOn: $enabled)
            if enabled {
                if let v = updates.newer {
                    VStack(alignment: .leading, spacing: 6) {
                        SwiftUI.Label("Version \(v.number) ist verfügbar", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .foregroundColor(UpdateStyle.teal)
                        Text("Veröffentlicht am \(v.date)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        let news = v.newSince(Int(BuildInfo.number) ?? 0)
                        if !news.isEmpty {
                            Text("Neu seit Version \(BuildInfo.number):")
                                .font(.caption.weight(.semibold))
                                .padding(.top, 2)
                            ForEach(Array(news.prefix(15).enumerated()), id: \.offset) { _, c in
                                Text((c.number.isEmpty ? "• " : "\(c.number) · ") + c.text)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if news.count > 15 {
                                Text("… und \(news.count - 15) weitere Änderungen")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    // (once it is in, the button goes: the next step is closing and opening the project)
                    if updates.folderName != nil && updates.installed?.ok != true {
                        Button(action: {
                            updates.install()
                        }) {
                            SwiftUI.Label("Jetzt aktualisieren", systemImage: "arrow.down.app.fill")
                                .font(.headline)
                        }
                        .disabled(updates.installing != nil)
                    }
                } else if updates.checking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Suche nach einer neuen Version …")
                            .foregroundColor(.secondary)
                    }
                } else if updates.failed {
                    Text("GitHub ist gerade nicht erreichbar (kein Internet?).")
                        .foregroundColor(.secondary)
                } else if updates.latest != nil {
                    Text("Das ist die neueste Version.")
                        .foregroundColor(.secondary)
                }
                if let step = updates.installing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(step)
                    }
                }
                if let result = updates.installed {
                    VStack(alignment: .leading, spacing: 4) {
                        SwiftUI.Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(result.ok ? UpdateStyle.green : .orange)
                        if result.ok {
                            Text("Jetzt in Swift Playgrounds das Projekt schließen und wieder öffnen, dann starten. Mappe, Antworten, Schrank und Einstellungen bleiben erhalten. Die vorige Version liegt als „\(UpdateCheck.backupName)“ daneben.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button(action: {
                    updates.check(force: true)
                }) {
                    SwiftUI.Label("Jetzt prüfen", systemImage: "arrow.clockwise")
                }
                .disabled(updates.checking)
                // the folder with the project, chosen once
                HStack(spacing: 10) {
                    SwiftUI.Image(systemName: updates.folderName == nil ? "folder.badge.questionmark" : "folder.fill")
                        .foregroundColor(updates.folderName == nil ? .orange : UpdateStyle.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updates.folderName.map { "Projektordner: \($0)" } ?? "Projektordner noch nicht gewählt")
                        if let m = folderMessage {
                            Text(m)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Button(updates.folderName == nil ? "Projektordner wählen …" : "Anderen Projektordner wählen …") {
                    folderMessage = nil
                    picking = true
                }
                if updates.newer != nil {
                    Link(destination: UpdateCheck.downloadURL) {
                        SwiftUI.Label("Stattdessen mit Safari laden", systemImage: "safari")
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType.folder]) { result in
            switch result {
            case .success(let url):
                if !updates.choose(url) {
                    folderMessage = "Dieser Ordner lässt sich nicht verwenden."
                } else if let n = updates.projectCount() {
                    folderMessage = n == 0 ? "Darin gibt es kein „Hoerblatt.swiftpm“ – bitte den Ordner wählen, in dem das Projekt liegt."
                        : n == 1 ? "Das Projekt wurde gefunden." : "\(n) Projekte gefunden; alle werden aktualisiert."
                }
            case .failure:
                folderMessage = "Es wurde kein Ordner gewählt."
            }
        }
        .onAppear {
            if enabled { updates.check() }
        }
        .onChange(of: enabled) { _, on in
            if on { updates.check(force: true) }
        }
    }
}

fileprivate enum UpdateStyle {
    static let teal = Color(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255)
    static let green = Color(red: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255)
}
