import SwiftUI
import UIKit
import VisionKit
import PhotosUI
import CoreGraphics
import CoreImage

// Taking the photo: the document camera (finds the sheet, pulls it straight, takes the picture itself), the photo
// library for tests, the short picture guide before the camera, and the check afterwards (too dark, shaken).
// The child does this alone and cannot read: big symbols, the words are spoken by AppState, not here.

// MARK: - Camera and photo library

/// Document camera (VisionKit). Every scanned page becomes a page of its own. `[]` when cancelled or failed.
/// It does not close itself: the presenter closes it in `onFinish`.
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void

    /// false where the document camera cannot run (no camera, simulator).
    @MainActor static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var onFinish: ([UIImage]) -> Void
        /// The camera may report twice (e.g. a failure while closing): answer once only.
        private var done = false

        init(onFinish: @escaping ([UIImage]) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for i in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: i))
            }
            finish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            finish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            finish([])
        }

        private func finish(_ images: [UIImage]) {
            if done { return }
            done = true
            onFinish(images)
        }
    }
}

/// Photo library (one picture), mainly for testing with existing photos. `nil` when cancelled.
/// It does not close itself: the presenter closes it in `onFinish`.
struct PhotoPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // taken here on the main thread; the picture itself arrives on a background thread
            let finish = onFinish
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                finish(nil)
                return
            }
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async {
                    finish(image)
                }
            }
        }
    }
}

// MARK: - Picture guide before the camera

/// "So wird das Foto gut": three picture tiles and a big camera button. AppState speaks the guide.
struct PhotoHelpView: View {
    var onGo: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(CapStyle.slate)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(CapPressStyle())
                    .accessibilityLabel(Text("Abbrechen"))
                }
                Text("So wird das Foto gut")
                    .font(.title.weight(.bold))
                    .foregroundColor(CapStyle.ink)
                    .multilineTextAlignment(.center)
                HStack(alignment: .top, spacing: 14) {
                    CapHelpTile(number: 1, caption: "Heft flach hinlegen") {
                        CapFlatSheetPicture()
                    }
                    CapHelpTile(number: 2, caption: "iPad gerade darüber") {
                        CapAboveSheetPicture()
                    }
                    CapHelpTile(number: 3, caption: "Ganzes Blatt aufs Foto") {
                        CapWholeSheetPicture()
                    }
                }
                Text("Leg das Heft flach hin. Halte das iPad gerade darüber. Das ganze Blatt muss auf das Foto.")
                    .font(.title3)
                    .foregroundColor(CapStyle.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onGo) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 132, height: 132)
                        .background(Circle().fill(CapStyle.teal))
                        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(CapPressStyle())
                .accessibilityLabel(Text("Foto machen"))
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(CapStyle.background.ignoresSafeArea())
    }
}

/// One step of the guide: number, picture, short caption (for adults; the child looks at the picture).
fileprivate struct CapHelpTile<Content: View>: View {
    let number: Int
    let caption: String
    let picture: Content

    init(number: Int, caption: String, @ViewBuilder picture: () -> Content) {
        self.number = number
        self.caption = caption
        self.picture = picture()
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                picture
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                Text("\(number)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(CapStyle.teal))
                    .padding(8)
            }
            Text(caption)
                .font(.callout)
                .foregroundColor(CapStyle.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white))
    }
}

/// The sheet lying flat on the table.
fileprivate struct CapFlatSheetPicture: View {
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 70))
                .foregroundColor(CapStyle.teal)
                .rotation3DEffect(.degrees(58), axis: (x: 1, y: 0, z: 0))
            Capsule()
                .fill(CapStyle.table)
                .frame(width: 120, height: 8)
        }
    }
}

/// The iPad held flat above the sheet, both lying the same way.
fileprivate struct CapAboveSheetPicture: View {
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "ipad.landscape")
                .font(.system(size: 48))
                .foregroundColor(CapStyle.slate)
                .rotation3DEffect(.degrees(58), axis: (x: 1, y: 0, z: 0))
            Image(systemName: "arrow.down")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(CapStyle.teal)
            Image(systemName: "doc.text.fill")
                .font(.system(size: 44))
                .foregroundColor(CapStyle.teal)
                .rotation3DEffect(.degrees(58), axis: (x: 1, y: 0, z: 0))
            Capsule()
                .fill(CapStyle.table)
                .frame(width: 90, height: 6)
        }
    }
}

/// The whole sheet inside the camera frame.
fileprivate struct CapWholeSheetPicture: View {
    var body: some View {
        ZStack {
            Image(systemName: "viewfinder")
                .font(.system(size: 104, weight: .light))
                .foregroundColor(CapStyle.slate)
            Image(systemName: "doc.text.fill")
                .font(.system(size: 50))
                .foregroundColor(CapStyle.teal)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(CapStyle.green)
                .background(Circle().fill(Color.white))
                .offset(x: 46, y: 46)
        }
    }
}

// MARK: - Check after the photo

/// What is wrong with a photo. The texts are also spoken (by AppState).
enum PhotoProblem: String, Identifiable {
    case dark, blurry, fewWords

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Das Foto ist zu dunkel."
        case .blurry: return "Das Foto ist verwackelt."
        case .fewWords: return "Ich kann kaum etwas lesen."
        }
    }

    var message: String {
        switch self {
        case .dark: return "Mach mehr Licht an oder geh näher ans Fenster."
        case .blurry: return "Halte das iPad ganz ruhig."
        case .fewWords: return "Das Blatt muss groß, hell und gerade auf dem Foto sein."
        }
    }

    /// SF Symbol for the problem card.
    var symbol: String {
        switch self {
        case .dark: return "lightbulb.fill"
        case .blurry: return "hand.raised.fill"
        case .fewWords: return "doc.text.magnifyingglass"
        }
    }
}

