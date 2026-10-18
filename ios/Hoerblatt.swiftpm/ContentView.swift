import SwiftUI
import PhotosUI

/// First step of the native Hörblatt: photo → words → tap a word or hear the sentence.
struct ContentView: View {
    @StateObject private var speaker = Speaker()
    @State private var image: UIImage?
    @State private var words: [Word] = []
    @State private var sentenceMode = false
    @State private var busy = false
    @State private var status = "Tippe auf die Kamera und fotografiere ein Arbeitsblatt."
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var lit: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            page
            tray
        }
        .background(Color(red: 0.93, green: 0.95, blue: 0.93))
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in
                showCamera = false
                if let img { Task { await process(img) } }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await process(img)
                }
                photoItem = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Hörblatt").font(.title2.bold())
            Spacer()
            Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    private var page: some View {
        GeometryReader { geo in
            if let image {
                let fit = fitRect(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                    ForEach(words) { w in
                        let r = CGRect(x: fit.minX + w.box.minX * fit.width, y: fit.minY + w.box.minY * fit.height,
                                       width: w.box.width * fit.width, height: w.box.height * fit.height)
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(lit.contains(w.id) ? Color.orange : Color.orange.opacity(0.45), lineWidth: lit.contains(w.id) ? 3 : 1)
                            .background(lit.contains(w.id) ? Color.orange.opacity(0.25) : Color.clear)
                            .frame(width: r.width + 6, height: r.height + 6)
                            .position(x: r.midX, y: r.midY)
                            .contentShape(Rectangle())
                            .onTapGesture { tapped(w) }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.viewfinder").font(.system(size: 72)).foregroundStyle(.teal)
                    Text("Noch kein Blatt").font(.title3)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .overlay { if busy { ProgressView("Ich lese das Blatt …").padding(24).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
    }

    private var tray: some View {
        HStack(spacing: 14) {
            Button { showCamera = true } label: { trayLabel("1", "camera.fill", .teal, on: false) }
            PhotosPicker(selection: $photoItem, matching: .images) { trayLabel("", "photo.on.rectangle", .gray, on: false) }
            Button { sentenceMode = false } label: { trayLabel("2", "hand.tap.fill", .orange, on: !sentenceMode) }
            Button { sentenceMode = true } label: { trayLabel("", "text.alignleft", .orange, on: sentenceMode) }
            Spacer()
            Text("\(words.count) Wörter").foregroundStyle(.secondary)
        }
        .padding(.horizontal).padding(.vertical, 12)
        .background(.white)
    }

    private func trayLabel(_ n: String, _ icon: String, _ color: Color, on: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(on ? color : color.opacity(0.15)).frame(width: 72, height: 64)
            Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(on ? .white : color)
                .frame(width: 72, height: 64)
            if !n.isEmpty { Text(n).font(.caption.bold()).foregroundStyle(on ? .white : color).padding(6) }
        }
    }

    private func fitRect(_ size: CGSize, in area: CGSize) -> CGRect {
        let s = min(area.width / size.width, area.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    private func tapped(_ w: Word) {
        let group = sentenceMode ? Sentences.around(words.firstIndex { $0.id == w.id } ?? 0, in: words) : [w]
        lit = Set(group.map(\.id))
        speaker.say(group.map(\.text).joined(separator: " "))
    }

    @MainActor
    private func process(_ img: UIImage) async {
        busy = true; status = "Ich lese das Blatt …"; words = []; lit = []
        image = img
        do {
            words = try await Reader.read(img)
            status = words.isEmpty ? "Ich konnte keine Schrift finden." : "Fertig. Tippe auf ein Wort."
            speaker.say(words.isEmpty ? "Ich konnte keine Schrift finden." : "Fertig. Tippe auf ein Wort.")
        } catch {
            status = "Das Lesen hat nicht geklappt: \(error.localizedDescription)"
        }
        busy = false
    }
}
