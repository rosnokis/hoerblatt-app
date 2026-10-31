import Foundation
import UIKit
import Combine
import PencilKit

// One open page: what the child taps, says, marks and draws on it, with undo. Port of the tap handler
// ("tapping the page"), the marker gestures and undo from index.html. Positions are page pixels.

/// Answers, marks, gaps and pen strokes for one undo step.
fileprivate struct PageControllerSnapshot: Equatable {
    var answers: [Answer]
    var marks: [Mark]
    var gaps: [Gap]
    var drawing: Data
}

/// Which page started the one shared listener (two pages can be open side by side).
@MainActor fileprivate enum PageControllerMic {
    static var owner: ObjectIdentifier? = nil
}

@MainActor final class PageController: ObservableObject, Identifiable {
    @Published var page: Page {
        didSet { pageDidChange(from: oldValue) }
    }
    let image: UIImage
    /// Lights up in orange while something is read.
    @Published var flash: [CGRect] = []
    /// Answer field with its bar (microphone, speaker, done). An empty field is dropped when left.
    @Published var activeAnswer: UUID? = nil {
        didSet {
            if let old = oldValue, old != activeAnswer { answerLeft(old) }
        }
    }
    /// This field should open the keyboard (the app cannot listen itself).
    @Published var keyboardAnswer: UUID? = nil
    /// Word shown big in the word lens (Markieren: finger held on a word), to mark single letters.
    @Published var lensWord: Int? = nil
    /// The page's id (it never changes for one controller).
    let id: UUID

    /// Reading order and hit tests; made anew when words, gaps, answers or marks change.
    var reading: Reading {
        if let r = readingCache { return r }
        let r = Reading(page: page)
        readingCache = r
        return r
    }

    private weak var app: AppState?
    private var readingCache: Reading? = nil
    private var undoStack: [PageControllerSnapshot] = []
    /// A second tap on the same word in a box within 8 s reads only that word.
    private var lastBoxTap: (word: Int, time: Date)? = nil
    private var flashToken = 0
    /// Grows with every listening run; callbacks of older runs are ignored.
    private var listenGeneration = 0
    private var listeningAnswer: UUID? = nil
    /// Typing (or one listening run) into this answer already has its undo step.
    private var typingUndoFor: UUID? = nil
    private var saveTask: Task<Void, Never>? = nil
    /// Letter edges per word (the words of a page never change).
    private var edgeCache: [Int: [CGFloat]] = [:]

    init(page: Page, image: UIImage, app: AppState) {
        _page = Published(initialValue: page)
        self.image = image
        self.id = page.id
        self.app = app
    }

    // MARK: - Hearing

    /// Mode "Wort": a word, a whole printed box, an answer, or what belongs into a gap.
    /// (What is read comes from Reading.hearWord / hearGap, as in the self test.)
    func tapWord(at p: CGPoint) {
        guard let app = app else { return }
        leaveAnswer()
        let r = reading
        if let ai = r.answerAt(p), ai < page.answers.count {
            speakAnswer(page.answers[ai].id)
            return
        }
        switch r.target(at: p) {
        case .gap(let k):
            lastBoxTap = nil
            say(r.hearGap(k, wholeSentence: false))
        case .word(let i):
            // a second tap on the same word in a box within 8 s reads only that word
            var again = false
            if let last = lastBoxTap, last.word == i, Date().timeIntervalSince(last.time) < 8 { again = true }
            let heard = r.hearWord(i, boxesTogether: app.settings.boxesTogether, again: again)
            if heard.wholeBox {
                lastBoxTap = (word: i, time: Date())
            } else {
                lastBoxTap = nil
            }
            say(heard.utterance)
        case .nothing:
            break
        }
    }

    /// Mode "Satz": the sentence around the word or gap; a word in a printed box reads the box.
    func tapSentence(at p: CGPoint) {
        leaveAnswer()
        let r = reading
        if let ai = r.answerAt(p), ai < page.answers.count {
            speakAnswer(page.answers[ai].id)
            return
        }
        lastBoxTap = nil
        switch r.target(at: p) {
        case .gap(let k):
            say(r.hearGap(k, wholeSentence: true))
        case .word(let i):
            say(r.hearSentence(i))
        case .nothing:
            break
        }
    }

