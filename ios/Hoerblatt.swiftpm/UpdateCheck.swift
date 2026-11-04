import Foundation
import SwiftUI

// Is there a newer version? (Teacher, November 2026: updating should be easier; the school iPad has no Kurzbefehle.)
// The app reads version.json from the public app repository – one small file, nothing is sent from the iPad – and the
// settings offer the newest project as a ZIP (Safari downloads it). A Swift Playgrounds app cannot replace its own code,
// so opening the new version stays a step for the teacher. Switchable in the settings (`AppSettings.updateCheck`).

/// What the app repository says about its newest version (written by tools/publish-app.sh).
struct RemoteVersion: Codable, Equatable {
    var number: String
    var date: String
    /// What changed lately (the last changes, newest first).
    var notes: [String]? = nil
}

@MainActor final class UpdateCheck: ObservableObject {
    static let versionURL = URL(string: "https://raw.githubusercontent.com/rosnokis/hoerblatt-app/main/version.json")!
    static let downloadURL = URL(string: "https://github.com/rosnokis/hoerblatt-app/raw/main/Hoerblatt.swiftpm.zip")!

    @Published private(set) var latest: RemoteVersion? = nil
    @Published private(set) var checking = false
    @Published private(set) var failed = false
    private var lastCheck = Date.distantPast

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
            // (no cookies, no cache: only this one file is read)
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: config)
            do {
                let (data, response) = try await session.data(from: UpdateCheck.versionURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                latest = try JSONDecoder().decode(RemoteVersion.self, from: data)
            } catch {
                failed = true
            }
            session.finishTasksAndInvalidate()
            checking = false
        }
    }
}

/// Einstellungen → Installierte Version: switch, "Version N ist verfügbar", what is new, download.
struct UpdateRows: View {
    @ObservedObject var updates: UpdateCheck
    @Binding var enabled: Bool

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
                        if let notes = v.notes, !notes.isEmpty {
                            Text("Zuletzt geändert:")
                                .font(.caption.weight(.semibold))
                                .padding(.top, 2)
                            ForEach(Array(notes.prefix(6).enumerated()), id: \.offset) { _, n in
                                Text("• " + n)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Link(destination: UpdateCheck.downloadURL) {
                        SwiftUI.Label("Neue Version laden", systemImage: "square.and.arrow.down")
                            .font(.headline)
                    }
                    Text("Safari lädt „Hoerblatt.swiftpm.zip“ (in der Dateien-App unter „Downloads“). Die Datei antippen, dann wird sie entpackt; „Hoerblatt.swiftpm“ wie bisher in Swift Playgrounds öffnen. Mappe, Antworten, Schrank und Einstellungen bleiben erhalten.")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                Button(action: {
                    updates.check(force: true)
                }) {
                    SwiftUI.Label("Jetzt prüfen", systemImage: "arrow.clockwise")
                }
                .disabled(updates.checking)
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
}
