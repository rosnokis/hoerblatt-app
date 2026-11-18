import SwiftUI

// Führung fürs Kind (das nicht lesen kann): the yellow "?" in the header starts it. Everything is spoken; the screen
// goes dark except the tool that is meant, which pulses with a yellow ring and a pointing hand. Steps: hello → Wort →
// Satz → Sprechen (lila gaps) → Fertig/Abgeben → "?" for next time; tools the teacher has hidden are left out.
// The next step comes by itself after the voice has finished; big round buttons: ✕ stop, speaker = once more,
// green arrow = next. Same content as the printed picture guide (anleitung/).

/// The places the tour points at (their frames come from the views via `tourTarget`).
enum TourTarget: Hashable {
    case wort, satz, sprechen, fertig, hilfe
}

struct TourFrames: PreferenceKey {
    static var defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as a place the tour can point at.
    func tourTarget(_ t: TourTarget) -> some View {
        anchorPreference(key: TourFrames.self, value: .bounds) { [t: $0] }
    }
}

struct TourStep {
    /// nil: no tool, a big picture in the middle (hello, the end).
    let target: TourTarget?
    let symbol: String
    let text: String
}

/// The steps for the tools that are shown.
func tourSteps(_ s: AppSettings) -> [TourStep] {
    var out = [TourStep(target: nil, symbol: "hand.wave.fill",
                        text: "Hallo! Ich zeige dir, wie das Hörblatt geht. Schau, wo es leuchtet, und hör gut zu.")]
    out.append(TourStep(target: .wort, symbol: "hand.tap.fill",
                        text: "Das ist der orange Knopf mit der Hand. Tippe auf ihn. Dann tippe auf ein Wort. Ich lese dir das Wort vor."))
    if s.shows(.satz) {
        out.append(TourStep(target: .satz, symbol: "text.alignleft",
                            text: "Das ist der Knopf mit den Zeilen. Tippe auf ihn. Dann tippe auf ein Wort. Ich lese dir den ganzen Satz vor."))
    }
    if s.shows(.sprechen) {
        out.append(TourStep(target: .sprechen, symbol: "mic.fill",
                            text: "Auf dem Blatt sind lila Stellen. Das sind Lücken für deine Antwort. Tippe auf eine lila Lücke. Wenn es Pling macht, sprich deine Antwort. Ich schreibe sie für dich auf."))
    }
    if s.shows(.fertig) {
        out.append(TourStep(target: .fertig, symbol: "checkmark.square.fill",
                            text: "Das ist der blaue Knopf mit dem Haken. Tippe auf ihn, wenn du fertig bist. Zeig das Bild deiner Lehrerin oder deinem Lehrer. Dann tippe auf den Daumen und auf Abgeben."))
    }
    if s.shows(.hilfe) {
        out.append(TourStep(target: .hilfe, symbol: "questionmark",
                            text: "Willst du das noch einmal hören? Dann tippe auf das gelbe Fragezeichen."))
    }
    out.append(TourStep(target: nil, symbol: "hand.thumbsup.fill", text: "Jetzt kannst du loslegen. Viel Spaß!"))
    return out
}

@MainActor final class Tour: ObservableObject {
    /// The step shown; nil: no tour.
    @Published private(set) var index: Int? = nil
    private(set) var steps: [TourStep] = []
    private weak var app: AppState?
    /// Each new step or stop makes older "speech ended" callbacks void.
    private var token = 0

    var step: TourStep? {
        guard let i = index, i < steps.count else { return nil }
        return steps[i]
    }

    func start(_ app: AppState) {
        self.app = app
        steps = tourSteps(app.settings)
        index = 0
        play()
    }

    func next() {
        guard let i = index else { return }
        if i + 1 < steps.count {
            index = i + 1
            play()
        } else {
            stop()
        }
    }

    func again() {
        play()
    }

    func stop() {
        token += 1
        index = nil
        app?.speaker.stop()
    }

    private func play() {
        guard let s = step, let app = app else { return }
        token += 1
        let t = token
        app.say(s.text) { [weak self] in
            // (a short breath, then the next step comes by itself)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let self = self, self.token == t else { return }
                self.next()
            }
        }
    }
}

/// The dark screen with the lit tool, the hand and the three round buttons.
struct TourOverlay: View {
    @ObservedObject var tour: Tour
    let anchors: [TourTarget: Anchor<CGRect>]
    @State private var pulse = false

    var body: some View {
        if let step = tour.step, let i = tour.index {
            GeometryReader { g in
                let full = CGRect(origin: .zero, size: g.size)
                let lit = step.target.flatMap { anchors[$0] }.map { g[$0].insetBy(dx: -12, dy: -12) }
                ZStack {
                    Path { p in
                        p.addRect(full)
                        if let r = lit { p.addRoundedRect(in: r, cornerSize: CGSize(width: 26, height: 26)) }
                    }
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    // (taps on the dark part do nothing: the child stays in the tour until it ends or ✕)
                    .contentShape(Rectangle())
                    .onTapGesture {}

                    if let r = lit {
                        RoundedRectangle(cornerRadius: 26)
                            .stroke(TourStyle.yellow, lineWidth: 7)
                            .frame(width: r.width, height: r.height)
                            .scaleEffect(pulse ? 1.12 : 1)
                            .position(x: r.midX, y: r.midY)
                            .allowsHitTesting(false)
                        // the hand points at the tool from the middle of the screen
                        let below = r.midY < g.size.height / 2
                        Image(systemName: below ? "hand.point.up.fill" : "hand.point.down.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .position(x: r.midX, y: below ? r.maxY + 52 + (pulse ? 10 : 0) : r.minY - 52 - (pulse ? 10 : 0))
                            .allowsHitTesting(false)
                    } else {
                        Image(systemName: step.symbol)
                            .font(.system(size: 110, weight: .bold))
                            .foregroundColor(TourStyle.yellow)
                            .scaleEffect(pulse ? 1.08 : 1)
                            .position(x: g.size.width / 2, y: g.size.height * 0.32)
                            .allowsHitTesting(false)
                    }

                    VStack(spacing: 18) {
                        HStack(spacing: 10) {
                            ForEach(0..<tour.steps.count, id: \.self) { k in
                                Circle()
                                    .fill(k == i ? TourStyle.yellow : Color.white.opacity(0.45))
                                    .frame(width: k == i ? 18 : 12, height: k == i ? 18 : 12)
                            }
                        }
                        HStack(spacing: 34) {
                            TourRound(symbol: "xmark", color: TourStyle.red, label: "Führung beenden") { tour.stop() }
                            TourRound(symbol: "speaker.wave.2.fill", color: TourStyle.yellow, label: "Noch einmal hören") {
                                tour.again()
                            }
                            TourRound(symbol: "arrow.right", color: TourStyle.green, label: "Weiter") { tour.next() }
                        }
                    }
                    .position(x: g.size.width / 2, y: g.size.height * 0.56)
                }
            }
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            }
            .onDisappear { pulse = false }
            .transition(.opacity)
        }
    }
}

private struct TourRound: View {
    let symbol: String
    let color: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(color == TourStyle.yellow ? Color.black : Color.white)
                .frame(width: 92, height: 92)
                .background(Circle().fill(color))
                .overlay(Circle().stroke(Color.white, lineWidth: 4))
        }
        .accessibilityLabel(Text(label))
    }
}

enum TourStyle {
    static let yellow = Color(red: 250.0 / 255, green: 204.0 / 255, blue: 21.0 / 255)
    static let green = Color(red: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255)
    static let red = Color(red: 220.0 / 255, green: 38.0 / 255, blue: 38.0 / 255)
}
