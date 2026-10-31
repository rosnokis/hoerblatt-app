import Foundation
import SwiftUI
import UIKit
import Combine
import VisionKit
import PDFKit

// State and flows of the app: the tool in use, photo → page, the Mappe with one or two open pages
// (e.g. book left, worksheet right), speaking. The child cannot read: every question is also spoken.

/// Waiting screen while a photo is read.
struct BusyInfo: Equatable {
    var progress: Double
    var message: String
}

/// A Heft whose pages are being read in the background.
struct HeftProgress: Equatable {
    var heft: UUID
    var done: Int
    var total: Int
}

/// Sheets and the camera. SwiftUI shows one at a time and drops one that comes while another is still
/// going away, so they are opened one after another.
fileprivate enum AppStateSheet {
    case library, settings, photoHelp, picker, scanner, finish, pdfPicker
}

/// Where the last photo came from ("Nochmal" opens the same again).
fileprivate enum AppStateSource {
    case camera, picker
}

fileprivate enum AppStatePhotoResult {
    case opened(words: Int)
    case retake
}

fileprivate enum AppStateKeys {
    static let left = "hoerblatt.open.left"
    static let right = "hoerblatt.open.right"
    static let twoPages = "hoerblatt.twoPages"
    static let side = "hoerblatt.activeSide"
}

/// Seconds a sheet needs to go away before the next one can come.
fileprivate let appStateSheetGap: Double = 0.65

fileprivate let appStatePhotoHint =
    "Leg das Heft flach hin. Halte das iPad gerade darüber. Das ganze Blatt muss auf das Foto. Dann tippe auf die Kamera."

