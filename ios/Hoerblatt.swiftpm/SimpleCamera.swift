import SwiftUI
import UIKit
import AVFoundation
import AudioToolbox
import Vision
import CoreImage

// The Hörblatt's own camera, made for a child who cannot read: the live picture fills the screen, the sheet is
// outlined as soon as it is seen, and once it is held still for a moment the photo is taken by itself. A big round
// button takes it at any time; a big cross closes. No "Keep"/"Save": one photo, then the camera closes. The photo is
// pulled straight onto the sheet's corners (perspective correction). Spoken hints come from AppState (`say`).
// Apple's document camera stays available as a setting (AppSettings.appleCamera).

struct SimpleCamera: UIViewControllerRepresentable {
    var say: (String) -> Void
    var onFinish: ([UIImage]) -> Void

    /// false where there is no back camera (simulator).
    @MainActor static var isAvailable: Bool {
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    func makeUIViewController(context: Context) -> SimpleCameraController {
        return SimpleCameraController(say: say, onFinish: onFinish)
    }

    func updateUIViewController(_ controller: SimpleCameraController, context: Context) {
        controller.say = say
        controller.onFinish = onFinish
    }
}

final class SimpleCameraController: UIViewController {
    var say: (String) -> Void
    var onFinish: ([UIImage]) -> Void

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let worker = SimpleCameraWorker()
    private let sessionQueue = DispatchQueue(label: "hoerblatt.camera.session")
    private let frameQueue = DispatchQueue(label: "hoerblatt.camera.frames")
    private var preview: AVCaptureVideoPreviewLayer? = nil
    private var rotation: AVCaptureDevice.RotationCoordinator? = nil
    private let outline = CAShapeLayer()
    private let shutter = UIButton(type: .custom)
    private let closeButton = UIButton(type: .system)
    private let flash = UIView()

    /// The sheet as last seen (capture-device points, 0…1, top-left origin) and since when it has stood still.
    private var lastQuad: [CGPoint]? = nil
    private var stillSince: Date? = nil
    private var taking = false
    private var finished = false
    private var lastSeen = Date()
    private var lastHint = Date()

    init(say: @escaping (String) -> Void, onFinish: @escaping ([UIImage]) -> Void) {
        self.say = say
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setUpButtons()
        worker.onQuad = { [weak self] quad in
            self?.sheetSeen(quad)
        }
        worker.onPhoto = { [weak self] data in
            self?.photoTaken(data)
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor [weak self] in
                    if ok {
                        self?.startCamera()
                    } else {
                        self?.cameraBlocked()
                    }
                }
            }
        default:
            cameraBlocked()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lastSeen = Date()
        lastHint = Date()
        say("Halte das iPad über das Blatt. Ich mache das Foto von selbst.")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        outline.frame = view.bounds
        flash.frame = view.bounds
        let safe = view.safeAreaInsets
        let size: CGFloat = 112
        shutter.frame = CGRect(x: (view.bounds.width - size) / 2, y: view.bounds.height - safe.bottom - size - 28,
                               width: size, height: size)
        closeButton.frame = CGRect(x: safe.left + 20, y: safe.top + 20, width: 72, height: 72)
        turnPreview()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Camera

    private func startCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            cameraBlocked()
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(worker, queue: frameQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        // frames in the sensor's own orientation: the sheet's corners are capture-device points then
        if let c = videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(0) {
            c.videoRotationAngle = 0
        }
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        outline.fillColor = UIColor(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255, alpha: 0.18).cgColor
        outline.strokeColor = UIColor(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255, alpha: 1).cgColor
        outline.lineWidth = 6
        outline.lineJoin = .round
        view.layer.insertSublayer(outline, above: layer)
        turnPreview()

        let session = self.session
        sessionQueue.async {
            session.startRunning()
        }
    }

    /// The picture stands the way the iPad is held.
    private func turnPreview() {
        guard let rc = rotation else { return }
        let angle = rc.videoRotationAngleForHorizonLevelPreview
        if let c = preview?.connection, c.isVideoRotationAngleSupported(angle), c.videoRotationAngle != angle {
            c.videoRotationAngle = angle
        }
    }

    private func cameraBlocked() {
        say("Die Kamera ist ausgeschaltet. Frag bitte deine Lehrkraft.")
        finish([])
    }

    // MARK: - The sheet in the live picture

    private func sheetSeen(_ quad: [CGPoint]?) {
        if taking || finished { return }
        turnPreview()
        guard let q = quad, simpleCameraArea(q) > 0.2, let layer = preview else {
            outline.path = nil
            lastQuad = nil
            stillSince = nil
            // no sheet for a while: say again what to do (not too often)
            if Date().timeIntervalSince(lastSeen) > 7 && Date().timeIntervalSince(lastHint) > 9 {
                lastHint = Date()
                say("Ich sehe das Blatt noch nicht. Halte das iPad ein bisschen höher, gerade über das Blatt.")
            }
            return
        }
        lastSeen = Date()
        let path = UIBezierPath()
        for (i, p) in q.enumerated() {
            let v = layer.layerPointConverted(fromCaptureDevicePoint: p)
            if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
        }
        path.close()
        outline.path = path.cgPath

        if let last = lastQuad, simpleCameraMoved(last, q) < 0.02 {
            if stillSince == nil { stillSince = Date() }
        } else {
            stillSince = nil
        }
        lastQuad = q
        // green while it stands still; the photo comes after a little more than a second
        let still = stillSince != nil
        outline.strokeColor = (still ? UIColor(red: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255, alpha: 1)
                                     : UIColor(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255, alpha: 1)).cgColor
        if let s = stillSince, Date().timeIntervalSince(s) > 1.2 {
            takePhoto()
        }
    }

