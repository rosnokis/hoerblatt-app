import SwiftUI
import UIKit
import AVFoundation

// Help and settings for teachers (opens only after pressing the gear for 1 s).
// Everything is kept on this device (AppSettings in UserDefaults, the Mappe in the app's documents).

struct SettingsView: View {
    @ObservedObject var app: AppState
    @State private var askDeleteAll = false
    /// Read once when the sheet appears (listing the voices takes a moment).
    @State private var voiceInfo = ""
    /// The file of the "Fehlersuche" button, once made.
    @State private var diagnosisURL: URL? = nil
    /// Selbsttest: its progress while it runs, and the package once made.
    @State private var selfTestStatus: SelfTestStatus? = nil
    @State private var selfTestURL: URL? = nil
    /// Papierkorb: the entry to delete for good (asked first), and the question "leeren?".
    @State private var purgeItem: TrashItem? = nil
    @State private var askEmptyTrash = false

    var body: some View {
        NavigationStack {
            Form {
                readingSection
                pageSection
                answerSection
                mappeSection
                trashSection
                helpSection
                sharingSection
                privacySection
                voiceSection
                diagnosisSection
            }
            .navigationTitle("Hilfe und Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        app.showSettings = false
                    }
                    .font(.headline)
                }
            }
        }
        .onAppear {
            voiceInfo = settingsVoiceDescription()
            app.store.purgeOldTrash()
        }
    }

    // MARK: - Settings

    @MainActor
    private var readingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sprechtempo")
                    Spacer()
                    Text(settingsPercent(app.settings.rate))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 12) {
                    Image(systemName: "tortoise.fill")
                        .foregroundColor(.secondary)
                    Slider(value: $app.settings.rate, in: 0.5...1.3, step: 0.05, onEditingChanged: { editing in
                        if !editing {
                            app.say("So schnell lese ich vor.")
                        }
                    })
                    Image(systemName: "hare.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            Button(action: {
                app.say("Hallo! Ich lese dir das Arbeitsblatt vor. Tippe auf ein Wort.")
            }) {
                SwiftUI.Label("Stimme anhören", systemImage: "speaker.wave.2.fill")
            }
            Toggle("Ansagen", isOn: $app.settings.announce)
            VStack(alignment: .leading, spacing: 10) {
                Text("Lückenton")
                Picker("Lückenton", selection: $app.settings.tone) {
                    ForEach(ToneKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 4)
            .onChange(of: app.settings.tone) { _, _ in
                // (AppState has already handed the new tone to the speaker)
                app.speaker.playTone()
            }
            Button(action: {
                app.speaker.playTone()
            }) {
                SwiftUI.Label("Ton anhören", systemImage: "bell.fill")
            }
        } header: {
            Text("Vorlesen")
        } footer: {
            // (verbatim: a "%" in a localized key would be read as a format sign)
            Text(verbatim: "100 % ist das normale Tempo des iPads. Ansagen: Beim Wählen eines Werkzeugs wird sein Name gesagt (z. B. „Markieren“), dazu kurze Meldungen. Der Lückenton steht im vorgelesenen Satz für eine leere Lücke.")
        }
    }

    @MainActor
    private var pageSection: some View {
        Section {
            Toggle("Wort-Umrandungen", isOn: $app.settings.outlines)
            Toggle("Kästen zusammen vorlesen", isOn: $app.settings.boxesTogether)
            Toggle("Lücken markieren", isOn: $app.settings.markGaps)
            Toggle("Foto-Hinweis vor der Kamera", isOn: $app.settings.photoHelp)
            Toggle("Vor dem Abschicken der Lehrkraft zeigen", isOn: $app.settings.showTeacherFirst)
        } header: {
            Text("Blatt und Foto")
        } footer: {
            Text("Wort-Umrandungen: dünne Rahmen um erkannte Wörter. Kästen zusammen: Ein Wort in einem gedruckten Kasten liest den ganzen Kasten, dasselbe Wort noch einmal angetippt nur dieses Wort. Lücken markieren: Schreiblinien und Kästchen lila zeigen. Foto-Hinweis: kurze Bildanleitung (Heft flach, iPad gerade darüber, ganzes Blatt) vor jedem Foto. Der Lehrkraft zeigen: Bei „Fertig“ erscheint zuerst ein Daumen-Knopf; erst danach kann das Kind teilen.")
        }
    }

    @MainActor
    private var answerSection: some View {
        Section {
            Toggle("Mikrofon-Knopf", isOn: $app.settings.mic)
            if app.settings.mic && app.listener.blocked {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mic.slash.fill")
                        .foregroundColor(.orange)
                    Text("Das Mikrofon oder die Spracherkennung ist nicht erlaubt oder nicht verfügbar. Das Kind antwortet deshalb über die Tastatur. Erlauben: iPad-Einstellungen → Datenschutz & Sicherheit → Mikrofon bzw. Spracherkennung.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Antworten")
        } footer: {
            Text("An: Das Hörblatt hört nach dem Antippen einer Lücke selbst zu. Aus: Die Antwort kommt über die Tastatur, mit ihrer Diktier-Taste (Mikrofon unten auf der Tastatur).")
        }
    }

    /// Fehlersuche: a file about the open page for the developer.
    @MainActor
    private var diagnosisSection: some View {
        Section {
            Button(action: {
                if let c = app.active {
                    diagnosisURL = Diagnosis.file(for: c, app: app)
                }
            }) {
                SwiftUI.Label("Datei zur offenen Seite erstellen", systemImage: "ladybug")
            }
            .disabled(app.active == nil)
            if let url = diagnosisURL {
                ShareLink(item: url) {
                    SwiftUI.Label("Datei teilen", systemImage: "square.and.arrow.up")
                }
            }
            Button(action: {
                if let hid = app.active?.page.heft { startSelfTest(.heft(hid)) }
            }) {
                SwiftUI.Label("Selbsttest: ganzes Heft prüfen", systemImage: "checklist")
            }
            .disabled(app.active?.page.heft == nil || selfTestStatus != nil)
            Button(action: {
                if let c = app.active, c.page.heft == nil { startSelfTest(.photo(c.page.id)) }
            }) {
                SwiftUI.Label("Selbsttest: offenes Foto prüfen", systemImage: "camera")
            }
            .disabled(app.active == nil || app.active?.page.heft != nil || selfTestStatus != nil)
            Button(action: { startSelfTest(.allPhotos) }) {
                SwiftUI.Label("Selbsttest: alle Fotos prüfen", systemImage: "photo.on.rectangle")
            }
            .disabled(!app.store.pages.contains(where: { $0.heft == nil }) || selfTestStatus != nil)
            if let st = selfTestStatus {
                VStack(alignment: .leading, spacing: 6) {
                    Text(st.message)
                    ProgressView(value: st.progress)
                }
            }
            if let url = selfTestURL {
                ShareLink(item: url) {
                    SwiftUI.Label("Selbsttest teilen", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Fehlersuche")
        } footer: {
            Text("Die Datei beschreibt, wie das Hörblatt die offene Seite gelesen hat (Wörter, ihre Lage, Kästen, Lücken, Sätze). Antworten, Markierungen und Stiftstriche sind nicht darin. Sie hilft, Fehler beim Vorlesen zu finden. Der Selbsttest geht alle Seiten des offenen Hefts (oder das offene Foto, oder alle Fotos) durch, tippt jedes Wort und jede Lücke an und packt alles mit den Bildern der Seiten in eine ZIP-Datei. Achtung: Fotos zeigen das Blatt so, wie es fotografiert wurde – auch Handschrift, z. B. den Namen des Kindes. Für den Foto-Test am besten leere Blätter nehmen.")
        }
    }

    @MainActor
    private func startSelfTest(_ scope: SelfTestScope) {
        guard selfTestStatus == nil else { return }
        selfTestURL = nil
        selfTestStatus = SelfTestStatus(message: "Selbsttest startet …", progress: 0)
        Task { @MainActor in
            let url = await SelfTest.run(scope, app: app) { st in
                selfTestStatus = st
            }
            selfTestStatus = nil
            selfTestURL = url
            app.announce(url == nil ? "Der Selbsttest hat nicht geklappt." : "Der Selbsttest ist fertig.")
        }
    }

    @MainActor
    private var mappeSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundColor(SettingsStyle.teal)
                Text(settingsPageCount(app.store.pages.count))
            }
            Button(role: .destructive, action: {
                app.saveOpenPages(stopping: false)
                askDeleteAll = true
            }) {
                SwiftUI.Label("Alle Seiten löschen", systemImage: "trash")
            }
            .disabled(app.store.pages.isEmpty)
            .confirmationDialog("Alle Seiten der Mappe löschen?", isPresented: $askDeleteAll, titleVisibility: .visible) {
                Button("Alle Seiten löschen", role: .destructive) {
                    app.store.deleteAll()
                }
                Button("Abbrechen", role: .cancel) {
                }
            } message: {
                Text("Alle Seiten und Hefte kommen mit ihren Antworten in den Papierkorb. Dort lassen sie sich \(PageStore.trashDays) Tage lang zurückholen, danach werden sie endgültig gelöscht.")
            }
        } header: {
            Text("Mappe")
        } footer: {
            Text("Jede fotografierte Seite bleibt mit allen Antworten in der Mappe. Eine einzelne Seite löscht man in der Mappe: lange auf die Seite drücken, dann auf den roten Papierkorb. Gelöschtes kommt in den Papierkorb (unten).")
        }
    }

    // MARK: - Papierkorb

    @MainActor
    private var trashSection: some View {
        Section {
            if app.store.trash.isEmpty {
                Text("Der Papierkorb ist leer.")
                    .foregroundColor(.secondary)
            }
            ForEach(app.store.trash) { item in
                HStack(spacing: 12) {
                    if let thumb = app.store.trashThumbnail(item) {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: item.heft != nil ? "book.closed" : "doc")
                            .frame(width: 44, height: 56)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settingsTrashTitle(item))
                            .lineLimit(2)
                        Text(settingsTrashDate(item, daysLeft: app.store.daysLeft(item)))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(action: {
                        app.store.restore(item.id)
                        // a Heft still being read goes on reading
                        app.readMissingHeftPages()
                    }) {
                        SwiftUI.Label("Zurückholen", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive, action: {
                        purgeItem = item
                    }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Endgültig löschen")
                }
            }
            if !app.store.trash.isEmpty {
                Button(role: .destructive, action: {
                    askEmptyTrash = true
                }) {
                    SwiftUI.Label("Papierkorb leeren", systemImage: "trash.slash")
                }
            }
        } header: {
            Text("Papierkorb")
        } footer: {
            Text("Gelöschte Seiten und Hefte bleiben \(PageStore.trashDays) Tage hier und werden danach automatisch endgültig gelöscht. Zurückholen bringt sie mit allen Antworten in die Mappe. Nur hier in den Einstellungen sichtbar.")
        }
        .confirmationDialog("Endgültig löschen?", isPresented: Binding(get: { purgeItem != nil },
                                                                     set: { if !$0 { purgeItem = nil } }),
                            titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) {
                if let item = purgeItem { app.store.purge(item.id) }
                purgeItem = nil
            }
            Button("Abbrechen", role: .cancel) {
                purgeItem = nil
            }
        } message: {
            Text("„\(purgeItem.map { settingsTrashTitle($0) } ?? "")“ wird von diesem iPad gelöscht. Das lässt sich nicht rückgängig machen.")
        }
        .confirmationDialog("Papierkorb leeren?", isPresented: $askEmptyTrash, titleVisibility: .visible) {
            Button("Papierkorb leeren", role: .destructive) {
                app.store.emptyTrash()
            }
            Button("Abbrechen", role: .cancel) {
            }
        } message: {
            Text("Alles im Papierkorb wird von diesem iPad gelöscht. Das lässt sich nicht rückgängig machen.")
        }
    }

    // MARK: - Help

    @MainActor
    private var helpSection: some View {
        Section {
            SettingsStepRow(number: "1", symbol: "camera.fill", color: SettingsStyle.teal, title: "Foto",
                            text: "Das Kind fotografiert das Blatt. Vorher zeigt ein kurzer Hinweis, wie es geht (abschaltbar). Ist das Foto zu dunkel, verwackelt oder kaum lesbar, fragt das Hörblatt: „Nochmal“ (Kamera) oder „Weiter“ (Pfeil). Die Schrift wird auf dem iPad erkannt.")
            SettingsStepRow(number: "2", symbol: "hand.tap.fill", color: SettingsStyle.orange, title: "Wort und Satz",
                            text: "Wort antippen: Nur dieses Wort wird vorgelesen. Zweiter Knopf: der ganze Satz, auch über Zeilen hinweg. Wörter in gedruckten Kästen: der ganze Kasten. Lücken sind lila; im Satz steht für eine leere Lücke ein kurzer Ton, eine ausgefüllte wird mitgelesen. Leere Tabellenzellen nennen ihre Spaltenüberschrift.")
            SettingsStepRow(number: "3", symbol: "mic.fill", color: SettingsStyle.lila, title: "Sprechen",
                            text: "Eine Lücke oder eine beliebige Stelle antippen: Es öffnet sich ein Antwortfeld, das Hörblatt hört zu. Der lila Lautsprecher liest die Antwort vor, das Mikrofon nimmt sie neu auf, das Häkchen schließt das Feld.")
            SettingsStepRow(number: "4", symbol: "highlighter", color: SettingsStyle.amber, title: "Markieren",
                            text: "Farbe wählen (gelb, grün, blau, orange). Wort antippen oder waagerecht über Wörter wischen. Für einen Wortteil den Finger kurz auf dem Wort liegen lassen: Die Wort-Lupe zeigt das Wort groß in Buchstaben, Wischen über die Buchstaben markiert genau diese. Die Seite verschiebt man dabei mit zwei Fingern.")
            SettingsStepRow(number: nil, symbol: "pencil.tip", color: SettingsStyle.slate, title: "Stift",
                            text: "Freihand zum Verbinden, Ankreuzen, Einkreisen und Durchstreichen, in Blau, Rot oder Schwarz. Radiergummi: Antworten, Markierungen, Stiftstriche und falsch erkannte Lücken. Der Pfeil nimmt den letzten Schritt zurück.")
            SettingsStepRow(number: "5", symbol: "checkmark.square.fill", color: SettingsStyle.blue, title: "Fertig",
                            text: "Ein Bild des Blatts mit allen Antworten, Markierungen und Stiftstrichen. Das Kind zeigt es zuerst der Lehrkraft und tippt auf den Daumen. Danach geht es über „Teilen“ per AirDrop an die Lehrkraft.")
            SettingsStepRow(number: nil, symbol: "folder.fill", color: SettingsStyle.teal, title: "Mappe und zwei Seiten",
                            text: "Jede Seite bleibt in der Mappe (Ordner oben links). Oben in der Leiste stehen die letzten Seiten: ein Tipp wechselt die Seite. Im Querformat zeigt der Knopf mit den zwei Rechtecken zwei Seiten nebeneinander, z. B. links das Buch und rechts das Arbeitsblatt. Die zuletzt berührte Seite hat einen türkisen Rahmen; eine Seite aus der Mappe oder der Leiste öffnet sich dort. Löschen: eine Seite in der Mappe oder in der Leiste lange drücken, dann der rote Papierkorb.")
            SettingsStepRow(number: nil, symbol: "book.fill", color: SettingsStyle.teal, title: "Heft (PDF)",
                            text: "Eine PDF (z. B. ein Ermittlerheft) per AirDrop aufs iPad schicken oder in der Dateien-App ablegen. In der Mappe „PDF öffnen“ tippen und die Datei wählen. Die erste Seite wird sofort gelesen und geöffnet, die übrigen liest das Hörblatt im Hintergrund weiter (kleiner Kreisel unter der Seite, geht auch nach einem Neustart weiter). Blättert das Kind zu einer noch nicht gelesenen Seite, kommt sie sofort dran. Das Heft liegt danach als ein Eintrag in der Mappe und öffnet sich auf der zuletzt bearbeiteten Seite; unten blättern große Pfeile. Bei „Fertig“ kann das Kind diese Seite als Bild oder das ganze Heft als PDF teilen.")
        } header: {
            Text("So geht es")
        } footer: {
            Text("Diese Seite öffnet sich nur, wenn man das Zahnrad 1 Sekunde lang drückt.")
        }
    }

    @MainActor
    private var sharingSection: some View {
        Section {
            Text("Auf dem Lehrer-iPad: Einstellungen → Allgemein → AirDrop → „Für alle für 10 Minuten“ (oder im Kontrollzentrum lange auf die Verbindungen drücken → AirDrop).")
                .font(.callout)
            Text("Das Kind tippt auf 5 Fertig, dann auf „Teilen“, dann auf AirDrop und auf das Lehrer-iPad. Erscheint auf dem Lehrer-iPad ein Code, gibt das Kind ihn ein.")
                .font(.callout)
            Text("Ohne AirDrop: Die Lehrkraft schaut direkt auf das iPad. Die Antworten bleiben in der Mappe gespeichert.")
                .font(.callout)
        } header: {
            Text("Abgabe mit AirDrop")
        }
    }

    @MainActor
    private var privacySection: some View {
        Section {
            Text("Fotos, Antworten, Markierungen und Stiftstriche bleiben auf diesem iPad (ohne iCloud-Sicherung). Die Texterkennung läuft auf dem Gerät; es wird nichts hochgeladen.")
                .font(.callout)
            Text("Ausnahme: Gesprochene Antworten erkennt Apple wie beim Tastatur-Diktat. Kann das iPad die Sprache nicht selbst erkennen, geschieht das gegebenenfalls auf Servern von Apple.")
                .font(.callout)
        } header: {
            Text("Datenschutz")
        }
    }

    @MainActor
    private var voiceSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "person.wave.2.fill")
                    .foregroundColor(SettingsStyle.teal)
                Text(voiceInfo.isEmpty ? "Stimme wird gesucht …" : voiceInfo)
            }
            Text("Das Hörblatt nimmt die beste deutsche Stimme des iPads. Eine natürlicher klingende Stimme laden: iPad-Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen → Deutsch, dort z. B. eine Stimme mit „(Premium)“ oder „(Erweitert)“ laden. Danach das Hörblatt neu starten.")
                .font(.callout)
        } header: {
            Text("Stimme")
        }
    }
}