    private func say(_ u: Utterance) {
        speak(parts: u.parts, rects: u.rects)
    }

    // MARK: - Answers

    /// Mode "Sprechen": a gap gets its field (or keeps the one it has), elsewhere a free field; then listen.
    func tapSpeak(at p: CGPoint) {
        guard let app = app else { return }
        let r = reading
        if let ai = r.answerAt(p), ai < page.answers.count {
            tapAnswer(page.answers[ai].id)
            return
        }
        stopListening()
        lastBoxTap = nil
        let target: UUID
        if let k = r.gapAt(p), k < page.gaps.count {
            let g = page.gaps[k]
            if let existing = page.answers.first(where: { $0.gap == g.id }) {
                target = existing.id
            } else {
                let a = Answer(id: UUID(), rect: r.newAnswerRect(forGap: k), gap: g.id, text: "")
                pushUndo()
                page.answers.append(a)
                target = a.id
            }
        } else {
            let a = Answer(id: UUID(), rect: r.newAnswerRect(at: p), gap: nil, text: "")
            pushUndo()
            page.answers.append(a)
            target = a.id
        }
        activeAnswer = target
        // (after a failed attempt the microphone is tried again; only a new failure opens the keyboard)
        if !app.settings.mic {
            keyboardAnswer = target
        } else {
            listen(target)
        }
        save()
    }

    /// A tap on an existing answer field: read it, open it for speaking, or erase it, depending on the tool.
    func tapAnswer(_ id: UUID) {
        guard let app = app, let a = answer(id) else { return }
        switch app.mode {
        case .wort, .satz:
            speakAnswer(id)
        case .sprechen:
            // (still listening for this field: let the child finish)
            if listeningAnswer == id && isMineListening { return }
            activeAnswer = id
            let micOK = app.settings.mic
            if pageControllerTrim(a.text).isEmpty {
                if micOK {
                    listen(id)
                } else {
                    keyboardAnswer = id
                }
            } else if !micOK {
                keyboardAnswer = id
            }
        case .radieren:
            pushUndo()
            deleteAnswer(id)
            save()
            app.announce("Gelöscht")
        case .markieren, .stift:
            break
        }
    }

    /// Listens for this field; what is heard is added to the text already in it.
    func listen(_ id: UUID) {
        guard let app = app, let a = answer(id) else { return }
        app.speaker.stop()
        activeAnswer = id
        if !app.settings.mic {
            keyboardAnswer = id
            return
        }
        stopMyListening()
        keyboardAnswer = nil
        typingUndoFor = nil
        let before = pageControllerTrim(a.text)
        listenGeneration += 1
        let gen = listenGeneration
        listeningAnswer = id
        PageControllerMic.owner = ObjectIdentifier(self)
        var heard = false
        app.listener.start(onText: { [weak self] text in
            guard let me = self, me.listenGeneration == gen else { return }
            let t = pageControllerTrim(text)
            if t.isEmpty { return }
            heard = true
            me.setAnswerText(id, before.isEmpty ? t : before + " " + t)
        }, onEnd: { [weak self] in
            guard let me = self, me.listenGeneration == gen else { return }
            me.listenFinished(id, heard: heard)
        })
    }

    /// Stops the microphone at once (no answer is read back).
    func stopListening() {
        if let app = app, app.listener.isListening {
            app.listener.stop()
        }
        stopMyListening()
    }

    func speakAnswer(_ id: UUID) {
        guard let app = app, let a = answer(id) else { return }
        if listeningAnswer != nil { stopMyListening() }
        let t = pageControllerTrim(a.text)
        if t.isEmpty {
            app.say("Noch leer")
            return
        }
        speak(t, rects: [a.rect])
    }