    // MARK: - Taking the photo

    @objc private func shutterTapped() {
        takePhoto()
    }

    @objc private func closeTapped() {
        finish([])
    }

    private func takePhoto() {
        if taking || finished || preview == nil { return }
        taking = true
        if let rc = rotation, let c = photoOutput.connection(with: .video) {
            let angle = rc.videoRotationAngleForHorizonLevelCapture
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: worker)
        // shutter sound and a white flash: the child knows the photo is taken
        AudioServicesPlaySystemSound(1108)
        flash.alpha = 0.9
        UIView.animate(withDuration: 0.35) {
            self.flash.alpha = 0
        }
    }

    private func photoTaken(_ data: Data?) {
        guard let d = data else {
            // (no picture: try again)
            taking = false
            stillSince = nil
            return
        }
        say("Foto ist gemacht.")
        shutter.isEnabled = false
        Task.detached(priority: .userInitiated) {
            let image = simpleCameraStraighten(d)
            await MainActor.run { [weak self] in
                self?.finish(image.map { [$0] } ?? [])
            }
        }
    }

    private func finish(_ images: [UIImage]) {
        if finished { return }
        finished = true
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        onFinish(images)
    }

    // MARK: - Buttons

    private func setUpButtons() {
        flash.backgroundColor = .white
        flash.alpha = 0
        flash.isUserInteractionEnabled = false
        view.addSubview(flash)

        // a big white ring with a white disc, like the camera app
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 56
        shutter.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
        shutter.layer.borderWidth = 8
        shutter.accessibilityLabel = "Foto machen"
        shutter.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        view.addSubview(shutter)

        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
        closeButton.layer.cornerRadius = 36
        closeButton.accessibilityLabel = "Schließen"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
    }
}

/// Frame and photo callbacks on the camera's own queues; results are handed to the main thread.
final class SimpleCameraWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    var onQuad: (([CGPoint]?) -> Void)? = nil
    var onPhoto: ((Data?) -> Void)? = nil
    private var lastRun: CFTimeInterval = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // about seven times a second is plenty
        let now = CACurrentMediaTime()
        if now - lastRun < 0.14 { return }
        lastRun = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = simpleCameraRectangleRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        try? handler.perform([request])
        var quad: [CGPoint]? = nil
        if let r = request.results?.first {
            // Vision: 0…1 with the origin bottom-left → capture-device points: origin top-left
            quad = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
        }
        let callback = onQuad
        DispatchQueue.main.async {
            callback?(quad)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let callback = onPhoto
        DispatchQueue.main.async {
            callback?(data)
        }
    }
}

// MARK: - Helpers (no actor state)

fileprivate func simpleCameraRectangleRequest() -> VNDetectRectanglesRequest {
    let r = VNDetectRectanglesRequest()
    r.maximumObservations = 1
    r.minimumConfidence = 0.6
    r.minimumAspectRatio = 0.3
    r.maximumAspectRatio = 1.0
    r.minimumSize = 0.3
    r.quadratureTolerance = 30
    return r
}

/// Area of the quadrilateral (0…1 coordinates): how much of the picture the sheet fills.
fileprivate func simpleCameraArea(_ q: [CGPoint]) -> CGFloat {
    guard q.count == 4 else { return 0 }
    var s: CGFloat = 0
    for i in 0..<4 {
        let a = q[i], b = q[(i + 1) % 4]
        s += a.x * b.y - b.x * a.y
    }
    return abs(s) / 2
}

/// How far the corners moved between two frames (largest corner distance, 0…1).
fileprivate func simpleCameraMoved(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
    guard a.count == 4, b.count == 4 else { return 1 }
    var m: CGFloat = 0
    for i in 0..<4 {
        m = max(m, hypot(a[i].x - b[i].x, a[i].y - b[i].y))
    }
    return m
}

/// The photo upright, pulled straight onto the sheet's corners; the whole photo when no sheet is found.
fileprivate func simpleCameraStraighten(_ data: Data) -> UIImage? {
    guard let photo = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
        return UIImage(data: data)
    }
    let request = simpleCameraRectangleRequest()
    let handler = VNImageRequestHandler(ciImage: photo, options: [:])
    try? handler.perform([request])
    var result = photo
    if let r = request.results?.first, let filter = CIFilter(name: "CIPerspectiveCorrection") {
        let e = photo.extent
        func point(_ p: CGPoint) -> CIVector {
            return CIVector(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height)
        }
        filter.setValue(photo, forKey: kCIInputImageKey)
        filter.setValue(point(r.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(r.topRight), forKey: "inputTopRight")
        filter.setValue(point(r.bottomRight), forKey: "inputBottomRight")
        filter.setValue(point(r.bottomLeft), forKey: "inputBottomLeft")
        if let out = filter.outputImage, out.extent.width > 100, out.extent.height > 100 {
            result = out
        }
    }
    let context = CIContext(options: nil)
    guard let cg = context.createCGImage(result, from: result.extent.integral) else { return UIImage(data: data) }
    return UIImage(cgImage: cg, scale: 1, orientation: .up)
}