// MARK: - Helpers

/// One step of the picture card: number and symbol in the card's colour, then what it does.
fileprivate struct SettingsStepRow: View {
    let number: String?
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color)
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let n = number {
                    Text(n)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(color)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color.white))
                        .padding(2)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Colours of the picture card.
fileprivate enum SettingsStyle {
    static let teal = Color(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255)
    static let orange = Color(red: 234.0 / 255, green: 88.0 / 255, blue: 12.0 / 255)
    static let lila = Color(red: 124.0 / 255, green: 58.0 / 255, blue: 237.0 / 255)
    static let amber = Color(red: 217.0 / 255, green: 119.0 / 255, blue: 6.0 / 255)
    static let slate = Color(red: 71.0 / 255, green: 85.0 / 255, blue: 105.0 / 255)
    static let blue = Color(red: 37.0 / 255, green: 99.0 / 255, blue: 235.0 / 255)
}

/// 0.85 → "85 %".
fileprivate func settingsPercent(_ rate: Double) -> String {
    let p = Int((rate * 100).rounded())
    return "\(p) %"
}

fileprivate func settingsPageCount(_ n: Int) -> String {
    if n == 0 { return "Die Mappe ist leer" }
    if n == 1 { return "1 Seite in der Mappe" }
    return "\(n) Seiten in der Mappe"
}

