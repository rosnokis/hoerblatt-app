import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The main screen: header (Mappe, strip of recent pages, two pages, settings), one page or two side by side,
// the answer bar and the tool tray with the numbers and colours of the printed picture card.
// Big symbols, few words: the child cannot read, AppState speaks what matters.

struct ContentView: View {
    @ObservedObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    /// Measured on the whole window (not shrunk by the keyboard).
    @State private var landscape = false

    var body: some View {
        ZStack {
            // (the sheets hang on different views: SwiftUI keeps them apart more reliably)
            CVStyle.background
                .ignoresSafeArea()
                .sheet(isPresented: $app.showPhotoHelp) {
                    PhotoHelpView(onGo: {
                        app.showPhotoHelp = false
                        app.startScanner()
                    }, onCancel: {
                        app.showPhotoHelp = false
                        app.speaker.stop()
                    })
                }
                .sheet(isPresented: $app.showPicker) {
                    PhotoPicker(onFinish: { image in
                        app.picked(image)
                    })
                }
            VStack(spacing: 0) {
                CVHeader(app: app, landscape: landscape)
                pagesArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                CVBottomBar(app: app)
            }
            .sheet(isPresented: $app.showLibrary) {
                LibraryView(app: app)
            }
            .sheet(isPresented: $app.showSettings) {
                SettingsView(app: app)
            }
            // (the Dateien picker for a PDF hangs on a view of its own, like the sheets)
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .fileImporter(isPresented: $app.showPDFPicker, allowedContentTypes: [UTType.pdf]) { result in
                    app.pickedPDF(result)
                }
            if let c = app.active {
                WordLensHost(app: app, controller: c)
                    .id(c.id)
            }
            if let info = app.busy {
                CVBusyCard(info: info)
            }
            if let problem = app.photoProblem {
                PhotoProblemView(problem: problem, onAgain: {
                    app.resolvePhotoProblem(retake: true)
                }, onGoOn: {
                    app.resolvePhotoProblem(retake: false)
                })
            }
            if let info = app.pendingDelete {
                CVDeleteCard(app: app, info: info)
            }
        }
        .background(CVOrientationReader(landscape: $landscape))
        .sheet(isPresented: $app.showFinish) {
            if let image = app.finishImage {
                FinishView(app: app, image: image)
            }
        }
        .fullScreenCover(isPresented: $app.showScanner) {
            DocumentScanner(onFinish: { images in
                app.scanned(images)
            })
            .ignoresSafeArea()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                app.saveOpenPages(stopping: true)
            } else if phase == .inactive {
                app.saveOpenPages(stopping: false)
            }
        }
    }

    /// Two pages side by side only in landscape; upright with two pages on, the active half fills the screen.
    @ViewBuilder
    private var pagesArea: some View {
        if landscape && app.twoPages {
            HStack(spacing: 10) {
                CVPane(app: app, side: .left, both: true)
                CVPane(app: app, side: .right, both: true)
            }
            .padding(10)
        } else if app.twoPages {
            CVPane(app: app, side: app.activeSide, both: false)
        } else {
            CVPane(app: app, side: .left, both: false)
        }
    }
}

// MARK: - Pages

/// One half: the page, or (two pages) a placeholder to choose one, or (no page at all) the big camera button.
fileprivate struct CVPane: View {
    @ObservedObject var app: AppState
    let side: Side
    /// Two pages are shown side by side.
    let both: Bool

    var body: some View {
        let shown: PageController? = side == .left ? app.left : app.right
        if let c = shown {
            // (PageCanvas draws the teal frame of the active half itself)
            PageCanvas(controller: c, app: app, isActive: c === app.active, onActivate: {
                app.activate(side)
            })
            .id(c.id)
            .overlay(alignment: .bottom) {
                if let h = app.store.heft(containing: c.id), h.pageTotal > 1, let n = h.number(of: c.id) {
                    CVHeftBar(app: app, side: side, index: n, count: h.pageTotal,
                              reading: app.heftProgress?.heft == h.id)
                }
            }
        } else if app.twoPages {
            CVSidePlaceholder(app: app, side: side, lit: both && app.activeSide == side)
        } else {
            CVEmptyState(app: app)
        }
    }
}

