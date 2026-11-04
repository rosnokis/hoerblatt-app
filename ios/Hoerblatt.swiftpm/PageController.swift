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

/// Reading the whole page aloud: not at all, sentence after sentence, or paused.
enum PageReadState: Equatable {
    case off, playing, paused
}

@MainActor final class PageController: ObservableObject, Identifiable {
    @Published var page: Page {
        didSet { pageDidChange(from: oldValue) }
    }
    let image: UIImage
    /// Lights up in orange while something is read.
    @Published var flash: [CGRect] = []
    /// The word being spoken in a sentence, lit up more strongly (teacher's wish: read along word by word).
    @Published var flashWord: [CGRect] = []
    /// While one word of an answer is spoken anew: that word – or the words heard for it – (they pulse red; the field
    /// itself does not).
    @Published var respeakRects: [CGRect] = []
    /// The word(s) just spoken anew, green for a moment.
    @Published var renewedRects: [CGRect] = []
    /// The whole page read aloud (a book; play button at the top left of the page).
    @Published var pageReadState: PageReadState = .off
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
    /// A word of an answer shown big in the word lens (Markieren: finger held on a word of an answer).
    @Published var lensAnswer: AnswerLensTarget? = nil
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
    /// The word last tapped (Wort/Satz): reading the whole page starts at its sentence.
    private var lastTappedWord: Int? = nil
    private var pageQueue: [Sentence] = []
    private var pageIndex = 0
    private var pageRun = 0
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
        endPageReading()
        leaveAnswer()
        let r = reading
        if let ai = r.answerAt(p), ai < page.answers.count {
            hearAnswer(page.answers[ai].id, at: p, whole: false)
            return
        }
        switch r.target(at: p) {
        case .gap(let k):
            lastBoxTap = nil
            // an empty gap: speak into it at once (teacher's wish); a filled one is read
            if page.gaps[k].kind == .check {
                checkBoxTapped(k)
            } else if r.answerText(onGap: k).isEmpty && canSpeak {
                speakIntoGap(k)
            } else {
                say(r.hearGap(k, wholeSentence: false))
            }
        case .word(let i):
            lastTappedWord = page.words[i].id
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
        endPageReading()
        leaveAnswer()
        let r = reading
        if let ai = r.answerAt(p), ai < page.answers.count {
            hearAnswer(page.answers[ai].id, at: p, whole: true)
            return
        }
        lastBoxTap = nil
        switch r.target(at: p) {
        case .gap(let k):
            // an empty gap: speak into it at once; a filled one reads its sentence with the answer
            if page.gaps[k].kind == .check {
                checkBoxTapped(k)
            } else if r.answerText(onGap: k).isEmpty && canSpeak {
                speakIntoGap(k)
            } else {
                say(r.hearGap(k, wholeSentence: true))
            }
        case .word(let i):
            lastTappedWord = page.words[i].id
            say(r.hearSentence(i))
        case .nothing:
            break
        }
    }

    private func say(_ u: Utterance) {
        speak(parts: u.parts, rects: u.rects, words: u.words)
    }

    // MARK: - Answers

    /// Mode "Sprechen": a gap gets its field (or keeps the one it has), elsewhere a free field; then listen.
    func tapSpeak(at p: CGPoint) {
        guard let app = app else { return }
        endPageReading()
        let r = reading
        if let ai = r.answerAt(p), ai < page.answers.count {
            tapAnswer(page.answers[ai].id, at: p)
            return
        }
        stopListening()
        lastBoxTap = nil
        if let k = r.gapAt(p), k < page.gaps.count {
            if page.gaps[k].kind == .check {
                checkBoxTapped(k)
            } else {
                speakIntoGap(k)
            }
            return
        }
        let a = Answer(id: UUID(), rect: r.newAnswerRect(at: p), gap: nil, text: "")
        pushUndo()
        page.answers.append(a)
        activeAnswer = a.id
        // (after a failed attempt the microphone is tried again; only a new failure opens the keyboard)
        if !app.settings.mic {
            keyboardAnswer = a.id
        } else {
            listen(a.id)
        }
        save()
    }

