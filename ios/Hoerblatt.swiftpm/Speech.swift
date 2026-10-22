import Foundation
import AVFoundation
import Speech
import Combine

// Reading aloud (AVSpeechSynthesizer), the gap tone (a WAV made in memory, like TONES in index.html)
// and listening (SFSpeechRecognizer, on the device when it can).

// MARK: - Audio session

/// The one audio session, shared by Speaker and Listener.
@MainActor fileprivate enum SpeechAudio {
    /// The Listener records: the Speaker must not switch the session away meanwhile.
    static var recording = false

    /// `.playback` sounds even when the iPad is set to silent.
    static func usePlayback() {
        if recording { return }
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .spokenAudio {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
        try? session.setActive(true)
    }

    static func useRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        recording = true
    }

    static func endRecording() {
        recording = false
        usePlayback()
    }
}

// MARK: - Speaker

/// Reads text and gap tones strictly one after another.
@MainActor final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking: Bool = false
    /// AppSettings.rate: 1 = the system's normal speed.
    var rate: Double = 0.85
    /// Gap tone; the sound is made anew when it changes.
    var tone: ToneKind = .glocke {
        didSet {
            if tone != oldValue { makeTone() }
        }
    }

    private var synth = AVSpeechSynthesizer()
    /// Set when an utterance never started: the synthesizer is replaced before the next one.
    private var renewSynth = false
    private var voice: AVSpeechSynthesisVoice?
    private var voicePicked = Date.distantPast
    private var tonePlayer: AVAudioPlayer?
    private var toneLength: Double = 0.7

    /// Grows with every new sequence and with stop(); callbacks of older sequences are ignored.
    private var generation = 0
    /// Grows with every part, so each part ends exactly once (delegate, watchdog or timer).
    private var partToken = 0
    private var parts: [SpeechPart] = []
    private var nextIndex = 0
    private var endHandler: (() -> Void)?
    private var current: AVSpeechUtterance?
    private var currentStarted = false

    override init() {
        super.init()
        synth.delegate = self
        voice = speechGermanVoice()
        voicePicked = Date()
        makeTone()
    }

    func say(_ text: String, onEnd: (() -> Void)? = nil) {
        say(parts: [SpeechPart.text(text)], onEnd: onEnd)
    }

    /// Text parts and gap tones one after another; onEnd after the last one (not after stop()).
    func say(parts newParts: [SpeechPart], onEnd: (() -> Void)? = nil) {
        let wasBusy = synth.isSpeaking
        halt()
        var list: [SpeechPart] = []
        for part in newParts {
            switch part {
            case .text(let s):
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { list.append(part) }
            case .tone:
                list.append(part)
            }
        }
        if list.isEmpty {
            isSpeaking = false
            onEnd?()
            return
        }
        if renewSynth {
            renewSynth = false
            synth.delegate = nil
            let fresh = AVSpeechSynthesizer()
            fresh.delegate = self
            synth = fresh
        }
        SpeechAudio.usePlayback()
        parts = list
        nextIndex = 0
        endHandler = onEnd
        isSpeaking = true
        let gen = generation
        if wasBusy {
            // the synthesizer may drop an utterance that follows a cancel too closely
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000)
                self?.playNext(gen)
            }
        } else {
            playNext(gen)
        }
    }

    /// Only the gap tone (to try it out in the settings).
    func playTone() {
        say(parts: [SpeechPart.tone], onEnd: nil)
    }

    /// Stops everything at once; onEnd is not called.
    func stop() {
        halt()
        if isSpeaking { isSpeaking = false }
    }

    // MARK: Sequence

    private func halt() {
        generation += 1
        partToken += 1
        parts = []
        nextIndex = 0
        endHandler = nil
        current = nil
        currentStarted = false
        if synth.isSpeaking {
            _ = synth.stopSpeaking(at: .immediate)
        }
        tonePlayer?.stop()
    }

    private func playNext(_ gen: Int) {
        guard gen == generation else { return }
        guard nextIndex < parts.count else {
            finishSequence()
            return
        }
        let part = parts[nextIndex]
        nextIndex += 1
        partToken += 1
        let token = partToken
        switch part {
        case .text(let s):
            speakPart(s, gen: gen, token: token)
        case .tone:
            tonePart(gen: gen, token: token)
        }
    }

    private func partDone(gen: Int, token: Int) {
        guard gen == generation, token == partToken else { return }
        current = nil
        currentStarted = false
        playNext(gen)
    }

    private func finishSequence() {
        let end = endHandler
        generation += 1
        partToken += 1
        parts = []
        nextIndex = 0
        endHandler = nil
        current = nil
        currentStarted = false
        isSpeaking = false
        end?()
    }

    // MARK: Text

    private func speakPart(_ text: String, gen: Int, token: Int) {
        let u = AVSpeechUtterance(string: text)
        if let v = germanVoice() { u.voice = v }
        let r = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, r))
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        current = u
        currentStarted = false
        synth.speak(u)
        watch(gen: gen, token: token, length: text.count)
    }

    /// Looked up again now and then: a better voice may have been downloaded meanwhile.
    private func germanVoice() -> AVSpeechSynthesisVoice? {
        if voice == nil || Date().timeIntervalSince(voicePicked) > 600 {
            voice = speechGermanVoice()
            voicePicked = Date()
        }
        return voice
    }

    /// Ends the part also when didFinish never comes (as in the web version): the voice went quiet after
    /// it had started, or nothing at all came out for a long time.
    private func watch(gen: Int, token: Int, length: Int) {
        let limit = 3.0 + Double(length) * 0.15 / max(0.3, rate)
        let begin = Date()
        Task { @MainActor [weak self] in
            var heard = false
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let me = self, me.generation == gen, me.partToken == token else { return }
                if me.synth.isSpeaking {
                    heard = true
                    continue
                }
                if me.currentStarted { heard = true }
                let elapsed = Date().timeIntervalSince(begin)
                if heard && elapsed > 0.4 {
                    me.partDone(gen: gen, token: token)
                    return
                }
                if elapsed > limit {
                    // nothing came out (seen after recording): use a fresh synthesizer next time
                    if !heard { me.renewSynth = true }
                    me.partDone(gen: gen, token: token)
                    return
                }
            }
        }
    }

    private func utteranceStarted(_ u: AVSpeechUtterance) {
        if u === current { currentStarted = true }
    }

    private func utteranceFinished(_ u: AVSpeechUtterance) {
        guard u === current else { return }
        partDone(gen: generation, token: partToken)
    }

    // The synthesizer calls these on a thread of its own choice; they only hop to the main actor.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let ref = SpeechUtteranceRef(utterance)
        Task { @MainActor in
            self.utteranceStarted(ref.utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let ref = SpeechUtteranceRef(utterance)
        Task { @MainActor in
            self.utteranceFinished(ref.utterance)
        }
    }

    // MARK: Tone

    private func tonePart(gen: Int, token: Int) {
        if let p = tonePlayer {
            p.stop()
            p.currentTime = 0
            _ = p.play()
        }
        // the next part follows a moment after the tone (like the web version)
        let wait = toneLength + 0.25
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.partDone(gen: gen, token: token)
        }
    }

    private func makeTone() {
        toneLength = speechToneLength(tone)
        tonePlayer?.stop()
        tonePlayer = try? AVAudioPlayer(data: speechToneWAV(tone))
        _ = tonePlayer?.prepareToPlay()
    }
}

