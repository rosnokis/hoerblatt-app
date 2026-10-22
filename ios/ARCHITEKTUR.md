# Hörblatt – native iPad-App (Swift Playgrounds)

Verbindlicher Bauplan. Alle Dateien liegen flach in `ios/Hoerblatt.swiftpm/` (ein Modul `AppModule`, kein `public` nötig).
**Es gibt keinen Compiler in der Entwicklungsumgebung.** Der Code wird erst auf dem iPad in Swift Playgrounds übersetzt.
Deshalb gilt: nur gut bekannte, stabile APIs (iOS 17), keine Experimente, keine neuen iOS-26-APIs, keine Makros
(`#Preview`, `@Observable`), keine Drittbibliotheken. Lieber schlicht und eindeutig als elegant.

## Rahmen
- `Package.swift`: swift-tools-version 5.9 → Swift-5-Sprachmodus. `platforms: [.iOS("17.0")]`. Fähigkeiten: Kamera,
  Fotos, Mikrofon, Spracherkennung.
- Gemeinsame Typen stehen in `Model.swift` (fertig, nicht ändern ohne Absprache): `Word`, `Gap`, `GapKind`, `PrintedBox`,
  `Answer`, `Mark`, `MarkColor`, `PenColor`, `Page`, `PageInfo`, `SpeechPart`, `ToneKind`, `Mode`, `Side`,
  `AppSettings`, `PixelImage`.
- **Koordinaten:** alles in Pixeln des gespeicherten Seitenbilds (aufrecht, `UIImage.scale == 1`,
  `imageOrientation == .up`), Ursprung oben links. Die Seitenansicht skaliert nur.
- Namen, die mit SwiftUI/UIKit kollidieren, sind verboten: also **nicht** `Layout`, `Image`, `Text`, `Color`, `Label`,
  `Tool`, `Group`, `Section` als eigene Typnamen. Die Layout-Analyse heißt `LayoutAnalysis`.
- Klassen mit UI-Zustand sind `@MainActor final class … : ObservableObject` mit `@Published`.
  Kein `@Observable`. Rechenarbeit (Vision, Layout) läuft in `Task.detached` und kommt mit `await MainActor.run` zurück.
- Sprache in der Oberfläche: Deutsch, kindgerecht, das Kind kann nicht lesen → jede Rückfrage wird zusätzlich
  vorgesprochen und hat eindeutige Symbole (SF Symbols) statt Text-Knöpfen.
- **Name des Kindes nie im Code**; Platzhalter in Texten: „das Kind“.

## Dateien, Besitzer, Schnittstellen (genau so verwenden!)

### Model.swift (fertig)
Siehe Datei. `Page.drawing` ist `PKDrawing.dataRepresentation()` in Seitenpixeln (leer = `Data()`).

### Store.swift — Mappe auf dem Gerät
```swift
@MainActor final class PageStore: ObservableObject {
    @Published private(set) var pages: [PageInfo]          // neueste zuerst
    init()                                                  // lädt Documents/Mappe/index.json
    func add(page: Page, image: UIImage)                    // schreibt image.jpg, thumb.jpg, page.json; vorne einfügen
    func save(_ page: Page)                                 // schreibt page.json, aktualisiert Titel in pages
    func loadPage(_ id: UUID) -> Page?
    func loadImage(_ id: UUID) -> UIImage?                  // Scale 1
    func thumbnail(_ id: UUID) -> UIImage?                  // ~300 px, zwischengespeichert
    func delete(_ id: UUID)
    func deleteAll()
}
```
Ordner: `Documents/Mappe/<uuid>/{page.json,image.jpg,thumb.jpg}`, Liste `Documents/Mappe/index.json`.
JSON mit `JSONEncoder`/`JSONDecoder` (Daten-Strategie Standard). Fehler werden still ignoriert (kein Absturz).