@MainActor final class AppState: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if settings == oldValue { return }
            settings.save()
            speaker.rate = settings.rate
            speaker.tone = settings.tone
        }
    }
    @Published private(set) var mode: Mode = .wort
    @Published var left: PageController? = nil {
        didSet { rememberOpen() }
    }
    @Published var right: PageController? = nil {
        didSet { rememberOpen() }
    }
    @Published var twoPages: Bool = false {
        didSet { rememberOpen() }
    }
    @Published var activeSide: Side = .left {
        didSet { rememberOpen() }
    }
    @Published var busy: BusyInfo? = nil
    @Published var showLibrary: Bool = false {
        didSet { sheetChanged(.library, from: oldValue, to: showLibrary) }
    }
    @Published var showSettings: Bool = false {
        didSet { sheetChanged(.settings, from: oldValue, to: showSettings) }
    }
    @Published var showPhotoHelp: Bool = false {
        didSet { sheetChanged(.photoHelp, from: oldValue, to: showPhotoHelp) }
    }
    @Published var showScanner: Bool = false {
        didSet { sheetChanged(.scanner, from: oldValue, to: showScanner) }
    }
    @Published var showPicker: Bool = false {
        didSet { sheetChanged(.picker, from: oldValue, to: showPicker) }
    }
    /// The Dateien app's picker for a PDF (a Heft).
    @Published var showPDFPicker: Bool = false {
        didSet { sheetChanged(.pdfPicker, from: oldValue, to: showPDFPicker) }
    }
    /// Set → the Fertig view.
    @Published var finishImage: UIImage? = nil {
        didSet { sheetChanged(.finish, from: oldValue != nil, to: finishImage != nil) }
    }
    /// Fertig on a page of a Heft: the Heft, and its PDF with all answers once it is made.
    @Published var finishHeft: Heft? = nil
    @Published var finishHeftPDF: URL? = nil
    /// Pages of a Heft being read in the background (small spinner under the page).
    @Published var heftProgress: HeftProgress? = nil
    @Published var photoProblem: PhotoProblem? = nil
    /// Question "Diese Seite löschen?".
    @Published var pendingDelete: PageInfo? = nil

    let store: PageStore
    let speaker: Speaker
    let listener: Listener

    private var bag = Set<AnyCancellable>()
    /// Set while this class itself opens or closes a sheet (no re-planning then).
    private var settingSheets = false
    private var lastSheetClosed = Date.distantPast
    /// Only the latest planned sheet is opened.
    private var presentToken = 0
    private var pendingFinish: UIImage? = nil
    /// The Mappe was open when the delete question came: it comes back afterwards.
    private var reopenLibrary = false
    private var photoQueue: [UIImage] = []
    private var processing = false
    private var photoSource: AppStateSource = .camera
    /// The open photo question ("Nochmal" → false, "Weiter" → true).
    private var problemAnswer: CheckedContinuation<Bool, Never>? = nil
    /// Grows when a reading ends, so late progress reports are dropped.
    private var progressRun = 0
    /// Open PDFs of Hefte with pages still to read.
    private var heftDocs: [UUID: PDFDocument] = [:]
    private var heftReading = false
    /// The child turned to a page not read yet: it is read next and opened.
    private var wantedPage: (heft: UUID, number: Int)? = nil
    /// Hefte and pages that cannot be read ("<heft>/<page>"): not tried again in this run.
    private var failedHefte = Set<UUID>()
    private var failedPages = Set<String>()
    private var busyPrefix = ""

    init() {
        _settings = Published(initialValue: AppSettings.load())
        store = PageStore()
        speaker = Speaker()
        listener = Listener()
        speaker.rate = settings.rate
        speaker.tone = settings.tone

        // the page(s) open when the app was last used
        let defaults = UserDefaults.standard
        let leftId = appStateUUID(defaults.string(forKey: AppStateKeys.left))
        let rightId = appStateUUID(defaults.string(forKey: AppStateKeys.right))
        let two = defaults.bool(forKey: AppStateKeys.twoPages)
        let side = Side(rawValue: defaults.string(forKey: AppStateKeys.side) ?? "") ?? Side.left
        twoPages = two
        if let id = leftId {
            left = makeController(id)
        }
        if let id = rightId, id != leftId {
            right = makeController(id)
        }
        if !two, left == nil, let r = right {
            left = r
            right = nil
        }
        activeSide = two ? side : Side.left

        // LibraryView and PageStrip watch the app only: the Mappe's and the listener's changes are passed on
        store.objectWillChange
            .sink { [weak self] _ in
                guard let me = self else { return }
                me.objectWillChange.send()
                // (the store is about to change: look after the change)
                Task { @MainActor in
                    me.dropMissingPages()
                }
            }
            .store(in: &bag)
        listener.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &bag)

        // pages of a Heft not read when the app was closed
        Task { @MainActor in
            self.startHeftReading()
        }
    }

    /// The page of the active half (one page: left).
    var active: PageController? {
        if !twoPages { return left }
        return activeSide == .left ? left : right
    }

    /// For the Fertig sheet (`$app.showFinish`).
    var showFinish: Bool {
        get { return finishImage != nil }
        set {
            if !newValue && finishImage != nil { finishImage = nil }
        }
    }

    // MARK: - Tools and speaking

    func setMode(_ m: Mode) {
        changeMode(m)
        announce(m.announcement)
    }

    func announce(_ text: String) {
        if settings.announce { say(text) }
    }

    func say(_ text: String, onEnd: (() -> Void)? = nil) {
        if listener.isListening { stopAllListening() }
        speaker.say(text, onEnd: onEnd)
    }

    func say(parts: [SpeechPart], onEnd: (() -> Void)? = nil) {
        if listener.isListening { stopAllListening() }
        speaker.say(parts: parts, onEnd: onEnd)
    }

    func undo() {
        guard let c = active else {
            announce("Nichts zum Zurücknehmen")
            return
        }
        c.undo()
    }

    // MARK: - Pages

    /// Opens a page of the Mappe in the active half; a Heft opens at the page last worked on.
    func open(_ id: UUID) {
        if let h = store.heft(id), !h.pages.isEmpty {
            open(h.pages[max(0, min(h.pages.count - 1, h.lastPage))])
            return
        }
        if showLibrary { showLibrary = false }
        store.noteOpened(id)
        let side = currentSide
        if let c = controller(on: side), c.id == id {
            announce(pageName(c))
            return
        }
        let other: Side = side == .left ? .right : .left
        if let o = controller(on: other), o.id == id {
            // already open in the other half (never twice: both would write the same page)
            if twoPages {
                activate(other)
            } else {
                // the hidden page comes to the front
                let previous = left
                if let p = previous { closeAnswer(p) }
                left = right
                right = previous
            }
            announce(pageName(o))
            return
        }
        guard let c = makeController(id) else {
            say("Diese Seite kann ich nicht öffnen.")
            return
        }
        speaker.stop()
        put(c, on: side)
        announce(pageName(c))
    }

    /// Spoken when a page opens: a page of a Heft by its place ("Seite 2 von 40"), any other page by its title.
    private func pageName(_ c: PageController) -> String {
        if let h = store.heft(containing: c.id), let n = h.number(of: c.id) {
            return "Seite \(n + 1) von \(h.pageTotal)"
        }
        return c.page.title
    }

    /// The arrows under a page of a Heft: the page before (-1) or after (+1) in the active half.
    func turnPage(_ delta: Int) {
        guard let c = active, let h = store.heft(containing: c.id), let cur = h.number(of: c.id) else { return }
        let target = cur + delta
        guard target >= 0 && target < h.pageTotal else {
            announce(delta < 0 ? "Das ist die erste Seite." : "Das ist die letzte Seite.")
            return
        }
        if let id = h.page(number: target) {
            open(id)
            return
        }
        if failedPages.contains(appStatePageKey(h.id, target)) {
            say("Diese Seite kann ich nicht lesen.")
            return
        }
        // not read yet: it comes next, then it opens
        wantedPage = (heft: h.id, number: target)
        busy = BusyInfo(progress: 0.5, message: "Seite \(target + 1) wird gelesen …")
        say("Einen Moment.")
        startHeftReading()
    }

    /// A page that is open in one of the halves.
    func openController(_ id: UUID) -> PageController? {
        return openControllers.first(where: { $0.id == id })
    }

    /// Called on every touch of a half (only matters with two pages).
    func activate(_ side: Side) {
        guard twoPages, side != activeSide else { return }
        if let old = active { closeAnswer(old) }
        activeSide = side
    }

    func setTwoPages(_ on: Bool) {
        if on == twoPages { return }
        if on {
            twoPages = true
            // the empty half takes the next page from the strip or the Mappe
            if left == nil {
                activeSide = .left
            } else if right == nil {
                activeSide = .right
            }
            announce("Zwei Seiten")
        } else {
            // the page in use stays; the other one waits hidden until two pages are shown again
            if (activeSide == .right && right != nil) || left == nil {
                let l = left
                left = right
                right = l
            }
            if let r = right { closeAnswer(r) }
            activeSide = .left
            twoPages = false
            announce("Eine Seite")
        }
    }

    /// The app goes to the background: write what is open now (not 0.6 s later).
    func saveOpenPages(stopping: Bool) {
        if stopping {
            stopAllListening()
            speaker.stop()
        }
        for c in openControllers { c.save() }
    }

    // MARK: - New photo

    /// Picture guide (if on) → camera.
    func newPhoto() {
        if processing || photoProblem != nil { return }
        stopAllListening()
        for c in openControllers { closeAnswer(c) }
        appStateHideKeyboard()
        if settings.photoHelp {
            presentSoon(.photoHelp)
        } else {
            startScanner()
        }
    }

    func startScanner() {
        stopAllListening()
        speaker.stop()
        // the Hörblatt's own camera (takes the photo by itself, no Keep/Save); Apple's document camera as a setting
        let camera = settings.appleCamera ? VNDocumentCameraViewController.isSupported : SimpleCamera.isAvailable
        if camera {
            photoSource = .camera
            presentSoon(.scanner)
        } else {
            // no document camera (e.g. simulator): a photo from the library
            photoSource = .picker
            presentSoon(.picker)
        }
    }

    func scanned(_ images: [UIImage]) {
        showScanner = false
        if images.isEmpty { return }
        photoSource = .camera
        enqueue(images)
    }

    func picked(_ image: UIImage?) {
        showPicker = false
        guard let image = image else { return }
        photoSource = .picker
        enqueue([image])
    }

    // MARK: - PDF → Heft

    func choosePDF() {
        if processing || photoProblem != nil { return }
        stopAllListening()
        for c in openControllers { closeAnswer(c) }
        appStateHideKeyboard()
        presentSoon(.pdfPicker)
    }

    /// From the Dateien picker: the file is copied (it may sit in a cloud folder) and read page by page.
    func pickedPDF(_ result: Result<URL, Error>) {
        showPDFPicker = false
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let pdf = data, !processing else {
            if data == nil { say("Diese Datei kann ich nicht öffnen.") }
            return
        }
        processing = true
        let name = url.deletingPathExtension().lastPathComponent
        Task { @MainActor in
            await self.readHeft(pdf, name: name)
            self.processing = false
        }
    }

    /// "Nochmal" (retake) or "Weiter" on the photo question.
    func resolvePhotoProblem(retake: Bool) {
        photoProblem = nil
        speaker.stop()
        if let c = problemAnswer {
            problemAnswer = nil
            c.resume(returning: !retake)
        } else if retake {
            reopenPhotoSource()
        }
    }

    // MARK: - Fertig, delete

    func finish() {
        guard let c = active else {
            say("Mach zuerst ein Foto von einem Blatt.")
            return
        }
        stopAllListening()
        closeAnswer(c)
        appStateHideKeyboard()
        c.save()
        // (FinishView speaks its own hint when it appears)
        pendingFinish = Exporter.render(c)
        finishHeftPDF = nil
        finishHeft = store.heft(containing: c.id)
        presentSoon(.finish)
        if let h = finishHeft {
            Task { @MainActor in
                let url = await Exporter.heftPDF(h, app: self)
                if self.finishHeft?.id == h.id { self.finishHeftPDF = url }
            }
        }
    }

    func askDelete(_ info: PageInfo) {
        // the question is shown on the main screen: the Mappe makes room and comes back afterwards
        if showLibrary {
            reopenLibrary = true
            showLibrary = false
        }
        pendingDelete = info
        let what = store.heft(info.id) != nil ? "Dieses Heft" : "Diese Seite"
        say(what + " löschen? Tippe auf den roten Papierkorb. Oder tippe auf den grünen Pfeil, dann bleibt sie.")
    }

    func confirmDelete(_ yes: Bool) {
        guard let info = pendingDelete else { return }
        pendingDelete = nil
        if yes {
            if let h = store.heft(info.id) {
                for p in h.pages { closePage(p) }
                heftDocs[h.id] = nil
                if wantedPage?.heft == h.id {
                    wantedPage = nil
                    busy = nil
                }
                store.deleteHeft(h.id)
            } else {
                closePage(info.id)
                store.delete(info.id)
            }
            announce("Gelöscht")
        } else {
            speaker.stop()
        }
        if reopenLibrary {
            reopenLibrary = false
            presentSoon(.library)
        }
    }

    // MARK: - Private: pages

    private var currentSide: Side {
        return twoPages ? activeSide : .left
    }

    private var openControllers: [PageController] {
        var list: [PageController] = []
        if let l = left { list.append(l) }
        if let r = right, r !== left { list.append(r) }
        return list
    }

    private func controller(on side: Side) -> PageController? {
        return side == .left ? left : right
    }

    private func makeController(_ id: UUID) -> PageController? {
        guard let page = store.loadPage(id), let image = store.loadImage(id) else { return nil }
        return PageController(page: page, image: image, app: self)
    }

    /// Puts a page into a half; the page there before is written and closed.
    private func put(_ c: PageController?, on side: Side) {
        if let old = controller(on: side), old !== c {
            closeAnswer(old)
            old.save()
        }
        if side == .left {
            left = c
        } else {
            right = c
        }
    }

    private func closePage(_ id: UUID) {
        if let l = left, l.id == id {
            closeAnswer(l)
            left = nil
        }
        if let r = right, r.id == id {
            closeAnswer(r)
            right = nil
        }
        if !twoPages, left == nil, let r = right {
            left = r
            right = nil
        }
    }

    /// Pages deleted from the Mappe (also "alle löschen" in the settings) are closed.
    private func dropMissingPages() {
        let ids = Set(store.pages.map { $0.id })
        if let l = left, !ids.contains(l.id) { closePage(l.id) }
        if let r = right, !ids.contains(r.id) { closePage(r.id) }
    }

    /// The answer bar of this page closes (an empty field goes away, its listening stops).
    private func closeAnswer(_ c: PageController) {
        if c.activeAnswer != nil { c.activeAnswer = nil }
        if c.keyboardAnswer != nil { c.keyboardAnswer = nil }
    }

    private func stopAllListening() {
        for c in openControllers { c.stopListening() }
        if listener.isListening { listener.stop() }
    }

    private func changeMode(_ m: Mode) {
        stopAllListening()
        if m != .sprechen {
            for c in openControllers { closeAnswer(c) }
            appStateHideKeyboard()
        }
        if m != .markieren {
            for c in openControllers where c.lensWord != nil { c.lensWord = nil }
        }
        if mode != m { mode = m }
    }

    private func rememberOpen() {
        let d = UserDefaults.standard
        if let l = left {
            d.set(l.id.uuidString, forKey: AppStateKeys.left)
        } else {
            d.removeObject(forKey: AppStateKeys.left)
        }
        if let r = right {
            d.set(r.id.uuidString, forKey: AppStateKeys.right)
        } else {
            d.removeObject(forKey: AppStateKeys.right)
        }
        d.set(twoPages, forKey: AppStateKeys.twoPages)
        d.set(activeSide.rawValue, forKey: AppStateKeys.side)
    }

    // MARK: - Private: reading photos

    private func enqueue(_ images: [UIImage]) {
        photoQueue.append(contentsOf: images)
        if processing { return }
        processing = true
        Task { @MainActor in
            await self.runPhotoQueue()
        }
    }

    /// Every scanned page becomes a page of its own; the last one stays open.
    private func runPhotoQueue() async {
        stopAllListening()
        var number = 0
        var opened = 0
        var lastWords = 0
        var retake = false
        while !photoQueue.isEmpty {
            let image = photoQueue.removeFirst()
            number += 1
            let total = number + photoQueue.count
            let result = await readPhoto(image, number: number, of: total)
            switch result {
            case .opened(let words):
                opened += 1
                lastWords = words
            case .retake:
                retake = true
            }
        }
        busy = nil
        processing = false
        if retake {
            reopenPhotoSource()
        } else if opened > 0 {
            changeMode(.wort)
            if lastWords > 0 {
                say("Fertig. Tippe auf ein Wort.")
            } else {
                say("Ich konnte keine Schrift finden. Mach das Foto noch einmal, gerade und hell.")
            }
        }
    }

    /// Check → read → check → into the Mappe and open in the active half.
    private func readPhoto(_ image: UIImage, number: Int, of total: Int) async -> AppStatePhotoResult {
        let prefix = total > 1 ? "Seite \(number) von \(total): " : ""
        busyPrefix = prefix
        busy = BusyInfo(progress: 0, message: prefix + "Das Foto wird geprüft …")
        if number == 1 { say("Einen Moment. Ich lese das Blatt.") }
        if let problem = await appStateCheckPhoto(image) {
            let goOn = await ask(problem)
            if !goOn { return .retake }
            busy = BusyInfo(progress: 0, message: prefix + "Das Foto wird vorbereitet …")
        }
        progressRun += 1
        let run = progressRun
        let analysis = await Recognizer.analyze(image, progress: appStateProgressRelay(self, run: run))
        progressRun += 1
        let words = analysis.page.words.count
        if words < 12 {
            let goOn = await ask(.fewWords)
            if !goOn { return .retake }
        }
        busy = BusyInfo(progress: 1, message: prefix + "Fertig")
        store.add(page: analysis.page, image: analysis.image)
        put(PageController(page: analysis.page, image: analysis.image, app: self), on: currentSide)
        return .opened(words: words)
    }

    /// The first page is read at once and opened; the others are read in the background while the child works.
    /// The PDF is kept so the reading goes on after the app was closed.
    private func readHeft(_ data: Data, name: String) async {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else {
            say("Diese Datei kann ich nicht öffnen.")
            return
        }
        if doc.isLocked {
            say("Diese PDF ist mit einem Kennwort geschützt. Ich kann sie nicht lesen.")
            return
        }
        stopAllListening()
        let title = appStateHeftTitle(name)
        let heftId = UUID()
        let total = doc.pageCount
        say("Einen Moment. Ich lese die erste Seite.")
        var first: (id: UUID, number: Int)? = nil
        for n in 0..<total {
            busyPrefix = ""
            busy = BusyInfo(progress: 0, message: "Seite \(n + 1) wird gelesen …")
            if let id = await readHeftPage(doc, number: n, heft: heftId, showProgress: true) {
                first = (id: id, number: n)
                break
            }
        }
        busy = nil
        guard let f = first else {
            say("In dieser Datei konnte ich keine Seite lesen.")
            return
        }
        store.saveHeftPDF(data, heftId)
        heftDocs[heftId] = doc
        store.addHeft(Heft(id: heftId, title: title, created: Date(), pages: [f.id], lastPage: 0,
                           numbers: [f.number], total: total))
        changeMode(.wort)
        open(f.id)
        say(total == 1 ? "Fertig. Tippe auf ein Wort."
            : "Fertig. Das Heft hat \(total) Seiten. Mit den Pfeilen blätterst du. Die anderen Seiten lese ich nebenbei.")
        startHeftReading()
    }

    /// One PDF page → a page of the Mappe (not yet in the Heft's list). nil: it cannot be drawn.
    private func readHeftPage(_ doc: PDFDocument, number n: Int, heft heftId: UUID, showProgress: Bool) async -> UUID? {
        guard let pdfPage = doc.page(at: n), let drawn = appStatePDFPicture(pdfPage) else { return nil }
        // read like a photo with Vision (Live Text): the PDF's own text places proved unreliable on the iPad
        // (characterBounds/string of PDFKit, see CLAUDE.md); PDFText stays for the diagnosis file
        let text: [Word]? = appStateUsePDFText ? PDFText.words(pdfPage, scale: drawn.scale) : nil
        var relay: (Double, String) -> Void = { _, _ in }
        if showProgress {
            progressRun += 1
            relay = appStateProgressRelay(self, run: progressRun)
        }
        var analysis = await Recognizer.analyze(drawn.picture, textWords: text, cleanPage: true, progress: relay)
        if showProgress { progressRun += 1 }
        analysis.page.heft = heftId
        analysis.page.heftPage = n
        analysis.page.title = "Seite \(n + 1)"
        store.add(page: analysis.page, image: analysis.image)
        return analysis.page.id
    }

    /// Reads the pages still missing in all Hefte, one after another (a page the child turned to comes first).
    private func startHeftReading() {
        if heftReading { return }
        heftReading = true
        Task { @MainActor in
            while let job = self.nextHeftJob() {
                await self.readHeftJob(job)
            }
            self.heftReading = false
            self.heftProgress = nil
        }
    }

    private func nextHeftJob() -> (heft: UUID, number: Int)? {
        if let w = wantedPage, let h = store.heft(w.heft), h.page(number: w.number) == nil,
           !failedPages.contains(appStatePageKey(w.heft, w.number)) {
            return w
        }
        for h in store.hefte where !failedHefte.contains(h.id) {
            if let n = h.unread.first(where: { !failedPages.contains(appStatePageKey(h.id, $0)) }) {
                return (heft: h.id, number: n)
            }
        }
        return nil
    }

    private func readHeftJob(_ job: (heft: UUID, number: Int)) async {
        guard let h = store.heft(job.heft) else { return }
        var doc = heftDocs[job.heft]
        if doc == nil {
            doc = PDFDocument(url: store.heftPDFURL(job.heft))
            heftDocs[job.heft] = doc
        }
        guard let pdf = doc else {
            // the PDF is gone: the Heft keeps the pages it has
            failedHefte.insert(job.heft)
            finishWanted(job, page: nil)
            return
        }
        heftProgress = HeftProgress(heft: job.heft, done: h.pages.count, total: h.pageTotal)
        let id = await readHeftPage(pdf, number: job.number, heft: job.heft, showProgress: false)
        if let pageId = id {
            if store.heft(job.heft) != nil {
                store.addHeftPage(job.heft, page: pageId, number: job.number)
            } else {
                // the Heft was deleted meanwhile (it is in the Papierkorb without this page; restored, it reads it again)
                store.delete(pageId, toTrash: false)
            }
        } else {
            failedPages.insert(appStatePageKey(job.heft, job.number))
        }
        if let now = store.heft(job.heft) {
            // (the PDF stays: the diagnosis file shows what PDFKit makes of a page)
            if now.unread.isEmpty { heftDocs[job.heft] = nil }
            heftProgress = HeftProgress(heft: job.heft, done: now.pages.count, total: now.pageTotal)
        }
        finishWanted(job, page: id)
    }

    /// Self test: pages of a Heft are still being read in the background.
    var heftReadingBusy: Bool { return heftReading }

    /// Self test: reads the pages still missing (no-op while that runs anyway).
    func readMissingHeftPages() {
        startHeftReading()
    }

    /// Self test: a page of a Heft drawn again from its PDF – the same pixels the reading used.
    func heftPagePicture(_ heftId: UUID, number n: Int) -> UIImage? {
        guard let doc = heftDocs[heftId] ?? PDFDocument(url: store.heftPDFURL(heftId)),
              let pdfPage = doc.page(at: n) else { return nil }
        return appStatePDFPicture(pdfPage)?.picture
    }

    /// The page the child is waiting for is there (or cannot be read).
    private func finishWanted(_ job: (heft: UUID, number: Int), page: UUID?) {
        guard let w = wantedPage, w.heft == job.heft, w.number == job.number else { return }
        wantedPage = nil
        busy = nil
        if let id = page, store.heft(job.heft) != nil {
            open(id)
        } else {
            say("Diese Seite kann ich nicht lesen.")
        }
    }

    /// Shows the photo question, speaks it and waits for "Nochmal" (false) or "Weiter" (true).
    private func ask(_ problem: PhotoProblem) async -> Bool {
        busy = nil
        if let old = problemAnswer {
            problemAnswer = nil
            old.resume(returning: true)
        }
        photoProblem = problem
        say(problem.title + " " + problem.message
            + " Tippe auf die Kamera für ein neues Foto. Oder tippe auf den Pfeil, dann geht es weiter.")
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            self.problemAnswer = c
        }
    }

    /// Called through `appStateProgressRelay` (the recogniser reports on any thread).
    fileprivate func showProgress(_ value: Double, _ message: String, run: Int) {
        guard run == progressRun, let b = busy else { return }
        let p = max(b.progress, min(1, max(0, value)))
        busy = BusyInfo(progress: p, message: busyPrefix + message)
    }

    private func reopenPhotoSource() {
        switch photoSource {
        case .camera:
            startScanner()
        case .picker:
            presentSoon(.picker)
        }
    }

    // MARK: - Private: sheets one after another

    private func sheetChanged(_ kind: AppStateSheet, from old: Bool, to new: Bool) {
        if settingSheets || old == new { return }
        if !new {
            lastSheetClosed = Date()
            return
        }
        // opened from elsewhere while another sheet is up or still going away: a moment later
        let recent = Date().timeIntervalSince(lastSheetClosed) < appStateSheetGap
        if sheetUp(except: kind) || recent {
            if kind == .finish { pendingFinish = finishImage }
            settingSheets = true
            setSheet(kind, false)
            settingSheets = false
            presentSoon(kind)
        }
    }

    private func presentSoon(_ kind: AppStateSheet) {
        presentToken += 1
        let token = presentToken
        var wait = appStateSheetGap - Date().timeIntervalSince(lastSheetClosed)
        if sheetUp(except: kind) {
            closeSheets(except: kind)
            wait = appStateSheetGap
        }
        if wait <= 0.01 {
            showSheet(kind)
            return
        }
        let nanos = UInt64(wait * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            if self.presentToken == token {
                self.showSheet(kind)
            }
        }
    }

    private func showSheet(_ kind: AppStateSheet) {
        // something else came first: leave it
        if sheetUp(except: kind) {
            if kind == .finish { pendingFinish = nil }
            return
        }
        if kind == .finish && pendingFinish == nil { return }
        settingSheets = true
        setSheet(kind, true)
        settingSheets = false
        if kind == .photoHelp { say(appStatePhotoHint) }
    }

    private func setSheet(_ kind: AppStateSheet, _ on: Bool) {
        switch kind {
        case .library:
            showLibrary = on
        case .settings:
            showSettings = on
        case .photoHelp:
            showPhotoHelp = on
        case .picker:
            showPicker = on
        case .scanner:
            showScanner = on
        case .pdfPicker:
            showPDFPicker = on
        case .finish:
            if on {
                finishImage = pendingFinish
                pendingFinish = nil
            } else {
                finishImage = nil
            }
        }
    }

    private func sheetUp(except kind: AppStateSheet) -> Bool {
        if kind != .library && showLibrary { return true }
        if kind != .settings && showSettings { return true }
        if kind != .photoHelp && showPhotoHelp { return true }
        if kind != .picker && showPicker { return true }
        if kind != .scanner && showScanner { return true }
        if kind != .pdfPicker && showPDFPicker { return true }
        if kind != .finish && finishImage != nil { return true }
        return false
    }

    private func closeSheets(except kind: AppStateSheet) {
        if kind != .library && showLibrary { showLibrary = false }
        if kind != .settings && showSettings { showSettings = false }
        if kind != .photoHelp && showPhotoHelp { showPhotoHelp = false }
        if kind != .picker && showPicker { showPicker = false }
        if kind != .scanner && showScanner { showScanner = false }
        if kind != .pdfPicker && showPDFPicker { showPDFPicker = false }
        if kind != .finish && finishImage != nil { finishImage = nil }
    }
}