/// Under a page of a Heft: big arrows to turn the page, and where in the Heft the page is ("3 / 8").
fileprivate struct CVHeftBar: View {
    @ObservedObject var app: AppState
    let side: Side
    let index: Int
    let count: Int
    /// Pages of this Heft are still being read in the background.
    let reading: Bool

    var body: some View {
        HStack(spacing: 18) {
            arrow("chevron.left", enabled: index > 0, caption: "Seite zurück", delta: -1)
            HStack(spacing: 8) {
                if reading {
                    ProgressView()
                        .tint(CVStyle.teal)
                } else {
                    Image(systemName: "book.fill")
                        .font(.system(size: 22, weight: .semibold))
                }
                Text("\(index + 1) / \(count)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundColor(CVStyle.teal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Seite \(index + 1) von \(count)"))
            arrow("chevron.right", enabled: index < count - 1, caption: "Seite weiter", delta: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.95)))
        .overlay(Capsule().stroke(CVStyle.teal.opacity(0.5), lineWidth: 2))
        .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
        .padding(.bottom, 12)
    }

    private func arrow(_ symbol: String, enabled: Bool, caption: String, delta: Int) -> some View {
        Button(action: {
            app.activate(side)
            app.turnPage(delta)
        }) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(.white)
                .frame(width: 68, height: 68)
                .background(Circle().fill(enabled ? CVStyle.teal : CVStyle.grey.opacity(0.35)))
        }
        .buttonStyle(CVPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(Text(caption))
    }
}

/// Empty half with two pages: opens the Mappe for this half.
fileprivate struct CVSidePlaceholder: View {
    @ObservedObject var app: AppState
    let side: Side
    /// The active half (teal frame).
    let lit: Bool

    var body: some View {
        Button(action: {
            app.activate(side)
            app.announce("Mappe")
            app.showLibrary = true
        }) {
            VStack(spacing: 18) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 130, height: 130)
                    .background(Circle().fill(CVStyle.teal))
                Text("Seite aus der Mappe wählen")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(CVStyle.slate)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(lit ? CVStyle.teal : CVStyle.slate.opacity(0.35),
                            style: StrokeStyle(lineWidth: lit ? 4 : 3, dash: lit ? [] : [10, 8]))
            )
        }
        .buttonStyle(CVPressStyle())
        .accessibilityLabel(Text("Seite aus der Mappe wählen"))
    }
}

/// No page open: the big camera button (and the Mappe, if it has pages).
fileprivate struct CVEmptyState: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            Button(action: {
                app.newPhoto()
            }) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 78, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 190, height: 190)
                    .background(Circle().fill(CVStyle.teal))
                    .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(CVPressStyle())
            .accessibilityLabel(Text("Foto machen"))
            Text("Foto vom Blatt machen")
                .font(.title2.weight(.semibold))
                .foregroundColor(CVStyle.slate)
            if !app.store.pages.isEmpty {
                Button(action: {
                    app.announce("Mappe")
                    app.showLibrary = true
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 30, weight: .semibold))
                        Text("Mappe")
                            .font(.title3.weight(.semibold))
                    }
                    .foregroundColor(CVStyle.teal)
                    .padding(.horizontal, 28)
                    .frame(height: 72)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().stroke(CVStyle.teal, lineWidth: 3))
                }
                .buttonStyle(CVPressStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header

fileprivate struct CVHeader: View {
    @ObservedObject var app: AppState
    let landscape: Bool

    var body: some View {
        HStack(spacing: 12) {
            CVSquareButton(symbol: "folder.fill", color: CVStyle.teal, filled: true, caption: "Mappe") {
                app.announce("Mappe")
                app.showLibrary = true
            }
            PageStrip(app: app)
                .frame(maxWidth: .infinity)
                .frame(height: 80)
            if landscape {
                CVSquareButton(symbol: "rectangle.split.2x1", color: CVStyle.teal, filled: app.twoPages,
                               caption: "Zwei Seiten nebeneinander") {
                    app.setTwoPages(!app.twoPages)
                }
            }
            CVSettingsKnob(app: app)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.9).ignoresSafeArea(edges: .top))
    }
}