### Speech.swift — Vorlesen, Ton, Zuhören
```swift
@MainActor final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking: Bool
    var rate: Double              // AppSettings.rate; AVSpeechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
    var tone: ToneKind            // erzeugt WAV im Speicher neu (wie TONES in index.html), AVAudioPlayer
    override init()
    func say(_ text: String, onEnd: (() -> Void)? = nil)
    func say(parts: [SpeechPart], onEnd: (() -> Void)? = nil)   // nacheinander; .tone spielt den Lückenton
    func playTone()                                              // nur der Ton (Vorhören in den Einstellungen)
    func stop()                                                  // bricht alles ab, onEnd wird NICHT gerufen
}
@MainActor final class Listener: NSObject, ObservableObject {
    @Published private(set) var isListening: Bool
    @Published private(set) var blocked: Bool     // keine Erlaubnis / nicht verfügbar → Tastatur-Rückfall
    override init()
    func start(onText: @escaping (String) -> Void, onEnd: @escaping () -> Void)
    func stop()
}
```
- Stimme: deutsche Stimme, bevorzugt `.premium`/`.enhanced`, sonst `AVSpeechSynthesisVoice(language: "de-DE")`.
- Audio-Session: zum Vorlesen `.playback` mit Modus `.spokenAudio` (klingt auch bei Stummschaltung).
  Zum Zuhören `.playAndRecord` mit `[.defaultToSpeaker, .allowBluetooth]`, danach wieder `.playback`.
- `Listener.start`: fragt beim ersten Mal `SFSpeechRecognizer.requestAuthorization` und die Mikrofon-Erlaubnis
  (`AVAudioSession.sharedInstance().requestRecordPermission`), `SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))`,
  `SFSpeechAudioBufferRecognitionRequest` mit `shouldReportPartialResults = true`; `requiresOnDeviceRecognition = true`,
  wenn `supportsOnDeviceRecognition`. `onText` bekommt jeweils den ganzen bisher erkannten Text. Stoppt nach ~2 s Stille
  oder 30 s, dann `onEnd`. Bei Verweigerung/Fehler: `blocked = true`, `onEnd()`.
- Ruft man `Speaker.say`, während der Listener läuft, stoppt AppState vorher den Listener.
- `Listener.stop()` ruft `onEnd` nicht. `blocked` gilt nur für den letzten Versuch: PageController versucht das
  Mikrofon bei jedem Antippen neu (wenn `settings.mic`), erst ein erneuter Fehler öffnet die Tastatur.

### LayoutAnalysis.swift — Linien, Kästen, Lücken (Port von `analyzeLayout` aus `index.html`)
```swift
struct LayoutResult {
    var gaps: [Gap]
    var boxes: [PrintedBox]          // ids = Index
    var wordBox: [Int: Int]          // Wort-id → Kasten-Index
    var dropped: Set<Int>            // Wort-ids, die weg sollen (Buchstabensalat in Schreibfeldern, Doppelte …)
    var textHeight: CGFloat          // typische Texthöhe in Pixeln
    var words: [Word] = []           // Eingabewörter nach der Bereinigung (gleiche ids/Reihenfolge, auch die verworfenen),
                                     // Rechtecke korrigiert, „.“ angehängt wo ein einzelner Punkt den Satz beendete
}
enum LayoutAnalysis {
    static func analyze(_ image: PixelImage, words: [Word]) -> LayoutResult   // reines Swift, kein UIKit, darf langsam sein
}
```
Treu zum getesteten JavaScript (Grate → Linien, Rahmen, Lineatur, graue Quadrate, Tabellen mit Überschriften,
Punkt nach Lücke = `endsSentence`, Unterstreichungen/Rahmen/Zeichnungen sind keine Lücken).