/// Carries an utterance from the synthesizer's callback to the main actor
/// (kept as an object, so a finished utterance can never be mistaken for a new one at the same address).
fileprivate final class SpeechUtteranceRef: @unchecked Sendable {
    let utterance: AVSpeechUtterance
    init(_ utterance: AVSpeechUtterance) {
        self.utterance = utterance
    }
}

/// German voice: premium, then enhanced, then the system's default German voice.
fileprivate func speechGermanVoice() -> AVSpeechSynthesisVoice? {
    let german = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
    if let v = german.first(where: { $0.quality == .premium }) { return v }
    if let v = german.first(where: { $0.quality == .enhanced }) { return v }
    if let v = AVSpeechSynthesisVoice(language: "de-DE") { return v }
    return AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("de") })
}

// MARK: - Gap tones (same sounds as TONES/toneURL in index.html)

fileprivate func speechToneLength(_ kind: ToneKind) -> Double {
    switch kind {
    case .glocke: return 0.7
    case .tropfen: return 0.25
    case .holz: return 0.35
    case .pfiff: return 0.32
    }
}

/// Sample value at time t (seconds), about -1…1.
fileprivate func speechToneValue(_ kind: ToneKind, _ t: Double) -> Double {
    let w: Double = 2 * Double.pi
    switch kind {
    case .glocke:
        let a: Double = sin(w * 1568 * t) * 0.6
        let b: Double = sin(w * 3136 * t) * 0.2
        let c: Double = sin(w * 4704 * t) * 0.08
        return exp(-t * 7) * (a + b + c)
    case .tropfen:
        let phase: Double = 350 * t + 1400 * t * t
        return exp(-t * 16) * sin(w * phase) * 0.8
    case .holz:
        return speechKnock(t) + speechKnock(t - 0.16)
    case .pfiff:
        let envelope: Double = min(1, min(t / 0.02, (0.32 - t) / 0.06))
        let freq: Double = t < 0.14 ? 660 : 880
        return envelope * sin(w * freq * t) * 0.5
    }
}