    /// Typed or heard text; the first change in one go gets one undo step.
    func setAnswerText(_ id: UUID, _ text: String) {
        guard let i = answerIndex(id), page.answers[i].text != text else { return }
        if typingUndoFor != id {
            pushUndo()
            typingUndoFor = id
        }
        page.answers[i].text = text
        scheduleSave()
    }

    func removeAnswer(_ id: UUID) {
        guard let a = answer(id) else { return }
        // (an empty field going away is not worth an undo step)
        if !pageControllerTrim(a.text).isEmpty { pushUndo() }
        deleteAnswer(id)
        save()
    }

    // MARK: - Marker

    /// A tap marks the whole word in the chosen colour; tapping it again (same colour) takes the mark off.
    func markTap(at p: CGPoint) {
        leaveAnswer()
        guard let wid = reading.wordAt(p, loose: true), let i = wordIndex(wid) else { return }
        pushUndo()
        toggleWholeMark(i)
        save()
    }

    /// A swipe across several words marks them all (or takes the marks off when it starts on a marked word);
    /// a swipe within one word marks the whole word. Parts of a word are marked in the word lens.
    func markStroke(_ points: [CGPoint]) {
        guard let start = points.first else { return }
        leaveAnswer()
        let r = reading
        let color = markColor
        let i0: Int? = r.wordAt(start, loose: true).flatMap { self.wordIndex($0) }
        var adding = true
        if let s = i0, page.marks.contains(where: { $0.word == s }) { adding = false }
        var xs: [CGFloat] = [start.x]
        var multi = false
        var order: [Int] = []
        for p in points.dropFirst() {
            xs.append(p.x)
            let hit: Int? = r.wordAt(p, loose: false).flatMap { self.wordIndex($0) }
            guard let h = hit else { continue }
            if !multi && h != i0 {
                multi = true
                if let s = i0 { order.append(s) }
            }
            if multi { order.append(h) }
        }

        if multi {
            var marks = page.marks
            var touched = Set<Int>()
            var changed = false
            for i in order {
                if touched.contains(i) { continue }
                touched.insert(i)
                let has = marks.contains(where: { $0.word == i })
                if adding && !has {
                    marks.append(Mark(id: UUID(), word: i, color: color, from: nil, to: nil))
                    changed = true
                } else if !adding && has {
                    marks.removeAll(where: { $0.word == i })
                    changed = true
                }
            }
            if changed {
                pushUndo()
                page.marks = marks
                save()
            }
            return
        }

        guard let i = i0, i < page.words.count else { return }
        let w = page.words[i].rect
        let lo = pageControllerClamp(xs.min() ?? start.x, w.minX, w.maxX)
        let hi = pageControllerClamp(xs.max() ?? start.x, w.minX, w.maxX)
        pushUndo()
        if hi - lo < w.height * 0.3 {
            // hardly moved: a tap
            toggleWholeMark(i)
        } else {
            var marks = page.marks
            marks.removeAll(where: { $0.word == i })
            marks.append(Mark(id: UUID(), word: i, color: color, from: nil, to: nil))
            page.marks = marks
        }
        save()
    }

    // MARK: - Word lens

    /// Finger held still on a word: the word opens big, letter by letter, and is read.
    func openLens(at p: CGPoint) {
        leaveAnswer()
        guard let wid = reading.wordAt(p, loose: true), let i = wordIndex(wid) else { return }
        guard letterEdges(i).count >= 2 else { return }
        lensWord = i
        hearLensWord()
    }

    func hearLensWord() {
        guard let i = lensWord, i >= 0, i < page.words.count else { return }
        let w = page.words[i]
        speak(Reading.cleanWord(w.text), rects: [w.rect])
    }

    func closeLens() {
        lensWord = nil
    }

    /// x positions (page pixels) of the edges between the letters of `WordLetters.letters` (one more than letters).
    func letterEdges(_ i: Int) -> [CGFloat] {
        if let e = edgeCache[i] { return e }
        guard i >= 0 && i < page.words.count else { return [] }
        let e = WordLetters.edges(word: page.words[i], image: image, pixelSize: page.pixelSize)
        edgeCache[i] = e
        return e
    }