### Recognizer.swift — Foto → Seite
```swift
struct Analysis { var image: UIImage; var page: Page }   // page: neue id, leere answers/marks, drawing = Data()
enum Recognizer {
    static func analyze(_ input: UIImage, progress: @escaping (Double, String) -> Void) async -> Analysis
}
```
- Bild aufrecht neu zeichnen (`.up`, Scale 1), lange Seite höchstens 2400 px.
- Quer fotografiert: Probe mit `.fast`-Erkennung bei 0°; wenige echte Wörter → auch 90°/270°, bestes nehmen.
- `VNRecognizeTextRequest`, `.accurate`, `["de-DE"]`, `usesLanguageCorrection = true`; Wortrechtecke je Wort über
  `VNRecognizedText.boundingBox(for:)` (normiert, Ursprung unten links → in Pixel oben links umrechnen).
- Wörter ohne Buchstaben/Ziffern weglassen; dann `LayoutAnalysis.analyze`, `dropped` entfernen, `box` setzen,
  ids neu durchzählen (id == Index) und `wordBox`/Kasten-Bezüge mit umrechnen.
- Titel: die ersten 1–4 Wörter der obersten größeren Zeile (max. 40 Zeichen), sonst „Seite“.
- `progress` wird auf beliebigem Thread gerufen; der Empfänger springt selbst auf den MainActor.

### Capture.swift — Kamera, Foto-Hinweis, Foto-Prüfung
```swift
struct DocumentScanner: UIViewControllerRepresentable { var onFinish: ([UIImage]) -> Void }   // [] bei Abbruch
struct PhotoPicker: UIViewControllerRepresentable { var onFinish: (UIImage?) -> Void }          // PHPickerViewController, 1 Bild
struct PhotoHelpView: View { var onGo: () -> Void; var onCancel: () -> Void }
enum PhotoProblem: String, Identifiable { case dark, blurry, fewWords
    var id: String; var title: String; var message: String; var symbol: String }
enum PhotoCheck { static func check(_ image: UIImage) -> PhotoProblem? }    // .dark / .blurry
struct PhotoProblemView: View { var problem: PhotoProblem; var onAgain: () -> Void; var onGoOn: () -> Void }
```
- `DocumentScanner`: `VNDocumentCameraViewController` (VisionKit) – erkennt die Seite, entzerrt, löst selbst aus.
  Jede gescannte Seite wird eine eigene Mappe-Seite.
- Prüfung: Papierhelligkeit (Mittel der helleren Hälfte der Pixel eines ~256-px-Graubilds) < 110 → `.dark`;
  Streuung des Laplace-Filters < 80 → `.blurry`. `.fewWords` (< 12 Wörter) setzt AppState nach der Erkennung.
- Texte (werden auch gesprochen): dunkel „Das Foto ist zu dunkel. Mach mehr Licht an oder geh näher ans Fenster.“,
  verwackelt „Das Foto ist verwackelt. Halte das iPad ganz ruhig.“, wenige Wörter „Ich kann kaum etwas lesen. Das Blatt
  muss groß, hell und gerade auf dem Foto sein.“ Hinweis vorher: „Leg das Heft flach hin. Halte das iPad gerade darüber.
  Das ganze Blatt muss auf das Foto.“ (mit drei Bild-Kacheln: Heft flach, iPad darüber, ganzes Blatt).