/// Help and settings for teachers: opens only after pressing 1 s (a ring fills meanwhile).
fileprivate struct CVSettingsKnob: View {
    @ObservedObject var app: AppState
    @GestureState private var holding = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Circle()
                .stroke(CVStyle.slate.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: holding ? 1 : 0)
                .stroke(CVStyle.teal, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(holding ? Animation.linear(duration: 1) : Animation.easeOut(duration: 0.15), value: holding)
            Image(systemName: "gearshape")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(CVStyle.slate)
        }
        .frame(width: 56, height: 56)
        .contentShape(Circle())
        .gesture(
            LongPressGesture(minimumDuration: 1, maximumDistance: 30)
                .updating($holding) { pressing, state, _ in
                    state = pressing
                }
                .onEnded { _ in
                    app.showSettings = true
                }
        )
        .accessibilityLabel(Text("Hilfe und Einstellungen für Lehrkräfte, 1 Sekunde lang drücken"))
    }
}

// MARK: - Bottom: answer bar, colours, tools

fileprivate struct CVBottomBar: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 8) {
            if let c = app.active {
                CVAnswerBar(app: app, controller: c, listener: app.listener)
                    .id(c.id)
            }
            if app.mode == .markieren || app.mode == .stift {
                CVPalette(app: app)
            }
            CVToolTray(app: app)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.9).ignoresSafeArea(edges: .bottom))
    }
}