    /// A check box ☐: its label ("richtig"), then the pen is picked to cross it (teacher's wish).
    private func checkBoxTapped(_ k: Int) {
        guard let app = app, k >= 0, k < page.gaps.count else { return }
        stopListening()
        let label = pageControllerTrim(page.gaps[k].head ?? "")
        // (the pen hidden by the teacher: the child crosses on the paper; only the label is read)
        if !app.settings.shows(.stift) {
            if !label.isEmpty { app.say(label) }
            return
        }
        app.setModeQuietly(.stift)
        app.say(label.isEmpty ? "Kreuze mit dem Stift an." : label + ". Kreuze mit dem Stift an.")
    }

    /// A gap gets its answer field (or keeps the one it has) and the Hörblatt listens at once – in every tool that
    /// reads (Wort, Satz, Sprechen). An empty table cell or writing field first says its heading ("Nomen").
    private func speakIntoGap(_ k: Int) {
        guard let app = app, k >= 0, k < page.gaps.count else { return }
        stopListening()
        let g = page.gaps[k]
        let target: UUID
        if let existing = page.answers.first(where: { $0.gap == g.id }) {
            target = existing.id
        } else {
            let a = Answer(id: UUID(), rect: reading.newAnswerRect(forGap: k), gap: g.id, text: "")
            pushUndo()
            page.answers.append(a)
            target = a.id
        }
        activeAnswer = target
        let head = pageControllerTrim(g.head ?? "")
        if !app.settings.mic {
            // no own listening: the keyboard with its dictation key
            if !head.isEmpty { app.say(head) }
            keyboardAnswer = target
        } else if head.isEmpty {
            listen(target)
        } else {
            // the heading first, then listen (if the child has not gone on meanwhile)
            app.say(head, onEnd: { [weak self] in
                guard let me = self, me.activeAnswer == target else { return }
                me.listen(target)
            })
        }
        save()
    }

    /// A tap on an existing answer field: read it (Wort: the word under the finger), open it for speaking, or erase
    /// it, depending on the tool.
    func tapAnswer(_ id: UUID, at p: CGPoint? = nil) {
        guard let app = app, let a = answer(id) else { return }
        switch app.mode {
        case .wort:
            endPageReading()
            hearAnswer(id, at: p, whole: false)
        case .satz:
            endPageReading()
            hearAnswer(id, at: p, whole: true)
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
            } else if let p = p {
                // on a word: speak it anew; between words: speak more in there
                speakAt(id, p)
            }
        case .radieren:
            eraseAnswerWord(id, at: p)
        case .markieren:
            // the word of the answer under the finger, as a printed word
            if let p = p { markAnswerWord(id, at: p) }
        case .stift:
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
        // a short "pling" first: the child hears that it may speak now (it cannot read a hint)
        app.speaker.playListenCue(then: { [weak self] in
            guard let me = self, let app = me.app, me.listenGeneration == gen, me.listeningAnswer == id else { return }
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
        })
    }

    /// Stops the microphone at once (no answer is read back).
    func stopListening() {
        if let app = app, app.listener.isListening {
            app.listener.stop()
        }
        stopMyListening()
    }

    /// Reads the answer; the word being spoken lights up (as in a printed sentence).
    func speakAnswer(_ id: UUID) {
        guard let app = app, let a = answer(id) else { return }
        if listeningAnswer != nil { stopMyListening() }
        let t = pageControllerTrim(a.text)
        if t.isEmpty {
            app.say("Noch leer")
            return
        }
        // (the places of the words are counted in the whole text; what is spoken starts after leading spaces)
        let lead = (a.text as NSString).range(of: t).location
        let shift = lead == NSNotFound ? 0 : lead
        let spoken = answerWordList(a).map { w in
            SpokenWord(start: w.range.location - shift, length: w.range.length, rects: [w.rect])
        }
        speak(parts: [SpeechPart.text(t)], rects: [a.rect], words: [spoken])
    }