### Reading.swift — Lesereihenfolge, Sätze, Treffer (Port von `seq`, `sentenceAt`, `hitWord`, `hitGap`, `answerOn`, `answerAt`)
```swift
struct Sentence { var parts: [SpeechPart]; var rects: [CGRect] }     // rects: je Zeile ein Rechteck zum Aufleuchten
struct Reading {
    init(page: Page)
    func wordAt(_ p: CGPoint, loose: Bool) -> Int?        // Wort-id
    func gapAt(_ p: CGPoint) -> Int?                       // Index in page.gaps
    func answerAt(_ p: CGPoint) -> Int?                    // Index in page.answers (Treffer auf ein Antwortfeld)
    func markAt(_ p: CGPoint) -> Int?                      // Index in page.marks (oberste)
    func sentence(atWord id: Int) -> Sentence
    func sentence(atGap index: Int) -> Sentence
    func boxWords(_ box: Int) -> [Word]                    // in Lesereihenfolge
    func answerText(onGap index: Int) -> String            // "" wenn leer
    func newAnswerRect(forGap index: Int) -> CGRect
    func newAnswerRect(at p: CGPoint) -> CGRect            // freies Antwortfeld an beliebiger Stelle
    func markRect(_ mark: Mark) -> CGRect?
    static func cleanWord(_ t: String) -> String           // Satzzeichen am Rand weg
}
```
Regeln exakt wie im JavaScript (Satzende . ! ? : auch vor schließenden Anführungszeichen, nicht „1.“; Doppelpunkt
direkt vor Lücke auf derselben Zeile ist kein Ende; Kasten-Grenze; Überschrift (Höhe ×1,4); nummerierte nächste Aufgabe;
großer Zeilenabstand außer Fortsetzung unter dem Zeilenanfang; kurze Zeile + Großbuchstabe; Lücke allein in der Zeile;
Kästchen mitten im Wort: Antwort und Wortrest werden zusammengelesen; leere Lücke = `.tone`, ausgefüllte = Antworttext).

### PageController.swift — eine geöffnete Seite
```swift
@MainActor final class PageController: ObservableObject, Identifiable {
    @Published var page: Page
    let image: UIImage
    @Published var flash: [CGRect]            // leuchtet orange, solange vorgelesen wird
    @Published var activeAnswer: UUID?         // Antwortfeld mit Bedienleiste (Mikrofon, Vorlesen, Fertig)
    @Published var keyboardAnswer: UUID?       // dieses Feld soll die Tastatur öffnen (Mikrofon blockiert)
    let id: UUID                               // = page.id
    var reading: Reading { get }               // zwischengespeichert, neu wenn words/gaps/answers sich ändern
    init(page: Page, image: UIImage, app: AppState)
    func tapWord(at p: CGPoint)                // Modus .wort
    func tapSentence(at p: CGPoint)            // Modus .satz
    func tapSpeak(at p: CGPoint)               // Modus .sprechen: Lücke → Feld darauf, sonst freies Feld; dann zuhören
    func tapAnswer(_ id: UUID)                 // Tipp auf ein vorhandenes Antwortfeld (je nach Modus)
    func markTap(at p: CGPoint)
    func markStroke(_ points: [CGPoint], slow: Bool)
    func eraseTap(at p: CGPoint)               // Antwort → Markierung → Lücke (Stiftstriche löscht der Radierer im Canvas)
    func listen(_ id: UUID)
    func stopListening()
    func speakAnswer(_ id: UUID)
    func setAnswerText(_ id: UUID, _ text: String)
    func removeAnswer(_ id: UUID)
    func drawingChanged(_ data: Data)          // nach jedem Stiftstrich; legt Zurück-Schritt an
    func undo()
    func save()                                // über app.store
}
```
Verhalten wie `index.html` (Klick-Handler „tapping the page“, Markier-Gesten, `undo`), mit `app.settings`.
Zurück-Schritte: bis 60 Schnappschüsse von answers/marks/gaps/drawing.

### PageCanvas.swift — die Seite auf dem Bildschirm (UIKit)
```swift
struct PageCanvas: UIViewRepresentable {
    @ObservedObject var controller: PageController
    @ObservedObject var app: AppState
    var isActive: Bool
    var onActivate: () -> Void
}
```
- `UIScrollView` (Zoom mit zwei Fingern; `viewForZooming` = Inhaltsansicht in Seitenpixel-Größe; Mindestzoom =
  ganze Seite sichtbar; Start: Seitenbreite füllt die Ansicht).
- Inhalt: `UIImageView`, Overlay-`UIView` (zeichnet mit CoreGraphics: Wortumrandungen, Lücken lila, Markierungen,
  Aufleuchten), `PKCanvasView` (gleich groß, `drawingPolicy = .anyInput`, durchsichtig), Antwortfelder als
  `UITextView` an `answer.rect` (Schrift = `page.textHeight * 1.1`, blau, wachsen nach unten).