fileprivate func speechKnock(_ u: Double) -> Double {
    if u < 0 { return 0 }
    return exp(-u * 45) * sin(2 * Double.pi * 900 * u) * 0.8
}

/// 16-bit mono PCM WAV at 22050 Hz, with a 20 ms fade at the end.
fileprivate func speechToneWAV(_ kind: ToneKind) -> Data {
    let rate = 22050
    let length = speechToneLength(kind)
    let n = Int((Double(rate) * length).rounded())
    var bytes: [UInt8] = []
    bytes.reserveCapacity(44 + n * 2)
    func putText(_ s: String) {
        bytes.append(contentsOf: Array(s.utf8))
    }
    func put16(_ v: Int) {
        let x = UInt16(truncatingIfNeeded: v)
        bytes.append(UInt8(truncatingIfNeeded: x))
        bytes.append(UInt8(truncatingIfNeeded: x >> 8))
    }
    func put32(_ v: Int) {
        let x = UInt32(truncatingIfNeeded: v)
        bytes.append(UInt8(truncatingIfNeeded: x))
        bytes.append(UInt8(truncatingIfNeeded: x >> 8))
        bytes.append(UInt8(truncatingIfNeeded: x >> 16))
        bytes.append(UInt8(truncatingIfNeeded: x >> 24))
    }
    putText("RIFF"); put32(36 + n * 2); putText("WAVEfmt "); put32(16)
    put16(1); put16(1); put32(rate); put32(rate * 2)
    put16(2); put16(16); putText("data"); put32(n * 2)
    for k in 0..<n {
        let t = Double(k) / Double(rate)
        let fade: Double = min(1, (length - t) / 0.02)
        let v: Double = max(-1, min(1, speechToneValue(kind, t) * fade))
        put16(Int((v * 32767).rounded()))
    }
    return Data(bytes)
}

// MARK: - Listener

/// Listens itself (like keyboard dictation): partial results, ends after a short silence or 30 s.
@MainActor final class Listener: NSObject, ObservableObject {
    @Published private(set) var isListening: Bool = false
    /// No permission, not available or failed at once: the answer is typed (keyboard with its dictation key).
    @Published private(set) var blocked: Bool = false

    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var textHandler: ((String) -> Void)?
    private var endHandler: (() -> Void)?
    /// Grows with every start and stop; results of older sessions are ignored.
    private var generation = 0
    private var heardText = ""
    private var startTime = Date()
    private var lastChange = Date()
    /// Set when the audio has ended and only the last result is awaited.
    private var endingSince: Date?

    override init() {
        super.init()
    }

    /// onText gets the whole text recognised so far, each time it changes; onEnd once at the natural end
    /// (silence, 30 s, refusal or error), not after stop().
    func start(onText: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        stop()
        let gen = generation
        textHandler = onText
        endHandler = onEnd
        isListening = true
        Task { @MainActor [weak self] in
            let allowed = await listenerAskPermissions()
            guard let me = self, me.generation == gen else { return }
            if allowed {
                me.begin(gen)
            } else {
                me.fail(gen)
            }
        }
    }

    /// Stops at once; onEnd is not called.
    func stop() {
        if isListening || engine != nil || task != nil {
            teardown()
        } else {
            generation += 1
        }
    }

    // MARK: Session