    /// Wort on an answer: only the word under the finger (as a printed word); where there is no word, the whole
    /// answer. Satz: the sentence the answer completes ("Ich vermute, dass … weil …"); a free field: the answer.
    private func hearAnswer(_ id: UUID, at p: CGPoint?, whole: Bool) {
        guard let a = answer(id) else { return }
        if whole, let gid = a.gap, let k = page.gaps.firstIndex(where: { $0.id == gid }) {
            if listeningAnswer != nil { stopMyListening() }
            say(reading.hearGap(k, wholeSentence: true))
            return
        }
        // Satz in a free field (an empty sheet holds a whole text): the sentence around the word, up to . ! ?
        if whole, let p = p {
            let words = answerWordList(a)
            if let k = answerWordIndex(words, at: p, textHeight: reading.textSize) {
                let ns = a.text as NSString
                func ends(_ i: Int) -> Bool {
                    let t = ns.substring(with: words[i].range)
                    return readingAnswerEndsSentence(t)
                }
                var s = k
                while s > 0 && !ends(s - 1) { s -= 1 }
                var e = k
                while e < words.count - 1 && !ends(e) { e += 1 }
                let start = words[s].range.location
                let end = words[e].range.location + words[e].range.length
                let said = ns.substring(with: NSRange(location: start, length: end - start))
                let lit = words[s...e].map { w in
                    SpokenWord(start: w.range.location - start, length: w.range.length, rects: [w.rect])
                }
                if listeningAnswer != nil { stopMyListening() }
                speak(parts: [SpeechPart.text(said)], rects: words[s...e].map { $0.rect }, words: [lit])
                return
            }
        }
        if !whole, let p = p {
            let words = answerWordList(a)
            if let k = answerWordIndex(words, at: p, textHeight: reading.textSize) {
                let text = (a.text as NSString).substring(with: words[k].range)
                let clean = Reading.cleanWord(text)
                if listeningAnswer != nil { stopMyListening() }
                // (lit up strongly while spoken, as a printed word being read)
                let said = clean.isEmpty ? text : clean
                let lit = SpokenWord(start: 0, length: (said as NSString).length, rects: [words[k].rect])
                speak(parts: [SpeechPart.text(said)], rects: [words[k].rect], words: [[lit]])
                return
            }
        }
        speakAnswer(id)
    }

    /// The words of an answer and where they stand on the page (as the field lays them out).
    func answerWordList(_ a: Answer) -> [AnswerWord] {
        return answerWords(a, in: page, textHeight: reading.textSize)
    }

    /// The words of an answer within a stretch of its text (UTF-16 place and length).
    private func answerWordsSpanning(in a: Answer, from location: Int, length: Int) -> [AnswerWord] {
        let end = location + max(1, length)
        return answerWordList(a).filter { $0.range.location < end && $0.range.location + $0.range.length > location }
    }

    /// Finger held on a word of an answer: that word is spoken anew (pling, listen) and replaces the old one; then the
    /// new word is read. (The child mumbles a little: "Er Ritter durch den Wald" – only "Ritter" is said again.)
    func respeakWord(_ id: UUID, at p: CGPoint) {
        guard let a = answer(id) else { return }
        let words = answerWordList(a)
        guard let k = answerWordIndex(words, at: p, textHeight: reading.textSize) else { return }
        speakInto(id, range: words[k].range, mark: [words[k].rect])
    }

    /// Sprechen on a written answer: a word under the finger is spoken anew; between two words (or after the last)
    /// new words go in there – a red bar shows the place.
    private func speakAt(_ id: UUID, _ p: CGPoint) {
        guard let a = answer(id) else { return }
        let th = reading.textSize
        let words = answerWordList(a)
        if let w = words.first(where: { $0.rect.insetBy(dx: -th * 0.05, dy: -th * 0.2).contains(p) }) {
            speakInto(id, range: w.range, mark: [w.rect])
            return
        }
        let point = answerInsertionPoint(words, textLength: (a.text as NSString).length, at: p, textHeight: th)
        speakInto(id, range: NSRange(location: point.location, length: 0), mark: point.caret.map { [$0] } ?? [])
    }