- Gesten je Modus: Tipp → Controller; Markieren: ein Finger wischt (Pan) → `markStroke`, Scrollen dann mit zwei Fingern
  (`panGestureRecognizer.minimumNumberOfTouches = 2` in Markieren und Stift); Stift: PKCanvas aktiv mit Tinte
  `PenColor.ink`, Breite `max(3, textHeight * 0.14)`; Radieren: PKCanvas mit `PKEraserTool(.vector)` + Tipp → `eraseTap`;
  sonst PKCanvas ohne Bedienung.
- Jede Berührung macht die Seite aktiv (`onActivate`). Aktive Seite bei zwei Seiten: türkiser Rahmen.

### AppState.swift — Zustand und Abläufe
```swift
struct BusyInfo: Equatable { var progress: Double; var message: String }
@MainActor final class AppState: ObservableObject {
    @Published var settings: AppSettings            // didSet: speichern, speaker.rate/tone setzen
    @Published private(set) var mode: Mode
    @Published var left: PageController?
    @Published var right: PageController?
    @Published var twoPages: Bool
    @Published var activeSide: Side
    @Published var busy: BusyInfo?
    @Published var showLibrary: Bool
    @Published var showSettings: Bool
    @Published var showPhotoHelp: Bool
    @Published var showScanner: Bool
    @Published var showPicker: Bool
    @Published var finishImage: UIImage?            // gesetzt → Fertig-Ansicht
    @Published var photoProblem: PhotoProblem?
    @Published var pendingDelete: PageInfo?         // Rückfrage „Wirklich löschen?“
    let store: PageStore
    let speaker: Speaker
    let listener: Listener
    var active: PageController? { get }             // Seite der aktiven Hälfte (bei einer Seite: left)
    init()
    func setMode(_ m: Mode)                          // spricht die Ansage, stoppt Zuhören
    func announce(_ text: String)                   // nur wenn settings.announce
    func say(_ text: String, onEnd: (() -> Void)? = nil)       // stoppt Zuhören, dann speaker
    func say(parts: [SpeechPart], onEnd: (() -> Void)? = nil)
    func open(_ id: UUID)                            // in die aktive Hälfte
    func activate(_ side: Side)
    func setTwoPages(_ on: Bool)
    func newPhoto()                                  // Foto-Hinweis (falls an) → Kamera
    func startScanner()
    func scanned(_ images: [UIImage])
    func picked(_ image: UIImage?)
    func resolvePhotoProblem(retake: Bool)
    func finish()                                    // Exporter.render(aktive Seite) → finishImage
    func askDelete(_ info: PageInfo)
    func confirmDelete(_ yes: Bool)
    func undo()
}
```
Ablauf neues Foto: Hinweis → Scanner (bzw. Foto-Auswahl) → je Bild: `PhotoCheck` → bei Problem Rückfrage (Nochmal =
Kamera neu, Weiter = trotzdem) → `Recognizer.analyze` mit Fortschritt (`busy`) → < 12 Wörter → Rückfrage →
`store.add` → in der aktiven Hälfte öffnen → „Fertig. Tippe auf ein Wort.“ und Modus `.wort`.
Start der App: zuletzt geöffnete Seite(n) wieder öffnen (UserDefaults), sonst leerer Zustand mit großem Kamera-Knopf.

### ContentView.swift — Hauptbildschirm, HoerblattApp.swift
- Kopfzeile: Mappe-Knopf (`folder.fill`), Seitenleiste mit Vorschaubildern der letzten Seiten (ein Tipp öffnet,
  `PageStrip` aus Library.swift), Zwei-Seiten-Schalter (`rectangle.split.2x1`, nur im Querformat), Hilfe/Einstellungen
  (`gearshape`, öffnet erst nach 2 s langem Drücken – Lehrkräfte).