/// Too dark or shaken, measured like photoQuality in index.html. `.fewWords` is decided after the recognition.
enum PhotoCheck {
    static func check(_ image: UIImage) -> PhotoProblem? {
        guard let m = measure(image) else { return nil }
        if m.paper < 110 { return .dark }
        if m.sharpness < 80 { return .blurry }
        return nil
    }

    /// paper: mean brightness of the brighter half of the pixels; sharpness: spread of the Laplace filter.
    /// Good photos of the test pages: paper ≥ 170, sharpness ≥ 400; darkened ≈ 65, blurred ≈ 5.
    /// Measured on a grey copy with the long side 1000 px (every 2nd pixel), the size the limits were found with.
    static func measure(_ image: UIImage) -> (paper: Double, sharpness: Double)? {
        guard let cg = capCGImage(image) else { return nil }
        let sw = Double(cg.width), sh = Double(cg.height)
        guard sw >= 3, sh >= 3 else { return nil }
        let s = 1000 / max(sw, sh)
        let w = max(3, Int((sw * s).rounded()))
        let h = max(3, Int((sh * s).rounded()))
        var px = [UInt8](repeating: 255, count: w * h)
        // orientation does not matter for either value, so the pixels are drawn as stored
        let ok: Bool = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var hist = [Int](repeating: 0, count: 256)
        var m = 0
        var q = 0
        var k = 0
        px.withUnsafeBufferPointer { v in
            for i in 0..<(w * h) { hist[Int(v[i])] += 1 }
            var y = 1
            while y < h - 1 {
                var x = 1
                while x < w - 1 {
                    let i = y * w + x
                    let l = 4 * Int(v[i]) - Int(v[i - 1]) - Int(v[i + 1]) - Int(v[i - w]) - Int(v[i + w])
                    m += l
                    q += l * l
                    k += 1
                    x += 2
                }
                y += 2
            }
        }
        // paper = the brighter half of the pixels (ink and shadows are the darker part)
        let half = (w * h) / 2
        var n = 0
        var sum = 0
        var t = 255
        while t >= 0 && n < half {
            let c = min(hist[t], half - n)
            n += c
            sum += c * t
            t -= 1
        }
        let paper = n > 0 ? Double(sum) / Double(n) : 0
        let mean = Double(m) / Double(max(1, k))
        let sharpness = Double(q) / Double(max(1, k)) - mean * mean
        return (paper: paper, sharpness: sharpness)
    }
}

fileprivate func capCGImage(_ image: UIImage) -> CGImage? {
    if let cg = image.cgImage { return cg }
    if let ci = image.ciImage, !ci.extent.isInfinite, !ci.extent.isEmpty {
        return CIContext(options: nil).createCGImage(ci, from: ci.extent)
    }
    return nil
}

/// The question after a bad photo: "Nochmal" (camera, teal) or "Weiter" (arrow, grey). Covers the screen with a
/// dimmed backdrop, so it is meant as an overlay. AppState speaks the texts.
struct PhotoProblemView: View {
    var problem: PhotoProblem
    var onAgain: () -> Void
    var onGoOn: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: problem.symbol)
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundColor(CapStyle.amber)
                    .frame(width: 124, height: 124)
                    .background(Circle().fill(CapStyle.amber.opacity(0.15)))
                Text(problem.title)
                    .font(.title2.weight(.bold))
                    .foregroundColor(CapStyle.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(problem.message)
                    .font(.title3)
                    .foregroundColor(CapStyle.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 40) {
                    CapRoundButton(symbol: "camera.fill", color: CapStyle.teal, caption: "Nochmal", action: onAgain)
                    CapRoundButton(symbol: "arrow.right", color: CapStyle.grey, caption: "Weiter", action: onGoOn)
                }
                .padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.white))
            .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 8)
            .padding(20)
        }
    }
}

/// Big round symbol button with a small caption underneath (for adults).
fileprivate struct CapRoundButton: View {
    let symbol: String
    let color: Color
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(color))
                Text(caption)
                    .font(.headline)
                    .foregroundColor(CapStyle.slate)
            }
        }
        .buttonStyle(CapPressStyle())
        .accessibilityLabel(Text(caption))
    }
}

/// Shrinks a little while pressed, so a tap is felt without tinting the colours.
fileprivate struct CapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Colours of the app (ARCHITEKTUR.md); fixed, so the cards look the same in dark mode.
fileprivate enum CapStyle {
    static let teal = Color(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255)
    static let slate = Color(red: 71.0 / 255, green: 85.0 / 255, blue: 105.0 / 255)
    static let grey = Color(red: 100.0 / 255, green: 116.0 / 255, blue: 139.0 / 255)
    static let amber = Color(red: 217.0 / 255, green: 119.0 / 255, blue: 6.0 / 255)
    static let ink = Color(red: 30.0 / 255, green: 41.0 / 255, blue: 59.0 / 255)
    static let green = Color(red: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255)
    static let table = Color(red: 180.0 / 255, green: 150.0 / 255, blue: 110.0 / 255)
    static let background = Color(red: 238.0 / 255, green: 241.0 / 255, blue: 236.0 / 255)
}