    /// Listens and puts what is heard into the answer: `range` with a length replaces that word ("Ritter" → "ritt"),
    /// an empty `range` inserts there. One undo step; the place pulses red meanwhile (not the whole field).
    private func speakInto(_ id: UUID, range: NSRange, mark: [CGRect]) {
        guard let app = app, let a = answer(id) else { return }
        endPageReading()
        stopListening()
        app.speaker.stop()
        activeAnswer = id
        if !app.settings.mic {
            // no own listening: the keyboard (with its dictation key) in this field
            keyboardAnswer = id
            return
        }
        keyboardAnswer = nil
        let old = a.text as NSString
        guard range.location >= 0, range.location + range.length <= old.length else { return }
        let original = a.text
        let before = old.substring(to: range.location)
        let after = old.substring(from: range.location + range.length)
        let oldWord = old.substring(with: range)
        let beforeTrim = pageControllerTrim(before)
        let sentenceStart = beforeTrim.isEmpty || ".!?".contains(beforeTrim.last ?? " ")
        pushUndo()
        // (the whole run is one undo step)
        typingUndoFor = id
        listenGeneration += 1
        let gen = listenGeneration
        listeningAnswer = id
        PageControllerMic.owner = ObjectIdentifier(self)
        respeakRects = mark
        renewedRects = []
        var newRange = NSRange(location: range.location, length: 0)
        var newWords = ""
        app.speaker.playListenCue(then: { [weak self] in
            guard let me = self, let app = me.app, me.listenGeneration == gen, me.listeningAnswer == id else { return }
            app.listener.start(onText: { [weak self] text in
                guard let me = self, me.listenGeneration == gen else { return }
                if range.length > 0 {
                    let w = answerReplacement(oldWord, heard: text, sentenceStart: sentenceStart)
                    if w.isEmpty { return }
                    newWords = w
                    newRange = NSRange(location: range.location, length: (w as NSString).length)
                    me.setAnswerText(id, before + w + after)
                } else {
                    guard let put = answerInserting(original, at: range.location, heard: text) else { return }
                    newWords = (put.text as NSString).substring(with: put.range)
                    newRange = put.range
                    me.setAnswerText(id, put.text)
                }
                // (the red mark follows the new word(s) as they are heard)
                if let now = me.answer(id) {
                    let lit = me.answerWordsSpanning(in: now, from: newRange.location, length: newRange.length)
                    if !lit.isEmpty { me.respeakRects = lit.map { $0.rect } }
                }
            }, onEnd: { [weak self] in
                guard let me = self, me.listenGeneration == gen else { return }
                me.respeakFinished(id, word: newWords, at: newRange.location)
            })
        })
    }

    /// Radiergummi on an answer: only the word under the finger goes (never the whole text with one tap – teacher:
    /// it must be safe). Where there is no word, nothing happens.
    private func eraseAnswerWord(_ id: UUID, at p: CGPoint?) {
        guard let app = app, let a = answer(id) else { return }
        let th = reading.textSize
        let words = answerWordList(a)
        guard let p = p,
              let w = words.first(where: { $0.rect.insetBy(dx: -th * 0.1, dy: -th * 0.2).contains(p) }) else {
            app.say(words.isEmpty ? "Das Feld ist leer." : "Tippe genau auf ein Wort.")
            return
        }
        let gone = Reading.cleanWord((a.text as NSString).substring(with: w.range))
        pushUndo()
        typingUndoFor = id
        setAnswerText(id, answerRemovingWord(a.text, range: w.range))
        typingUndoFor = nil
        // (an answer left empty goes, unless it is the writing of an empty sheet)
        if let now = answer(id), pageControllerTrim(now.text).isEmpty, page.blank != true {
            deleteAnswer(id)
        }
        save()
        app.say(gone.isEmpty ? "Gelöscht" : gone + " ist gelöscht.")
    }

    private func respeakFinished(_ id: UUID, word: String, at location: Int) {
        listeningAnswer = nil
        if PageControllerMic.owner == ObjectIdentifier(self) { PageControllerMic.owner = nil }
        respeakRects = []
        save()
        guard let app = app, let a = answer(id) else { return }
        if app.listener.blocked {
            activeAnswer = id
            keyboardAnswer = id
            app.say("Tippe auf das Mikrofon der Tastatur und sprich.")
            return
        }
        if word.isEmpty {
            app.say("Ich habe nichts gehört. Versuch es noch einmal.")
            return
        }
        // the new word(s) – one spoken word may come back as several – green for a moment, and read
        let lit = answerWordsSpanning(in: a, from: location, length: (word as NSString).length)
        if !lit.isEmpty {
            let rects = lit.map { $0.rect }
            renewedRects = rects
            let said = lit.map { Reading.cleanWord((a.text as NSString).substring(with: $0.range)) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            speak(said.isEmpty ? word : said, rects: [])
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if let me = self, me.renewedRects == rects { me.renewedRects = [] }
            }
        } else {
            speakAnswer(id)
        }
    }