    /// The colour of each letter of a word, from its marks (a later mark covers an earlier one).
    func letterColors(_ i: Int) -> [MarkColor?] {
        let edges = letterEdges(i)
        let n = max(0, edges.count - 1)
        var out = [MarkColor?](repeating: nil, count: n)
        for m in page.marks where m.word == i {
            for k in 0..<n {
                if let a = m.from, let b = m.to {
                    let mid = (edges[k] + edges[k + 1]) / 2
                    if mid >= min(a, b) && mid <= max(a, b) { out[k] = m.color }
                } else {
                    out[k] = m.color
                }
            }
        }
        return out
    }

    /// Word lens: letters a…b get the chosen colour, or lose it when all of them have it already.
    func markLetters(word i: Int, from a: Int, to b: Int) {
        var colors = letterColors(i)
        let n = colors.count
        guard n > 0 else { return }
        let lo = max(0, min(a, b))
        let hi = min(n - 1, max(a, b))
        guard lo <= hi else { return }
        let color = markColor
        let all = (lo...hi).allSatisfy { colors[$0] == color }
        for k in lo...hi { colors[k] = all ? nil : color }
        pushUndo()
        setLetterColors(i, colors)
        save()
    }

    /// Word lens: all marks of the word go.
    func clearLetters(word i: Int) {
        guard page.marks.contains(where: { $0.word == i }) else { return }
        pushUndo()
        page.marks.removeAll(where: { $0.word == i })
        save()
        app?.announce("Gelöscht")
    }

    // MARK: - Eraser, pen, undo

    /// Answer → mark → (wrongly recognised) gap. Pen strokes are erased by the eraser in the canvas.
    func eraseTap(at p: CGPoint) {
        guard let app = app else { return }
        leaveAnswer()
        let r = reading
        if let ai = r.answerAt(p), ai < page.answers.count {
            let aid = page.answers[ai].id
            pushUndo()
            deleteAnswer(aid)
            save()
            app.announce("Gelöscht")
            return
        }
        if let mi = r.markAt(p), mi < page.marks.count {
            pushUndo()
            page.marks.remove(at: mi)
            save()
            app.announce("Gelöscht")
            return
        }
        if let k = r.gapAt(p), k < page.gaps.count {
            pushUndo()
            var changed = page
            let gid = changed.gaps[k].id
            changed.gaps.remove(at: k)
            for n in changed.answers.indices where changed.answers[n].gap == gid {
                changed.answers[n].gap = nil
            }
            page = changed
            save()
            app.announce("Gelöscht")
        }
    }

    /// After each pen stroke; the undo step keeps the drawing from before it.
    func drawingChanged(_ data: Data) {
        if data == page.drawing { return }
        // the canvas reports a drawing that was set back (undo, opening) with other bytes: not a change
        if pageControllerSameDrawing(data, page.drawing) { return }
        pushUndo()
        page.drawing = data
        scheduleSave()
    }

    func undo() {
        guard let app = app else { return }
        stopListening()
        // (steps that changed nothing, e.g. an empty field that went away again, are skipped)
        let now = snapshot(keepEmpty: true)
        while let last = undoStack.last, last == now {
            undoStack.removeLast()
        }
        guard let s = undoStack.popLast() else {
            app.announce("Nichts zum Zurücknehmen")
            return
        }
        typingUndoFor = nil
        var restored = page
        restored.answers = s.answers
        restored.marks = s.marks
        restored.gaps = s.gaps
        restored.drawing = s.drawing
        page = restored
        if let a = activeAnswer, answerIndex(a) == nil { activeAnswer = nil }
        if let k = keyboardAnswer, answerIndex(k) == nil { keyboardAnswer = nil }
        save()
        app.announce("Zurück")
    }