- Mitte: eine `PageCanvas`, oder zwei nebeneinander (Querformat + `twoPages`). Ohne Seite: großer Kamera-Knopf.
- Unten `ToolTray`: 1 Foto (teal, `camera.fill`), 2 Wort (orange, `hand.tap.fill`) + Satz (orange, `text.alignleft`),
  3 Sprechen (lila, `mic.fill`), 4 Markieren (amber, `highlighter`) mit 4 Farbpunkten wenn aktiv, Stift (slate,
  `pencil.tip`, ohne Nummer) mit 3 Farbpunkten wenn aktiv, Radierer (`eraser.fill`), Zurück (`arrow.uturn.backward`),
  5 Fertig (blau, `checkmark.square.fill`). Große Knöpfe (≥ 64 pt), Nummer klein oben links wie auf der Bildkarte.
- Antwort-Leiste: wenn `activeAnswer` gesetzt, über der Werkzeugleiste: Mikrofon (nochmal sprechen, pulsiert beim Zuhören),
  Lautsprecher (Antwort vorlesen, lila), Häkchen (fertig). Große Knöpfe in Bildschirmgröße, nicht im Zoom.
- Overlays: Fortschritt (`busy`), Foto-Problem, Lösch-Rückfrage, Sheets für Mappe, Einstellungen, Foto-Hinweis,
  Fertig-Ansicht; `fullScreenCover` für Scanner.
- Farben: teal #0F766E, orange #EA580C, lila #7C3AED, amber #D97706, slate #475569, blau #2563EB, Hintergrund #EEF1EC.

### Library.swift — Mappe
```swift
struct LibraryView: View { @ObservedObject var app: AppState }      // Sheet: Raster aller Seiten
struct PageStrip: View { @ObservedObject var app: AppState }        // waagerechte Leiste in der Kopfzeile
```
- Raster mit Vorschaubild + Titel + Datum; Tipp öffnet (in der aktiven Hälfte) und schließt das Sheet.
  Langes Drücken → `app.askDelete` (Rückfrage mit Bild der Seite, großem roten Papierkorb und grünem Zurück-Pfeil,
  Frage wird gesprochen: „Diese Seite löschen?“). Erste Kachel: „Neue Seite“ (Kamera) und „Foto wählen“ (Fotos).
- Seiten, die gerade offen sind, haben einen farbigen Rand (links/rechts).

### SettingsView.swift — Hilfe und Einstellungen (Lehrkräfte)
`struct SettingsView: View { @ObservedObject var app: AppState }` – Form: Sprechtempo (0,5–1,3), Ansagen,
Wort-Umrandungen, Kästen zusammen vorlesen, Lücken markieren, Mikrofon-Knopf, Lückenton (4, mit Vorhören),
Foto-Hinweis; Mappe: alle Seiten löschen (mit Rückfrage); Hilfe-Text (Ablauf, AirDrop-Abgabe, Datenschutz:
alles bleibt auf dem Gerät, gesprochene Antworten erkennt Apple ggf. auf Servern wie beim Diktat); Stimmen-Hinweis.

### Export.swift — Fertig
```swift
enum Exporter { @MainActor static func render(_ c: PageController) -> UIImage }   // Bild + Markierungen + Antworten + Stift
struct FinishView: View { @ObservedObject var app: AppState; let image: UIImage }
```
Fertig-Ansicht: großes Bild, großer blauer Teilen-Knopf (`ShareLink(item: Image(uiImage:), preview: …)`) → AirDrop,
Zurück-Knopf; gesprochen: „Fertig. Tippe auf Teilen und dann auf AirDrop.“

## Prüfregeln für alle Dateien
- Jede verwendete Funktion/Eigenschaft eines anderen Moduls steht genau so in diesem Bauplan.
- Keine doppelten Typnamen über Dateien hinweg; Hilfstypen `private`/`fileprivate` oder mit Dateipräfix.
- Jede `switch` über eigene Enums vollständig. Keine erzwungenen Entpackungen (`!`) außer bei garantiert vorhandenen
  Ressourcen. Kein `fatalError`.
- UI-Änderungen nur auf dem MainActor.