    /// Typed or heard text; the first change in one go gets one undo step.
    func setAnswerText(_ id: UUID, _ text: String) {
        guard let i = answerIndex(id), page.answers[i].text != text else { return }
        if typingUndoFor != id {
            pushUndo()
            typingUndoFor = id
        }
        page.answers[i].text = text
        // (marks on the answer stay on their letters, wherever these went)
        page.answers[i].marks = answerMarksFixed(page.answers[i].marks, in: text)
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
        if let ai = reading.answerAt(p), ai < page.answers.count {
            markAnswerWord(page.answers[ai].id, at: p)
            return
        }
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
        if let ai = reading.answerAt(start), ai < page.answers.count {
            markAnswerStroke(page.answers[ai].id, points)
            return
        }
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
        if let ai = reading.answerAt(p), ai < page.answers.count {
            openAnswerLens(page.answers[ai].id, at: p)
            return
        }
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
        lensAnswer = nil
    }

    // MARK: - Marker and word lens on answers (the child's own words behave as printed ones)

    /// A tap marks the whole word of the answer (tapped again in the same colour: the mark goes).
    private func markAnswerWord(_ id: UUID, at p: CGPoint) {
        guard let a = answer(id) else { return }
        let words = answerWordList(a)
        guard let k = answerWordIndex(words, at: p, textHeight: reading.textSize) else { return }
        let letters = answerLetterRanges(a.text, word: words[k].range)
        guard !letters.isEmpty else { return }
        let colors = answerLetterColors(a.marks, letters: letters)
        let color = markColor
        let all = colors.allSatisfy { $0 == color }
        pushUndo()
        setAnswerMarks(id, answerMarksSetting(a.marks, text: a.text, letters: letters,
                                              colors: Array(repeating: all ? nil : color, count: letters.count)))
        save()
    }

    /// A swipe over words of an answer marks them all (or takes the marks off when it starts on a marked word).
    private func markAnswerStroke(_ id: UUID, _ points: [CGPoint]) {
        guard let a = answer(id), let start = points.first else { return }
        let th = reading.textSize
        let words = answerWordList(a)
        var hit: [Int] = []
        for p in points {
            if let k = answerWordIndex(words, at: p, textHeight: th), !hit.contains(k) { hit.append(k) }
        }
        guard let first = answerWordIndex(words, at: start, textHeight: th) ?? hit.first else { return }
        let firstLetters = answerLetterRanges(a.text, word: words[first].range)
        let adding = !answerLetterColors(a.marks, letters: firstLetters).contains { $0 != nil }
        var marks = a.marks
        for k in hit {
            let letters = answerLetterRanges(a.text, word: words[k].range)
            if letters.isEmpty { continue }
            marks = answerMarksSetting(marks, text: a.text, letters: letters,
                                       colors: Array(repeating: adding ? markColor : nil, count: letters.count))
        }
        pushUndo()
        setAnswerMarks(id, marks)
        save()
    }

    private func setAnswerMarks(_ id: UUID, _ marks: [AnswerMark]?) {
        guard let i = answerIndex(id) else { return }
        page.answers[i].marks = marks
    }

    /// Finger held on a word of an answer: the word lens shows it letter by letter.
    private func openAnswerLens(_ id: UUID, at p: CGPoint) {
        guard let a = answer(id) else { return }
        let words = answerWordList(a)
        guard let k = answerWordIndex(words, at: p, textHeight: reading.textSize),
              !answerLetterRanges(a.text, word: words[k].range).isEmpty else { return }
        lensAnswer = AnswerLensTarget(id: id, range: words[k].range)
        hearLensAnswer()
    }