    /// Writes the page into the Mappe now.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        app?.store.save(page)
    }

    // MARK: - Private

    private var markColor: MarkColor {
        return app?.settings.markColor ?? MarkColor.gelb
    }

    /// This page's listening run is the one going on.
    private var isMineListening: Bool {
        guard let app = app, listeningAnswer != nil else { return false }
        return app.listener.isListening && PageControllerMic.owner == ObjectIdentifier(self)
    }

    /// Ends this page's listening run (another page's run goes on).
    private func stopMyListening() {
        if isMineListening { app?.listener.stop() }
        listenGeneration += 1
        if PageControllerMic.owner == ObjectIdentifier(self) { PageControllerMic.owner = nil }
        if listeningAnswer != nil {
            listeningAnswer = nil
            save()
        }
    }

    private func listenFinished(_ id: UUID, heard: Bool) {
        listeningAnswer = nil
        if PageControllerMic.owner == ObjectIdentifier(self) { PageControllerMic.owner = nil }
        save()
        guard let app = app, let a = answer(id) else { return }
        if app.listener.blocked {
            // listening does not work here: the keyboard with its dictation key
            activeAnswer = id
            keyboardAnswer = id
            app.say("Tippe auf das Mikrofon der Tastatur und sprich.")
            return
        }
        if heard && !pageControllerTrim(a.text).isEmpty {
            speakAnswer(id)
        } else {
            app.say("Ich habe nichts gehört. Tippe auf das Mikrofon und sprich.")
        }
    }

    /// The bar moves away from a field: stop listening to it, drop it if it stayed empty.
    private func answerLeft(_ id: UUID) {
        if listeningAnswer == id { stopMyListening() }
        if keyboardAnswer == id { keyboardAnswer = nil }
        if typingUndoFor == id { typingUndoFor = nil }
        if let a = answer(id), pageControllerTrim(a.text).isEmpty {
            page.answers.removeAll(where: { $0.id == id })
            save()
        }
    }

    /// Another tool is used on the page: the answer bar closes.
    private func leaveAnswer() {
        if activeAnswer != nil { activeAnswer = nil }
        if keyboardAnswer != nil { keyboardAnswer = nil }
    }

    /// Removes a field without an undo step (the caller decides).
    private func deleteAnswer(_ id: UUID) {
        if listeningAnswer == id { stopMyListening() }
        if keyboardAnswer == id { keyboardAnswer = nil }
        if typingUndoFor == id { typingUndoFor = nil }
        page.answers.removeAll(where: { $0.id == id })
        if activeAnswer == id { activeAnswer = nil }
    }

    /// One mark per run of letters with the same colour; all letters in one colour: a mark on the whole word.
    private func setLetterColors(_ i: Int, _ colors: [MarkColor?]) {
        let edges = letterEdges(i)
        let n = colors.count
        guard edges.count == n + 1 else { return }
        var marks = page.marks.filter { $0.word != i }
        var k = 0
        while k < n {
            guard let c = colors[k] else {
                k += 1
                continue
            }
            var e = k
            while e + 1 < n && colors[e + 1] == c { e += 1 }
            if k == 0 && e == n - 1 {
                marks.append(Mark(id: UUID(), word: i, color: c, from: nil, to: nil))
            } else {
                marks.append(Mark(id: UUID(), word: i, color: c, from: edges[k].rounded(), to: edges[e + 1].rounded()))
            }
            k = e + 1
        }
        page.marks = marks
    }

    private func toggleWholeMark(_ i: Int) {
        let color = markColor
        let same = page.marks.contains(where: { $0.word == i && $0.from == nil && $0.color == color })
        var marks = page.marks
        marks.removeAll(where: { $0.word == i })
        if !same {
            marks.append(Mark(id: UUID(), word: i, color: color, from: nil, to: nil))
        }
        page.marks = marks
    }

    private func speak(_ text: String, rects: [CGRect]) {
        speak(parts: [SpeechPart.text(text)], rects: rects)
    }

    /// Reads and lights up the rectangles until the speech ends.
    private func speak(parts: [SpeechPart], rects: [CGRect]) {
        guard let app = app else { return }
        flashToken += 1
        let token = flashToken
        let pad = max(4, reading.textSize * 0.18)
        flash = rects.map { $0.insetBy(dx: -pad, dy: -pad) }
        app.say(parts: parts, onEnd: { [weak self] in
            self?.endFlash(token)
        })
        watchFlash(token)
    }

    private func endFlash(_ token: Int) {
        if token == flashToken && !flash.isEmpty { flash = [] }
    }

    /// Speech stopped from elsewhere never calls onEnd: the light goes out when the speaker is quiet.
    private func watchFlash(_ token: Int) {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let me = self, me.flashToken == token, !me.flash.isEmpty else { return }
                let speaking = me.app?.speaker.isSpeaking ?? false
                if !speaking {
                    me.flash = []
                    return
                }
            }
        }
    }

    /// Text changes come in quickly (typing, listening): write a moment later. The page is held until
    /// then, so a page closed right after typing is still written.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self.save()
        }
    }

    /// Empty fields are left out: undo never brings one back (one undo takes a spoken answer away).
    private func pushUndo() {
        undoStack.append(snapshot(keepEmpty: false))
        if undoStack.count > 60 {
            undoStack.removeFirst(undoStack.count - 60)
        }
        typingUndoFor = nil
    }

    private func snapshot(keepEmpty: Bool) -> PageControllerSnapshot {
        var answers = page.answers
        if !keepEmpty {
            answers.removeAll(where: { pageControllerTrim($0.text).isEmpty })
        }
        return PageControllerSnapshot(answers: answers, marks: page.marks, gaps: page.gaps, drawing: page.drawing)
    }

    private func pageDidChange(from old: Page) {
        let sameText = page.words == old.words && page.gaps == old.gaps && page.boxes == old.boxes
        let sameWork = page.answers == old.answers && page.marks == old.marks
        let sameSize = page.textHeight == old.textHeight && page.pixelSize == old.pixelSize
        if !(sameText && sameWork && sameSize) { readingCache = nil }
    }

    private func answerIndex(_ id: UUID) -> Int? {
        return page.answers.firstIndex(where: { $0.id == id })
    }

    private func answer(_ id: UUID) -> Answer? {
        return page.answers.first(where: { $0.id == id })
    }

    /// Word id → index in `page.words` (they are kept equal; checked anyway).
    private func wordIndex(_ id: Int) -> Int? {
        if id >= 0 && id < page.words.count && page.words[id].id == id { return id }
        return page.words.firstIndex(where: { $0.id == id })
    }
}