/// The voice the speaker picks (same order: premium, enhanced, the system's German voice).
fileprivate func settingsVoiceDescription() -> String {
    let german = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
    var best: AVSpeechSynthesisVoice? = german.first(where: { $0.quality == .premium })
    if best == nil {
        best = german.first(where: { $0.quality == .enhanced })
    }
    if best == nil {
        best = AVSpeechSynthesisVoice(language: "de-DE")
    }
    guard let v = best else { return "Keine deutsche Stimme gefunden" }
    var kind = "einfache Qualität"
    if v.quality == .premium {
        kind = "Premium"
    } else if v.quality == .enhanced {
        kind = "Erweitert"
    }
    let count = german.count
    let installed = count == 1 ? "1 deutsche Stimme" : "\(count) deutsche Stimmen"
    return "Jetzt: \(v.name) (\(kind)) · \(installed) auf dem iPad"
}

// MARK: - Papierkorb texts

fileprivate func settingsTrashTitle(_ item: TrashItem) -> String {
    if let h = item.heft {
        let n = h.pageTotal
        return item.title + " (Heft, " + (n == 1 ? "1 Seite" : "\(n) Seiten") + ")"
    }
    return item.title
}

fileprivate func settingsTrashDate(_ item: TrashItem, daysLeft: Int) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "d. MMMM"
    let left: String
    switch daysLeft {
    case 0: left = "wird heute endgültig gelöscht"
    case 1: left = "noch 1 Tag"
    default: left = "noch \(daysLeft) Tage"
    }
    return "Gelöscht am " + f.string(from: item.deleted) + " · " + left
}