    /// The letters of the word in the answer lens and their colours.
    func lensAnswerLetters() -> (letters: [String], colors: [MarkColor?])? {
        guard let t = lensAnswer, let a = answer(t.id) else { return nil }
        let ranges = answerLetterRanges(a.text, word: t.range)
        if ranges.isEmpty { return nil }
        let ns = a.text as NSString
        return (letters: ranges.map { ns.substring(with: $0) }, colors: answerLetterColors(a.marks, letters: ranges))
    }

    func hearLensAnswer() {
        guard let t = lensAnswer, let a = answer(t.id) else { return }
        let ns = a.text as NSString
        guard t.range.location + t.range.length <= ns.length else { return }
        let rect = answerWordList(a).first(where: { $0.range == t.range })?.rect
        speak(Reading.cleanWord(ns.substring(with: t.range)), rects: rect.map { [$0] } ?? [])
    }

    /// Word lens on an answer word: letters a…b get the chosen colour, or lose it when all of them have it already.
    func markAnswerLetters(from a0: Int, to b0: Int) {
        guard let t = lensAnswer, let a = answer(t.id) else { return }
        let ranges = answerLetterRanges(a.text, word: t.range)
        var colors = answerLetterColors(a.marks, letters: ranges)
        let n = colors.count
        guard n > 0 else { return }
        let lo = max(0, min(a0, b0))
        let hi = min(n - 1, max(a0, b0))
        guard lo <= hi else { return }
        let color = markColor
        let all = (lo...hi).allSatisfy { colors[$0] == color }
        for k in lo...hi { colors[k] = all ? nil : color }
        pushUndo()
        setAnswerMarks(t.id, answerMarksSetting(a.marks, text: a.text, letters: ranges, colors: colors))
        save()
    }

    /// Word lens on an answer word: all its marks go.
    func clearAnswerLetters() {
        guard let t = lensAnswer, let a = answer(t.id) else { return }
        let ranges = answerLetterRanges(a.text, word: t.range)
        guard answerLetterColors(a.marks, letters: ranges).contains(where: { $0 != nil }) else { return }
        pushUndo()
        setAnswerMarks(t.id, answerMarksSetting(a.marks, text: a.text, letters: ranges,
                                                colors: Array(repeating: nil, count: ranges.count)))
        save()
        app?.announce("Gelöscht")
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
            // (a word of it, never the whole answer)
            eraseAnswerWord(page.answers[ai].id, at: p)
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
            // (remembered: reading the page again after an update does not bring it back)
            changed.erasedGaps = (changed.erasedGaps ?? []) + [changed.gaps[k].rect]
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

    /// The child is speaking, typing or in the word lens: the page is not read again just now.
    var isBusyEditing: Bool {
        return listeningAnswer != nil || keyboardAnswer != nil || lensWord != nil || lensAnswer != nil
    }

    /// The page read again with a newer recognition (after an update): words, gaps and boxes are new; answers, marks
    /// and pen strokes stay (`pageCarryOver`). The undo steps go: they hold marks by the old word numbers.
    func replaceReading(with fresh: Page) {
        endPageReading()
        lastBoxTap = nil
        lastTappedWord = nil
        if !flash.isEmpty { flash = [] }
        if !flashWord.isEmpty { flashWord = [] }
        edgeCache = [:]
        undoStack = []
        typingUndoFor = nil
        page = pageCarryOver(page, into: fresh)
        save()
    }

    /// Writes the page into the Mappe now.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        app?.store.save(page)
    }

    // MARK: - Private

    /// The teacher has not hidden "Sprechen": an empty gap starts listening (otherwise it is only read).
    private var canSpeak: Bool {
        return app?.settings.shows(.sprechen) ?? true
    }

    private var markColor: MarkColor {
        return app?.settings.markColor ?? MarkColor.gelb
    }

    /// This page's listening run is the one going on.
    /// This field is being listened to now (red, pulsing) – in every tool, since a gap starts listening in Wort and
    /// Satz too.
    func isListening(to id: UUID) -> Bool {
        return listeningAnswer == id && isMineListening
    }

    private var isMineListening: Bool {
        guard let app = app, listeningAnswer != nil else { return false }
        return app.listener.isListening && PageControllerMic.owner == ObjectIdentifier(self)
    }

