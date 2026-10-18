import AVFoundation
import Combine

/// Reads aloud with the German system voice.
final class Speaker: ObservableObject {
    private let synth = AVSpeechSynthesizer()
    @Published var rate: Float = 0.42

    func say(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "de-DE")
        u.rate = rate
        synth.speak(u)
    }
}