/// Bar of the open answer field, in screen size (not zoomed with the page).
fileprivate struct CVAnswerBar: View {
    @ObservedObject var app: AppState
    @ObservedObject var controller: PageController
    @ObservedObject var listener: Listener

    var body: some View {
        if let id = controller.activeAnswer {
            HStack(spacing: 32) {
                micButton(id)
                CVRoundButton(symbol: "speaker.wave.2.fill", color: CVStyle.lila, caption: "Antwort vorlesen") {
                    controller.speakAnswer(id)
                }
                CVRoundButton(symbol: "checkmark", color: CVStyle.green, caption: "Antwort fertig") {
                    done()
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(Capsule().fill(CVStyle.lila.opacity(0.1)))
        }
    }

    /// The app listens itself (teacher's setting), otherwise the keyboard with its dictation key. A blocked
    /// listener is tried again here: if it still fails, PageController opens the keyboard and says so.
    private var canListen: Bool {
        return app.settings.mic
    }

    @ViewBuilder
    private func micButton(_ id: UUID) -> some View {
        let listening = listener.isListening
        ZStack {
            if listening {
                CVPulseRing(color: CVStyle.red)
                    .frame(width: 80, height: 80)
            }
            CVRoundButton(symbol: canListen ? "mic.fill" : "keyboard",
                          color: listening ? CVStyle.red : CVStyle.lila,
                          caption: canListen ? "Nochmal sprechen" : "Tastatur") {
                mic(id)
            }
        }
    }

    private func mic(_ id: UUID) {
        if listener.isListening {
            // a second tap ends listening
            controller.stopListening()
            return
        }
        if canListen {
            controller.listen(id)
        } else {
            controller.keyboardAnswer = id
            app.say("Tippe auf das Mikrofon der Tastatur und sprich.")
        }
    }

    private func done() {
        controller.stopListening()
        controller.keyboardAnswer = nil
        // (an empty field goes away by itself)
        controller.activeAnswer = nil
        controller.save()
        cvHideKeyboard()
    }
}

/// Colour dots of the marker (4) or the pen (3), shown while that tool is in use.
fileprivate struct CVPalette: View {
    @ObservedObject var app: AppState

    var body: some View {
        HStack(spacing: 18) {
            if app.mode == .markieren {
                ForEach(MarkColor.allCases) { c in
                    CVColorDot(color: Color(uiColor: c.swatch), selected: app.settings.markColor == c, caption: c.title) {
                        app.settings.markColor = c
                        app.announce(c.title)
                    }
                }
            } else {
                ForEach(PenColor.allCases) { c in
                    CVColorDot(color: Color(uiColor: c.ink), selected: app.settings.penColor == c, caption: c.title) {
                        app.settings.penColor = c
                        app.announce(c.title)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().stroke((app.mode == .markieren ? CVStyle.amber : CVStyle.slate).opacity(0.4), lineWidth: 2))
    }
}

/// The tools as on the picture card: 1 Foto, 2 Wort + Satz, 3 Sprechen, 4 Markieren, Stift (no number),
/// Radiergummi, Zurück, 5 Fertig. Scrolls sideways only where the screen is too narrow.
fileprivate struct CVToolTray: View {
    @ObservedObject var app: AppState

    var body: some View {
        GeometryReader { g in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    CVToolButton(symbol: "camera.fill", color: CVStyle.teal, number: 1, filled: true, caption: "Foto") {
                        app.newPhoto()
                    }
                    HStack(spacing: 8) {
                        CVToolButton(symbol: "hand.tap.fill", color: CVStyle.orange, number: 2,
                                     filled: app.mode == .wort, caption: "Wort vorlesen") {
                            app.setMode(.wort)
                        }
                        CVToolButton(symbol: "text.alignleft", color: CVStyle.orange, number: nil,
                                     filled: app.mode == .satz, caption: "Satz vorlesen") {
                            app.setMode(.satz)
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 22).fill(CVStyle.orange.opacity(0.12)))
                    CVToolButton(symbol: "mic.fill", color: CVStyle.lila, number: 3,
                                 filled: app.mode == .sprechen, caption: "Antwort sprechen") {
                        app.setMode(.sprechen)
                    }
                    CVToolButton(symbol: "highlighter", color: CVStyle.amber, number: 4,
                                 filled: app.mode == .markieren, caption: "Markieren") {
                        app.setMode(.markieren)
                    }
                    CVToolButton(symbol: "pencil.tip", color: CVStyle.slate, number: nil,
                                 filled: app.mode == .stift, caption: "Stift") {
                        app.setMode(.stift)
                    }
                    HStack(spacing: 8) {
                        CVToolButton(symbol: "eraser.fill", color: CVStyle.grey, number: nil,
                                     filled: app.mode == .radieren, caption: "Radiergummi") {
                            app.setMode(.radieren)
                        }
                        CVToolButton(symbol: "arrow.uturn.backward", color: CVStyle.slate, number: nil,
                                     filled: false, caption: "Zurück") {
                            app.undo()
                        }
                    }
                    CVToolButton(symbol: "checkmark.square.fill", color: CVStyle.blue, number: 5, filled: true,
                                 caption: "Fertig") {
                        app.finish()
                    }
                }
                .padding(.horizontal, 14)
                .frame(minWidth: g.size.width, minHeight: g.size.height)
            }
        }
        .frame(height: 92)
    }
}

// MARK: - Overlays

/// Waiting screen while a photo is read: ring with percent and what is happening.
fileprivate struct CVBusyCard: View {
    let info: BusyInfo

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(CVStyle.teal.opacity(0.18), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.02, min(1, info.progress))))
                        .stroke(CVStyle.teal, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: info.progress)
                    Text("\(Int((info.progress * 100).rounded())) %")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(CVStyle.ink)
                }
                .frame(width: 140, height: 140)
                Text(info.message)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(CVStyle.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(32)
            .frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.white))
            .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 8)
            .padding(20)
        }
    }
}

/// "Diese Seite löschen?" with the page's picture, a big red bin and a green arrow back.
fileprivate struct CVDeleteCard: View {
    @ObservedObject var app: AppState
    let info: PageInfo

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                picture
                Text(app.store.heft(info.id) != nil ? "Dieses Heft löschen?" : "Diese Seite löschen?")
                    .font(.title2.weight(.bold))
                    .foregroundColor(CVStyle.ink)
                    .multilineTextAlignment(.center)
                if !info.title.isEmpty {
                    Text(info.title)
                        .font(.headline)
                        .foregroundColor(CVStyle.slate)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 56) {
                    CVRoundButton(symbol: "arrow.uturn.backward", color: CVStyle.green, caption: "Nein, behalten",
                                  size: 104) {
                        app.confirmDelete(false)
                    }
                    CVRoundButton(symbol: "trash.fill", color: CVStyle.red, caption: "Ja, löschen", size: 104) {
                        app.confirmDelete(true)
                    }
                }
                .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: 500)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.white))
            .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 8)
            .padding(20)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let thumb = app.store.thumbnail(info.id) {
            Image(uiImage: thumb)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.12), lineWidth: 1))
        } else {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 80))
                .foregroundColor(CVStyle.slate)
        }
    }
}