    /// Ends this page's listening run (another page's run goes on).
    private func stopMyListening() {
        if isMineListening { app?.listener.stop() }
        // (the word being spoken anew is marked only while listening)
        if !respeakRects.isEmpty { respeakRects = [] }
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
        // (the writing of an empty sheet stays, even empty)
        if let a = answer(id), pageControllerTrim(a.text).isEmpty, page.blank != true {
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

    // MARK: - Reading the whole page (a book)

    /// Play: from the sentence of the word last tapped (else from the top) to the end of the page; pause; go on.
    func togglePageReading() {
        guard let app = app else { return }
        switch pageReadState {
        case .off:
            // (two pages side by side: only one is read at a time)
            app.endPageReading(except: self)
            leaveAnswer()
            stopListening()
            pageQueue = reading.pageSentences(fromWord: lastTappedWord)
            pageIndex = 0
            if pageQueue.isEmpty {
                app.say("Hier finde ich nichts zum Vorlesen.")
                return
            }
            pageReadState = .playing
            readPageSentence()
        case .playing:
            // pause: the sentence starts again when going on
            pageRun += 1
            pageReadState = .paused
            app.speaker.stop()
            flash = []
            flashWord = []
        case .paused:
            app.endPageReading(except: self)
            pageReadState = .playing
            readPageSentence()
        }
    }

    /// A tap on the page, another tool or page: reading the whole page stops.
    func endPageReading() {
        guard pageReadState != .off else { return }
        pageRun += 1
        pageReadState = .off
        app?.speaker.stop()
        flash = []
        flashWord = []
    }

    private func readPageSentence() {
        pageRun += 1
        let run = pageRun
        guard pageIndex < pageQueue.count else {
            pageReadState = .off
            app?.announce("Ende der Seite")
            return
        }
        let s = pageQueue[pageIndex]
        speak(parts: s.parts, rects: s.rects, words: s.words, then: { [weak self] in
            guard let me = self, me.pageRun == run, me.pageReadState == .playing else { return }
            me.pageIndex += 1
            me.readPageSentence()
        })
        watchPageReading(run)
    }

    /// Speech stopped from elsewhere never ends the sentence: the button goes back to play.
    private func watchPageReading(_ run: Int) {
        Task { @MainActor [weak self] in
            var quiet = 0
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let me = self, me.pageRun == run, me.pageReadState == .playing else { return }
                quiet = (me.app?.speaker.isSpeaking ?? false) ? 0 : quiet + 1
                if quiet >= 3 {
                    me.pageReadState = .off
                    return
                }
            }
        }
    }

    /// Reads and lights up the rectangles until the speech ends; with `words`, the word being spoken too;
    /// `then` after the natural end (not after a stop).
    private func speak(parts: [SpeechPart], rects: [CGRect], words: [[SpokenWord]] = [], then: (() -> Void)? = nil) {
        guard let app = app else { return }
        flashToken += 1
        let token = flashToken
        let pad = max(4, reading.textSize * 0.18)
        flash = rects.map { $0.insetBy(dx: -pad, dy: -pad) }
        if !flashWord.isEmpty { flashWord = [] }
        var onWord: ((Int, NSRange) -> Void)? = nil
        if !words.isEmpty {
            let wordPad = max(2, reading.textSize * 0.08)
            onWord = { [weak self] part, range in
                guard let me = self, me.flashToken == token, part >= 0, part < words.count else { return }
                // the word that holds the start of the spoken range
                if let w = words[part].first(where: { range.location >= $0.start && range.location < $0.start + $0.length })
                    ?? words[part].first(where: { $0.start >= range.location }) {
                    let lit = w.rects.map { $0.insetBy(dx: -wordPad, dy: -wordPad) }
                    if me.flashWord != lit { me.flashWord = lit }
                }
            }
        }
        app.say(parts: parts, onEnd: { [weak self] in
            self?.endFlash(token)
            then?()
        }, onWord: onWord)
        watchFlash(token)
    }

    private func endFlash(_ token: Int) {
        if token == flashToken && !flash.isEmpty { flash = [] }
        if token == flashToken && !flashWord.isEmpty { flashWord = [] }
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
                    me.flashWord = []
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