// MARK: - Helpers (no actor state)

fileprivate func pageControllerTrim(_ s: String) -> String {
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

fileprivate func pageControllerClamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    return max(lo, min(hi, v))
}

/// Number of strokes and their bounds; nil when the data cannot be read.
@MainActor fileprivate func pageControllerDrawingSummary(_ data: Data) -> (count: Int, bounds: CGRect)? {
    if data.isEmpty { return (count: 0, bounds: CGRect.zero) }
    guard let drawing = try? PKDrawing(data: data) else { return nil }
    if drawing.strokes.isEmpty { return (count: 0, bounds: CGRect.zero) }
    return (count: drawing.strokes.count, bounds: drawing.bounds)
}

@MainActor fileprivate func pageControllerSameDrawing(_ a: Data, _ b: Data) -> Bool {
    guard let x = pageControllerDrawingSummary(a), let y = pageControllerDrawingSummary(b) else { return false }
    if x.count != y.count { return false }
    if x.count == 0 { return true }
    let tolerance: CGFloat = 0.5
    let sameOrigin = abs(x.bounds.minX - y.bounds.minX) < tolerance && abs(x.bounds.minY - y.bounds.minY) < tolerance
    let sameSize = abs(x.bounds.width - y.bounds.width) < tolerance && abs(x.bounds.height - y.bounds.height) < tolerance
    return sameOrigin && sameSize
}