    private func begin(_ gen: Int) {
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
        }
        guard let rec = recognizer, rec.isAvailable else {
            fail(gen)
            return
        }
        do {
            try SpeechAudio.useRecording()
        } catch {
            fail(gen)
            return
        }
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail(gen)
            return
        }
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        if rec.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        listenerInstallTap(input, format: format, request: newRequest)
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail(gen)
            return
        }
        engine = newEngine
        request = newRequest
        heardText = ""
        startTime = Date()
        lastChange = startTime
        endingSince = nil
        let report: @Sendable (String?, Bool, String?, Int) -> Void = { [weak self] text, isFinal, domain, code in
            guard let me = self else { return }
            Task { @MainActor in
                me.handle(gen, text: text, isFinal: isFinal, errorDomain: domain, errorCode: code)
            }
        }
        task = listenerRecognize(rec, request: newRequest, report: report)
        watch(gen)
    }

    private func handle(_ gen: Int, text: String?, isFinal: Bool, errorDomain: String?, errorCode: Int) {
        guard gen == generation, isListening else { return }
        if let t = text {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && clean != heardText {
                heardText = clean
                lastChange = Date()
                textHandler?(clean)
            }
        }
        // the text handler may have stopped listening
        guard gen == generation else { return }
        if isFinal {
            finish(gen)
            return
        }
        if let domain = errorDomain {
            // an error right at the start with nothing heard: listening does not work here
            let early = Date().timeIntervalSince(startTime) < 3
            if heardText.isEmpty && endingSince == nil && early && !listenerHarmless(domain: domain, code: errorCode) {
                fail(gen)
            } else {
                finish(gen)
            }
        }
    }

    /// Ends after ~2 s without new words (6 s while nothing was heard yet) or after 30 s.
    private func watch(_ gen: Int) {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let me = self, me.generation == gen, me.isListening else { return }
                let now = Date()
                if let since = me.endingSince {
                    // the last result did not come in time
                    if now.timeIntervalSince(since) > 1.5 {
                        me.finish(gen)
                        return
                    }
                    continue
                }
                let quiet = now.timeIntervalSince(me.lastChange)
                let total = now.timeIntervalSince(me.startTime)
                let silence: Double = me.heardText.isEmpty ? 6 : 2
                if total > 30 || quiet > silence {
                    me.wrapUp()
                }
            }
        }
    }

    /// Stops the microphone and waits briefly for the final (cleaned up) text.
    private func wrapUp() {
        guard endingSince == nil else { return }
        endingSince = Date()
        if let e = engine {
            e.stop()
            e.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
    }

    private func finish(_ gen: Int) {
        guard gen == generation else { return }
        let end = endHandler
        teardown()
        blocked = false
        end?()
    }

    private func fail(_ gen: Int) {
        guard gen == generation else { return }
        let end = endHandler
        teardown()
        blocked = true
        end?()
    }

    private func teardown() {
        generation += 1
        if let e = engine {
            e.stop()
            e.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        textHandler = nil
        endHandler = nil
        endingSince = nil
        if isListening { isListening = false }
        SpeechAudio.endRecording()
    }
}

// The closures below are made outside the main actor on purpose: the audio tap and the recognition
// results run on background threads.

/// Speech permission, then microphone permission (each system question appears only the first time).
fileprivate func listenerAskPermissions() async -> Bool {
    var status = SFSpeechRecognizer.authorizationStatus()
    if status == .notDetermined {
        status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { s in
                cont.resume(returning: s)
            }
        }
    }
    if status != .authorized { return false }
    let mic = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            cont.resume(returning: granted)
        }
    }
    return mic
}

fileprivate func listenerInstallTap(_ input: AVAudioInputNode, format: AVAudioFormat,
                                    request: SFSpeechAudioBufferRecognitionRequest) {
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
    }
}

fileprivate func listenerRecognize(_ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                   report: @escaping @Sendable (String?, Bool, String?, Int) -> Void) -> SFSpeechRecognitionTask {
    return recognizer.recognitionTask(with: request) { result, error in
        let text = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal ?? false
        var domain: String? = nil
        var code = 0
        if let ns = error as NSError? {
            domain = ns.domain
            code = ns.code
        }
        report(text, isFinal, domain, code)
    }
}

/// "No speech", "retry" and cancellations do not mean that listening is impossible.
fileprivate func listenerHarmless(domain: String, code: Int) -> Bool {
    if domain == "kAFAssistantErrorDomain" {
        return code == 203 || code == 216 || code == 1110
    }
    if domain == "kLSRErrorDomain" {
        return code == 301
    }
    return false
}