// MARK: - Building blocks

/// Big tool button with the small number of the picture card in the top left corner.
fileprivate struct CVToolButton: View {
    let symbol: String
    let color: Color
    let number: Int?
    /// The tool in use, or an action that is always coloured (Foto, Fertig).
    let filled: Bool
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(filled ? color : Color.white)
                RoundedRectangle(cornerRadius: 18)
                    .stroke(color, lineWidth: 3)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(filled ? Color.white : color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let n = number {
                    Text(String(n))
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(filled ? color : Color.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(filled ? Color.white : color))
                        .padding(5)
                }
            }
            .frame(width: 70, height: 70)
            .shadow(color: Color.black.opacity(filled ? 0.18 : 0.06), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(CVPressStyle())
        .accessibilityLabel(Text(caption))
    }
}

fileprivate struct CVSquareButton: View {
    let symbol: String
    let color: Color
    let filled: Bool
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(filled ? Color.white : color)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16).fill(filled ? color : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(color, lineWidth: 3))
        }
        .buttonStyle(CVPressStyle())
        .accessibilityLabel(Text(caption))
    }
}

fileprivate struct CVRoundButton: View {
    let symbol: String
    let color: Color
    let caption: String
    var size: CGFloat = 80
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(color))
                .shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 3)
        }
        .buttonStyle(CVPressStyle())
        .accessibilityLabel(Text(caption))
    }
}

fileprivate struct CVColorDot: View {
    let color: Color
    let selected: Bool
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                Circle()
                    .stroke(selected ? CVStyle.ink : Color.black.opacity(0.15), lineWidth: selected ? 4 : 1.5)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.5), radius: 1, x: 0, y: 1)
                }
            }
            .frame(width: 54, height: 54)
        }
        .buttonStyle(CVPressStyle())
        .accessibilityLabel(Text(caption))
    }
}

/// Ring that keeps growing and fading while the app listens.
fileprivate struct CVPulseRing: View {
    let color: Color
    @State private var grown = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 6)
            .scaleEffect(grown ? 1.45 : 1)
            .opacity(grown ? 0 : 0.9)
            .onAppear {
                withAnimation(Animation.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    grown = true
                }
            }
    }
}

/// Shrinks a little while pressed, so a tap is felt without changing the colours.
fileprivate struct CVPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Landscape = the window is wider than high, measured without the keyboard (typing must not switch layouts).
fileprivate struct CVOrientationReader: View {
    @Binding var landscape: Bool

    var body: some View {
        GeometryReader { g in
            Color.clear
                .onChange(of: g.size, initial: true) { _, size in
                    let wide = size.width > size.height
                    if wide != landscape { landscape = wide }
                }
        }
        .ignoresSafeArea()
    }
}

/// Colours of the picture card (ARCHITEKTUR.md); fixed, so the screen looks the same in dark mode.
fileprivate enum CVStyle {
    static let teal = Color(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255)
    static let orange = Color(red: 234.0 / 255, green: 88.0 / 255, blue: 12.0 / 255)
    static let lila = Color(red: 124.0 / 255, green: 58.0 / 255, blue: 237.0 / 255)
    static let amber = Color(red: 217.0 / 255, green: 119.0 / 255, blue: 6.0 / 255)
    static let slate = Color(red: 71.0 / 255, green: 85.0 / 255, blue: 105.0 / 255)
    static let blue = Color(red: 37.0 / 255, green: 99.0 / 255, blue: 235.0 / 255)
    static let grey = Color(red: 100.0 / 255, green: 116.0 / 255, blue: 139.0 / 255)
    static let red = Color(red: 220.0 / 255, green: 38.0 / 255, blue: 38.0 / 255)
    static let green = Color(red: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255)
    static let ink = Color(red: 30.0 / 255, green: 41.0 / 255, blue: 59.0 / 255)
    static let background = Color(red: 238.0 / 255, green: 241.0 / 255, blue: 236.0 / 255)
}

@MainActor fileprivate func cvHideKeyboard() {
    _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