// MARK: - Helpers (no actor state)

fileprivate func appStateUUID(_ s: String?) -> UUID? {
    guard let s = s else { return nil }
    return UUID(uuidString: s)
}

/// Runs off the main actor (a nonisolated async function), so the waiting screen keeps moving.
fileprivate func appStateCheckPhoto(_ image: UIImage) async -> PhotoProblem? {
    return PhotoCheck.check(image)
}

/// The recogniser calls this on any thread; the value is handed to the main actor.
fileprivate func appStateProgressRelay(_ app: AppState, run: Int) -> (Double, String) -> Void {
    return { value, message in
        Task { @MainActor in
            app.showProgress(value, message, run: run)
        }
    }
}

@MainActor fileprivate func appStateHideKeyboard() {
    _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// "Ermittlerheft_Klasse4" → "Ermittlerheft Klasse4" (the file name, as the teacher chose it).
fileprivate func appStateHeftTitle(_ fileName: String) -> String {
    let spaced = fileName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    let t = spaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return t.isEmpty ? "Heft" : t
}

/// A PDF page drawn as a picture (turned as the PDF shows it), long side 2400 pixels, scale 1, on white.
/// `scale`: pixels per PDF point (for the PDF's own words).
@MainActor fileprivate func appStatePDFPicture(_ page: PDFPage) -> (picture: UIImage, scale: CGFloat)? {
    let box = page.bounds(for: .mediaBox)
    var w = box.width
    var h = box.height
    let turn = ((page.rotation % 360) + 360) % 360
    if turn == 90 || turn == 270 { swap(&w, &h) }
    guard w > 1, h > 1 else { return nil }
    let k = 2400 / max(w, h)
    let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    let thumb = page.thumbnail(of: size, for: .mediaBox)
    if thumb.size.width < 1 || thumb.size.height < 1 { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let picture = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        UIColor.white.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        thumb.draw(in: CGRect(origin: .zero, size: size))
    }
    return (picture: picture, scale: k)
}

fileprivate func appStatePageKey(_ heft: UUID, _ number: Int) -> String {
    return heft.uuidString + "/" + String(number)
}

/// Words of a PDF page from the PDF's own text (true) or read by Vision from the drawn page (false).
fileprivate let appStateUsePDFText = false
