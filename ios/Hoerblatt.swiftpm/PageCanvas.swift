import SwiftUI
import UIKit
import PencilKit
import Combine

// The page on screen. A UIScrollView zooms one content view that is exactly as big as the page image
// (1 point = 1 page pixel), so words, gaps, answers and pen strokes use the model's pixel rectangles as they are.
// Layers from bottom to top: photo, overlay (marks, gaps, outlines, read-aloud light), pen canvas, answer fields.

struct PageCanvas: UIViewRepresentable {
    @ObservedObject var controller: PageController
    @ObservedObject var app: AppState
    /// The half the tools act on (teal frame when two pages lie side by side).
    var isActive: Bool
    /// Called on any touch, so this half becomes the active one.
    var onActivate: () -> Void

    /// Keeps the UIKit view between SwiftUI updates.
    final class Coordinator {
        weak var view: PageCanvasHostView?
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }

    func makeUIView(context: Context) -> PageCanvasHostView {
        let view = PageCanvasHostView(frame: .zero)
        context.coordinator.view = view
        view.configure(controller: controller, app: app, isActive: isActive, onActivate: onActivate)
        return view
    }

    func updateUIView(_ uiView: PageCanvasHostView, context: Context) {
        context.coordinator.view = uiView
        uiView.configure(controller: controller, app: app, isActive: isActive, onActivate: onActivate)
    }

    static func dismantleUIView(_ uiView: PageCanvasHostView, coordinator: Coordinator) {
        uiView.tearDown()
        coordinator.view = nil
    }
}

// MARK: - The UIKit view

/// Scroll view, page layers, gestures. Delegate of the scroll view, the pen canvas and the answer fields
/// (all three are scroll views, so the scroll callbacks check which one is meant).
final class PageCanvasHostView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UITextViewDelegate {
    private let scroller = UIScrollView()
    private let contentView = UIView()
    private let imageView = UIImageView()
    private let overlay = PageCanvasOverlayView(frame: .zero)
    private let canvas = PKCanvasView()
    private let fieldLayer = PageCanvasPassThroughView(frame: .zero)
    /// The marker swipe under the finger, before the controller decides what it marks.
    private let previewLayer = CAShapeLayer()
    private let tapGesture = UITapGestureRecognizer(target: nil, action: nil)
    private let markPan = UIPanGestureRecognizer(target: nil, action: nil)
    /// Markieren: finger held still on a word opens the word lens.
    private let lensPress = UILongPressGestureRecognizer(target: nil, action: nil)

    private var controller: PageController?
    private var app: AppState?
    private var isActivePage = false
    private var onActivate: () -> Void = {}
    private var controllerSink: AnyCancellable?
    private var appSink: AnyCancellable?
    private var listenerSink: AnyCancellable?

    private var pageSize = CGSize(width: 1, height: 1)
    private var textHeight: CGFloat = 20
    /// Start view (page width fills the view) still to be set once the view has a size.
    private var needsFit = true
    private var lastLayoutSize = CGSize.zero
    private var fitWidthScale: CGFloat = 1
    /// Keyboard frame in screen coordinates while it is shown.
    private var keyboardScreenFrame: CGRect?
    private var keyboardOverlap: CGFloat = 0

    private var overlayKey: PageCanvasOverlayKey?
    private var toolKey: PageCanvasToolKey?
    private var fields: [UUID: PageCanvasAnswerField] = [:]
    private var fieldOrder: [UUID] = []

    /// The controller's drawing as last seen, and the bytes this view last sent or loaded:
    /// only a change made elsewhere (undo) is loaded back into the canvas.
    private var seenDrawing = Data()
    private var sentDrawing = Data()
    private var loadingDrawing = false
    /// The eraser took a stroke during the current touch (then the tap must not erase more).
    private var inkChangedInTouch = false
    /// The touch stopped a moving page: that is no tap on a word.
    private var touchStoppedScroll = false

    // Marker swipe (page pixels, plus the length in screen points for the speed)
    private var markSwipeActive = false
    private var markPoints: [CGPoint] = []
    private var markStartWord: Int?
    private var markMulti = false
    private var markTouched: [Int] = []
    private var markAdding = true
    private let previewMarkId = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func build() {
        backgroundColor = .clear
        clipsToBounds = true
        // ink, marks and answers keep their printed colours in dark mode
        overrideUserInterfaceStyle = .light

        scroller.frame = bounds
        scroller.delegate = self
        scroller.contentInsetAdjustmentBehavior = .never
        // the pen and the marker start at once instead of waiting whether the page scrolls
        scroller.delaysContentTouches = false
        scroller.bouncesZoom = true
        scroller.scrollsToTop = false
        scroller.backgroundColor = .clear
        scroller.isMultipleTouchEnabled = true
        addSubview(scroller)

        contentView.backgroundColor = .white
        contentView.isMultipleTouchEnabled = true
        scroller.addSubview(contentView)

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        contentView.addSubview(imageView)

        overlay.isUserInteractionEnabled = false
        contentView.addSubview(overlay)
        previewLayer.fillColor = nil
        previewLayer.strokeColor = nil
        overlay.layer.addSublayer(previewLayer)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.scrollsToTop = false
        canvas.isMultipleTouchEnabled = true
        canvas.isUserInteractionEnabled = false
        canvas.delegate = self
        contentView.addSubview(canvas)

        fieldLayer.backgroundColor = .clear
        fieldLayer.isMultipleTouchEnabled = true
        contentView.addSubview(fieldLayer)

        tapGesture.addTarget(self, action: #selector(handleTap(_:)))
        // the pen canvas and the eraser still get the touch
        tapGesture.cancelsTouchesInView = false
        tapGesture.delaysTouchesEnded = false
        tapGesture.delegate = self
        scroller.addGestureRecognizer(tapGesture)

        markPan.addTarget(self, action: #selector(handleMarkPan(_:)))
        markPan.minimumNumberOfTouches = 1
        markPan.maximumNumberOfTouches = 1
        markPan.delegate = self
        markPan.isEnabled = false
        scroller.addGestureRecognizer(markPan)

        lensPress.addTarget(self, action: #selector(handleLensPress(_:)))
        lensPress.minimumPressDuration = 0.45
        lensPress.allowableMovement = 12
        lensPress.delegate = self
        lensPress.isEnabled = false
        scroller.addGestureRecognizer(lensPress)
        // a finger that moves before the lens opens is a swipe
        markPan.require(toFail: lensPress)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - SwiftUI side

    func configure(controller: PageController, app: AppState, isActive: Bool, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        isActivePage = isActive
        if self.app !== app {
            self.app = app
            // (SwiftUI does not see the listener's changes through the app)
            appSink = app.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyState() }
            listenerSink = app.listener.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyState() }
            toolKey = nil
            overlayKey = nil
        }
        if self.controller !== controller {
            bind(controller)
        }
        applyState()
    }

    func tearDown() {
        controllerSink?.cancel()
        appSink?.cancel()
        listenerSink?.cancel()
        controllerSink = nil
        appSink = nil
        listenerSink = nil
        // (no controller any more: closing the keyboard below must not change the page)
        controller = nil
        app = nil
        endMarkSwipe()
        for f in fields.values where f.textView.isFirstResponder {
            f.textView.resignFirstResponder()
        }
        imageView.image = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// A new page in this view: image, sizes, ink and fields start fresh.
    private func bind(_ c: PageController) {
        controller = c
        controllerSink = c.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyState() }
        endMarkSwipe()
        for f in fields.values {
            if f.textView.isFirstResponder { f.textView.resignFirstResponder() }
            f.removeFromSuperview()
        }
        fields = [:]
        fieldOrder = []
        overlayKey = nil
        toolKey = nil

        let ps = pageSizeOf(c)
        pageSize = ps
        textHeight = pageCanvasTextHeight(c.page)
        // frames are set at zoom 1, the scroll view scales them afterwards
        scroller.minimumZoomScale = min(scroller.minimumZoomScale, 1)
        scroller.maximumZoomScale = max(scroller.maximumZoomScale, 1)
        scroller.zoomScale = 1
        let pageRect = CGRect(origin: .zero, size: ps)
        contentView.frame = pageRect
        imageView.frame = pageRect
        imageView.image = c.image
        overlay.frame = pageRect
        overlay.limitScale(for: ps)
        previewLayer.frame = overlay.bounds
        previewLayer.path = nil
        canvas.frame = pageRect
        canvas.contentSize = ps
        fieldLayer.frame = pageRect
        scroller.contentSize = ps

        seenDrawing = c.page.drawing
        loadDrawing(c.page.drawing)
        overlay.setNeedsDisplay()

        needsFit = true
        if bounds.width > 1 && bounds.height > 1 {
            fit(reset: true)
        }
    }

    // MARK: - Following the controller and the app

    /// Brings everything in line with the controller and the app; cheap when nothing changed.
    private func applyState() {
        guard let c = controller, let a = app else { return }
        let mode = a.mode
        let s = a.settings
        let th = pageCanvasTextHeight(c.page)
        textHeight = th
        applyTool(mode: mode, settings: s, textHeight: th)
        applyOverlay(c, settings: s, mode: mode, textHeight: th)
        applyFields(c, a, mode: mode, textHeight: th)
        applyDrawing(c)
        updateActiveFrame()
    }

    private func applyTool(mode: Mode, settings s: AppSettings, textHeight th: CGFloat) {
        let width = min(25, max(3, th * 0.14))
        let key = PageCanvasToolKey(mode: mode, pen: s.penColor, width: width)
        if let old = toolKey, old == key { return }
        let modeChanged = toolKey?.mode != mode
        toolKey = key
        // typing belongs to "Sprechen": another tool closes the keyboard
        if modeChanged && mode != .sprechen, let f = editingField() {
            f.textView.resignFirstResponder()
        }
        switch mode {
        case .stift:
            canvas.tool = PKInkingTool(.pen, color: s.penColor.ink, width: width)
            canvas.isUserInteractionEnabled = true
        case .radieren:
            canvas.tool = PKEraserTool(.vector)
            canvas.isUserInteractionEnabled = true
        case .wort, .satz, .sprechen, .markieren:
            canvas.isUserInteractionEnabled = false
        }
        // one finger draws, marks or erases there; the page then moves with two fingers
        let oneFingerWorks = mode == .markieren || mode == .stift || mode == .radieren
        scroller.panGestureRecognizer.minimumNumberOfTouches = oneFingerWorks ? 2 : 1
        markPan.isEnabled = mode == .markieren
        lensPress.isEnabled = mode == .markieren
        if mode != .markieren { endMarkSwipe() }
    }

    private func applyOverlay(_ c: PageController, settings s: AppSettings, mode: Mode, textHeight th: CGFloat) {
        // outlines help finding words to listen to (as in the web version: only in Wort and Satz)
        let hints = s.outlines && (mode == .wort || mode == .satz)
        let key = PageCanvasOverlayKey(words: c.page.words, boxes: c.page.boxes, gaps: c.page.gaps,
                                       marks: c.page.marks, flash: c.flash, hints: hints,
                                       boxesTogether: s.boxesTogether, markGaps: s.markGaps, textHeight: th)
        var onlyFlash = false
        var dirty = CGRect.null
        if let old = overlayKey {
            if old == key { return }
            var probe = old
            probe.flash = key.flash
            if probe == key {
                onlyFlash = true
                for r in old.flash { dirty = dirty.union(r) }
                for r in key.flash { dirty = dirty.union(r) }
            }
        }
        overlayKey = key
        overlay.textHeight = th
        overlay.flash = c.flash
        if onlyFlash {
            // (redrawing the whole page for the light while reading would be wasted work)
            if !dirty.isNull {
                let pad = max(8, th * 0.5)
                overlay.setNeedsDisplay(dirty.insetBy(dx: -pad, dy: -pad))
            }
            return
        }

        let reading = c.reading
        var marks: [PageCanvasMarkPaint] = []
        for m in c.page.marks {
            if let r = reading.markRect(m) {
                marks.append(PageCanvasMarkPaint(rect: r, color: m.color.fill))
            }
        }
        overlay.marks = marks

        var gapRects: [CGRect] = []
        if s.markGaps {
            for g in c.page.gaps {
                switch g.kind {
                case .line:
                    // the rect ends on the writing line; a little below it the line stays visible inside
                    gapRects.append(CGRect(x: g.rect.minX, y: g.rect.minY, width: g.rect.width,
                                           height: g.rect.height + th * 0.08))
                case .box:
                    gapRects.append(g.rect)
                }
            }
        }
        overlay.gapRects = gapRects

        var wordRects: [CGRect] = []
        var boxRects: [CGRect] = []
        if hints {
            let pad = th * 0.08
            for w in c.page.words {
                // a word in a printed box is read with its box: the box is outlined instead
                // (a word in a table cell is read alone: outlined like any word)
                if s.boxesTogether, let bx = w.box, bx >= 0, bx < c.page.boxes.count,
                   c.page.boxes[bx].cell != true { continue }
                wordRects.append(w.rect.insetBy(dx: -pad, dy: -pad))
            }
            if s.boxesTogether {
                for b in c.page.boxes where b.cell != true {
                    boxRects.append(b.rect.insetBy(dx: th * 0.1, dy: th * 0.1))
                }
            }
        }
        overlay.wordRects = wordRects
        overlay.boxRects = boxRects
        overlay.setNeedsDisplay()
    }

    private func applyFields(_ c: PageController, _ a: AppState, mode: Mode, textHeight th: CGFloat) {
        let answers = c.page.answers
        let ids = answers.map { $0.id }
        var created = false
        for ans in answers where fields[ans.id] == nil {
            let f = PageCanvasAnswerField(answerId: ans.id, delegate: self)
            fields[ans.id] = f
            fieldLayer.addSubview(f)
            created = true
        }
        let keep = Set(ids)
        for id in Array(fields.keys) where !keep.contains(id) {
            if let f = fields[id] {
                if f.textView.isFirstResponder { f.textView.resignFirstResponder() }
                f.removeFromSuperview()
            }
            fields[id] = nil
        }
        if created || ids != fieldOrder {
            // later answers lie on top, as in the list
            for id in ids {
                if let f = fields[id] { fieldLayer.bringSubviewToFront(f) }
            }
            fieldOrder = ids
        }
        let listening = a.listener.isListening && mode == .sprechen
        for ans in answers {
            guard let f = fields[ans.id] else { continue }
            let active = c.activeAnswer == ans.id
            f.update(answer: ans, textHeight: th, editable: c.keyboardAnswer == ans.id, active: active,
                     listening: listening && active, erasing: mode == .radieren)
        }
        focusPendingField()
    }

    private func applyDrawing(_ c: PageController) {
        let d = c.page.drawing
        if d == seenDrawing { return }
        seenDrawing = d
        // (what this view sent itself is already on the canvas)
        if d != sentDrawing { loadDrawing(d) }
    }

    private func loadDrawing(_ data: Data) {
        var drawing = PKDrawing()
        if !data.isEmpty, let d = try? PKDrawing(data: data) {
            drawing = d
        }
        loadingDrawing = true
        canvas.drawing = drawing
        loadingDrawing = false
        sentDrawing = data
    }

    /// Teal frame around the active half, only while two pages are shown side by side.
    private func updateActiveFrame() {
        var show = false
        if isActivePage, let a = app, a.twoPages, let w = window, bounds.width < w.bounds.width * 0.75 {
            show = true
        }
        let width: CGFloat = show ? 4 : 0
        if layer.borderWidth != width {
            layer.borderColor = PageCanvasPalette.teal.cgColor
            layer.borderWidth = width
        }
    }

    // MARK: - Size and zoom

    override func layoutSubviews() {
        super.layoutSubviews()
        if scroller.frame != bounds { scroller.frame = bounds }
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            fit(reset: needsFit)
            updateKeyboardOverlap()
            if let f = editingField() { revealField(f) }
        }
        updateActiveFrame()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            updateActiveFrame()
            focusPendingField()
        }
    }

    /// Smallest zoom: the whole page; start: the page width fills the view. On a new size (rotation,
    /// second page) a page shown at full width stays at full width and keeps its place.
    private func fit(reset: Bool) {
        let b = scroller.bounds.size
        guard b.width > 1, b.height > 1, pageSize.width > 1, pageSize.height > 1 else { return }
        let fitWidth = b.width / pageSize.width
        let fitAll = min(fitWidth, b.height / pageSize.height)
        let oldZoom = scroller.zoomScale
        let wasFitWidth = abs(oldZoom - fitWidthScale) <= fitWidthScale * 0.02
        let oldSize = scroller.contentSize
        let relX = oldSize.width > 0 ? max(0, scroller.contentOffset.x) / oldSize.width : 0
        let relY = oldSize.height > 0 ? max(0, scroller.contentOffset.y) / oldSize.height : 0

        scroller.minimumZoomScale = fitAll
        scroller.maximumZoomScale = max(fitWidth * 4, 1)
        fitWidthScale = fitWidth

        if reset || needsFit {
            scroller.zoomScale = fitWidth
            updateInsets()
            scroller.contentOffset = CGPoint(x: -scroller.contentInset.left, y: -scroller.contentInset.top)
            needsFit = false
            return
        }
        let zoom = wasFitWidth ? fitWidth : min(max(oldZoom, fitAll), scroller.maximumZoomScale)
        if zoom != scroller.zoomScale { scroller.zoomScale = zoom }
        updateInsets()
        let newSize = scroller.contentSize
        scroller.contentOffset = clampedOffset(CGPoint(x: relX * newSize.width, y: relY * newSize.height))
    }

    /// Centres a page smaller than the view; leaves room for the keyboard below an answer field.
    private func updateInsets() {
        let b = scroller.bounds.size
        let cs = scroller.contentSize
        let h = max(0, (b.width - cs.width) / 2)
        let v = max(0, (b.height - keyboardOverlap - cs.height) / 2)
        let insets = UIEdgeInsets(top: v, left: h, bottom: v + keyboardOverlap, right: h)
        if scroller.contentInset != insets { scroller.contentInset = insets }
    }

    private func clampedOffset(_ p: CGPoint) -> CGPoint {
        let inset = scroller.contentInset
        let cs = scroller.contentSize
        let b = scroller.bounds.size
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, cs.width + inset.right - b.width)
        let maxY = max(minY, cs.height + inset.bottom - b.height)
        return CGPoint(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
    }

    private func pageSizeOf(_ c: PageController) -> CGSize {
        let s = c.page.pixelSize
        if s.width.isFinite && s.height.isFinite && s.width >= 1 && s.height >= 1 { return s }
        let img = c.image
        return CGSize(width: max(1, img.size.width * img.scale), height: max(1, img.size.height * img.scale))
    }

    // MARK: - Scroll, canvas and text delegates

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return scrollView === scroller ? contentView : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === scroller else { return }
        updateInsets()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard canvasView === canvas, !loadingDrawing, let c = controller else { return }
        inkChangedInTouch = true
        let data = canvasView.drawing.dataRepresentation()
        sentDrawing = data
        c.drawingChanged(data)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let c = controller, let f = field(of: textView) else { return }
        c.setAnswerText(f.answerId, textView.text ?? "")
        f.relayout()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let f = field(of: textView) else { return }
        revealField(f)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard controller != nil, let f = field(of: textView) else { return }
        let id = f.answerId
        // The keyboard was closed: the field is plain again until it is tapped. Set a moment later,
        // because this can run inside a SwiftUI update, where published state must not change.
        Task { @MainActor [weak self] in
            guard let me = self, let c = me.controller, c.keyboardAnswer == id else { return }
            let typing = me.fields[id]?.textView.isFirstResponder ?? false
            if !typing { c.keyboardAnswer = nil }
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // the return key closes the keyboard (an answer is one line of thought)
        if text == "\n" {
            textView.resignFirstResponder()
            return false
        }
        return true
    }

    // MARK: - Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === tapGesture {
            // every touch on this half makes it the active one
            if !isActivePage { onActivate() }
            inkChangedInTouch = false
            touchStoppedScroll = scroller.isDecelerating
        }
        // typing into the open answer field stays with the text view
        if let v = touch.view, isEditableText(v) { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let tapFirst = gestureRecognizer === tapGesture
        guard tapFirst || otherGestureRecognizer === tapGesture else { return false }
        let other = tapFirst ? otherGestureRecognizer : gestureRecognizer
        // a swipe or a scroll is no tap; the pen canvas and the eraser may see the same touch
        if other === markPan || other === lensPress || other === scroller.panGestureRecognizer
            || other === scroller.pinchGestureRecognizer {
            return false
        }
        return true
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, !touchStoppedScroll, let c = controller, let a = app else { return }
        let mode = a.mode
        // (the pen draws a dot by itself)
        if mode == .stift { return }
        let p = g.location(in: contentView)
        if let id = answerHit(p, c) {
            c.tapAnswer(id)
            return
        }
        switch mode {
        case .wort:
            c.tapWord(at: p)
        case .satz:
            c.tapSentence(at: p)
        case .sprechen:
            c.tapSpeak(at: p)
        case .markieren:
            c.markTap(at: p)
        case .radieren:
            // a pen stroke under the finger belongs to the eraser; the tap must not also take a mark away
            if inkChangedInTouch || strokeNear(p) { return }
            c.eraseTap(at: p)
        case .stift:
            break
        }
    }

    @objc private func handleMarkPan(_ g: UIPanGestureRecognizer) {
        guard let c = controller else {
            endMarkSwipe()
            return
        }
        switch g.state {
        case .began:
            let loc = g.location(in: contentView)
            let tr = g.translation(in: contentView)
            // the swipe started where the finger came down, before the pan was recognised
            let start = CGPoint(x: loc.x - tr.x, y: loc.y - tr.y)
            let reading = c.reading
            markSwipeActive = true
            markPoints = [start]
            markStartWord = wordIndex(reading.wordAt(start, loose: true), c)
            markMulti = false
            markTouched = []
            if let s = markStartWord {
                markAdding = !c.page.marks.contains(where: { $0.word == s })
            } else {
                markAdding = true
            }
            addMarkPoint(loc, reading, c)
            showMarkPreview(c)
        case .changed:
            guard markSwipeActive else { return }
            addMarkPoint(g.location(in: contentView), c.reading, c)
            showMarkPreview(c)
        case .ended:
            guard markSwipeActive else { return }
            addMarkPoint(g.location(in: contentView), c.reading, c)
            let points = markPoints
            endMarkSwipe()
            c.markStroke(points)
        default:
            endMarkSwipe()
        }
    }

    @objc private func handleLensPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let c = controller else { return }
        let p = g.location(in: contentView)
        if answerHit(p, c) != nil { return }
        endMarkSwipe()
        c.openLens(at: p)
    }

    /// Same reading of the swipe as `markStroke`: leaving the first word makes it a swipe across words.
    private func addMarkPoint(_ p: CGPoint, _ reading: Reading, _ c: PageController) {
        if let last = markPoints.last {
            let dx = p.x - last.x
            let dy = p.y - last.y
            if dx * dx + dy * dy < 0.25 { return }
        }
        markPoints.append(p)
        guard let h = wordIndex(reading.wordAt(p, loose: false), c) else { return }
        if !markMulti && h != markStartWord {
            markMulti = true
            if let s = markStartWord { markTouched.append(s) }
        }
        if markMulti && !markTouched.contains(h) { markTouched.append(h) }
    }

    private func showMarkPreview(_ c: PageController) {
        guard let a = app else { return }
        let reading = c.reading
        let color = a.settings.markColor
        var rects: [CGRect] = []
        if markMulti {
            // (taking marks off shows nothing until the finger lifts)
            if markAdding {
                for i in markTouched {
                    let m = Mark(id: previewMarkId, word: i, color: color, from: nil, to: nil)
                    if let r = reading.markRect(m) { rects.append(r) }
                }
            }
        } else if let i = markStartWord, i >= 0, i < c.page.words.count {
            // a swipe within one word marks the whole word (as in `markStroke`)
            let w = c.page.words[i].rect
            let xs = markPoints.map { min(max($0.x, w.minX), w.maxX) }
            if let lo = xs.min(), let hi = xs.max(), hi - lo >= w.height * 0.3 {
                let m = Mark(id: previewMarkId, word: i, color: color, from: nil, to: nil)
                if let r = reading.markRect(m) { rects.append(r) }
            }
        }
        let path = UIBezierPath()
        let radius = textHeight * 0.15
        for r in rects {
            if let piece = PageCanvasOverlayView.roundedPath(r, radius) { path.append(piece) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.fillColor = color.fill.cgColor
        previewLayer.path = rects.isEmpty ? nil : path.cgPath
        CATransaction.commit()
    }

    private func endMarkSwipe() {
        markSwipeActive = false
        markPoints = []
        markTouched = []
        markMulti = false
        markStartWord = nil
        if previewLayer.path != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.path = nil
            CATransaction.commit()
        }
    }

    // MARK: - Hits

    /// The answer field under the finger (topmost), as it is shown.
    private func answerHit(_ p: CGPoint, _ c: PageController) -> UUID? {
        let pad = textHeight * 0.2
        for a in c.page.answers.reversed() {
            let r = fields[a.id]?.frame ?? a.rect
            if r.insetBy(dx: -pad, dy: -pad).contains(p) { return a.id }
        }
        return nil
    }

    private func strokeNear(_ p: CGPoint) -> Bool {
        let tol = max(textHeight * 0.5, 12)
        for stroke in canvas.drawing.strokes {
            if !stroke.renderBounds.insetBy(dx: -tol, dy: -tol).contains(p) { continue }
            let t = stroke.transform
            for sp in stroke.path {
                let q = sp.location.applying(t)
                let dx = q.x - p.x
                let dy = q.y - p.y
                if dx * dx + dy * dy <= tol * tol { return true }
            }
        }
        return false
    }

    /// Word id → index in `page.words` (kept equal; checked anyway).
    private func wordIndex(_ id: Int?, _ c: PageController) -> Int? {
        guard let id = id else { return nil }
        let words = c.page.words
        if id >= 0 && id < words.count && words[id].id == id { return id }
        return words.firstIndex(where: { $0.id == id })
    }

    private func isEditableText(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let v = current, v !== self {
            if let tv = v as? UITextView, tv.isEditable { return true }
            current = v.superview
        }
        return false
    }

    private func field(of textView: UITextView) -> PageCanvasAnswerField? {
        for f in fields.values where f.textView === textView { return f }
        return nil
    }

    private func editingField() -> PageCanvasAnswerField? {
        for f in fields.values where f.textView.isFirstResponder { return f }
        return nil
    }

    // MARK: - Keyboard

    /// Opens the keyboard for a field that asked for it, once the view is on screen.
    private func focusPendingField() {
        guard window != nil else { return }
        for f in fields.values where f.focusPending {
            if f.textView.isFirstResponder {
                f.focusPending = false
            } else if f.textView.becomeFirstResponder() {
                f.focusPending = false
                revealField(f)
            }
        }
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        keyboardScreenFrame = value.cgRectValue
        updateKeyboardOverlap()
        if let f = editingField() { revealField(f) }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardScreenFrame = nil
        updateKeyboardOverlap()
    }

    /// How far the keyboard covers this view, only while one of its answer fields is typed into.
    private func updateKeyboardOverlap() {
        var overlap: CGFloat = 0
        if let kb = keyboardScreenFrame, let w = window, editingField() != nil {
            let space: UICoordinateSpace
            if let screen = w.windowScene?.screen {
                space = screen.coordinateSpace
            } else {
                space = w
            }
            let local = convert(kb, from: space)
            let hit = bounds.intersection(local)
            if !hit.isNull { overlap = hit.height }
        }
        if overlap != keyboardOverlap {
            keyboardOverlap = overlap
            updateInsets()
        }
    }

    /// Scrolls so the field is visible above the keyboard.
    private func revealField(_ f: PageCanvasAnswerField) {
        guard f.superview != nil else { return }
        let r = f.convert(f.bounds, to: scroller)
        let b = scroller.bounds.size
        let visibleHeight = max(40, b.height - keyboardOverlap)
        let margin: CGFloat = 24
        var off = scroller.contentOffset
        if r.maxY + margin > off.y + visibleHeight { off.y = r.maxY + margin - visibleHeight }
        if r.minY - margin < off.y { off.y = r.minY - margin }
        if r.maxX + margin > off.x + b.width { off.x = r.maxX + margin - b.width }
        if r.minX - margin < off.x { off.x = r.minX - margin }
        off = clampedOffset(off)
        if off != scroller.contentOffset { scroller.setContentOffset(off, animated: true) }
    }
}

// MARK: - Helpers

/// Typical text height of the page (same fallback as `Reading`).
fileprivate func pageCanvasTextHeight(_ page: Page) -> CGFloat {
    let th = page.textHeight
    if th.isFinite && th > 1 { return th }
    return max(12, page.pixelSize.height * 0.024)
}

fileprivate enum PageCanvasPalette {
    static var purple: UIColor { return UIColor(red: 124 / 255, green: 58 / 255, blue: 237 / 255, alpha: 1) }
    static var orange: UIColor { return UIColor(red: 234 / 255, green: 88 / 255, blue: 12 / 255, alpha: 1) }
    static var teal: UIColor { return UIColor(red: 15 / 255, green: 118 / 255, blue: 110 / 255, alpha: 1) }
    static var slate: UIColor { return UIColor(red: 71 / 255, green: 85 / 255, blue: 105 / 255, alpha: 1) }
    static var answerInk: UIColor { return UIColor(red: 0.11, green: 0.25, blue: 0.69, alpha: 1) }
    static var answerBackground: UIColor { return UIColor(red: 237 / 255, green: 233 / 255, blue: 254 / 255, alpha: 0.92) }
    static var answerListening: UIColor { return UIColor(red: 221 / 255, green: 214 / 255, blue: 254 / 255, alpha: 0.97) }
}

/// What the overlay shows; a change in any of it redraws.
fileprivate struct PageCanvasOverlayKey: Equatable {
    var words: [Word]
    var boxes: [PrintedBox]
    var gaps: [Gap]
    var marks: [Mark]
    var flash: [CGRect]
    var hints: Bool
    var boxesTogether: Bool
    var markGaps: Bool
    var textHeight: CGFloat
}

fileprivate struct PageCanvasToolKey: Equatable {
    var mode: Mode
    var pen: PenColor
    var width: CGFloat
}

fileprivate struct PageCanvasMarkPaint {
    var rect: CGRect
    var color: UIColor
}

/// Lets touches through where no answer field is, so the pen canvas and the page below get them.
fileprivate final class PageCanvasPassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - Overlay

/// Marks, gaps, word outlines and the read-aloud light, drawn in page pixels.
fileprivate final class PageCanvasOverlayView: UIView {
    var textHeight: CGFloat = 20
    var marks: [PageCanvasMarkPaint] = []
    var gapRects: [CGRect] = []
    var wordRects: [CGRect] = []
    var boxRects: [CGRect] = []
    var flash: [CGRect] = []
    /// A page is thousands of points wide: at screen scale its backing store would take several times
    /// the memory, and on screen it is shown smaller anyway.
    private var drawScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clearsContextBeforeDrawing = true
        contentScaleFactor = drawScale
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// At most about 8 million backing pixels, never more than 1 pixel per point.
    func limitScale(for size: CGSize) {
        let area = max(1, size.width * size.height)
        drawScale = max(0.5, min(1, (8_000_000 / area).squareRoot()))
        if contentScaleFactor != drawScale { contentScaleFactor = drawScale }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // (UIKit may set the screen's scale when the view joins a window)
        if contentScaleFactor != drawScale { contentScaleFactor = drawScale }
    }

    static func roundedPath(_ r: CGRect, _ radius: CGFloat) -> UIBezierPath? {
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
              r.width > 0.5, r.height > 0.5 else { return nil }
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        return UIBezierPath(roundedRect: r, cornerRadius: rad)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let th = max(textHeight, 4)
        let radius = th * 0.15

        // marks first, like a highlighter on the paper
        for m in marks where m.rect.intersects(rect) {
            guard let p = PageCanvasOverlayView.roundedPath(m.rect, radius) else { continue }
            fill(ctx, p, m.color)
        }

        let purple = PageCanvasPalette.purple
        let gapFill = purple.withAlphaComponent(0.12)
        let gapLine = max(2.5, th * 0.08)
        let gapDash: [CGFloat] = [th * 0.25, th * 0.18]
        for g in gapRects where g.insetBy(dx: -gapLine, dy: -gapLine).intersects(rect) {
            guard let p = PageCanvasOverlayView.roundedPath(g, radius) else { continue }
            fill(ctx, p, gapFill)
            stroke(ctx, p, purple, width: gapLine, dash: gapDash)
        }

        let orange = PageCanvasPalette.orange
        if !boxRects.isEmpty {
            let boxColor = orange.withAlphaComponent(0.7)
            let boxLine = max(2, th * 0.07)
            let boxDash: [CGFloat] = [th * 0.25, th * 0.18]
            for b in boxRects where b.insetBy(dx: -boxLine, dy: -boxLine).intersects(rect) {
                guard let p = PageCanvasOverlayView.roundedPath(b, radius) else { continue }
                stroke(ctx, p, boxColor, width: boxLine, dash: boxDash)
            }
        }
        if !wordRects.isEmpty {
            let wordColor = orange.withAlphaComponent(0.5)
            let wordLine = max(1.5, th * 0.045)
            let wordDash: [CGFloat] = [th * 0.15, th * 0.15]
            for w in wordRects where w.insetBy(dx: -wordLine, dy: -wordLine).intersects(rect) {
                guard let p = PageCanvasOverlayView.roundedPath(w, radius) else { continue }
                stroke(ctx, p, wordColor, width: wordLine, dash: wordDash)
            }
        }

        // the light while reading: lighter for a sentence over several lines
        if !flash.isEmpty {
            let flashFill = orange.withAlphaComponent(flash.count > 1 ? 0.10 : 0.18)
            let flashLine = max(3, th * 0.1)
            for f in flash where f.insetBy(dx: -flashLine, dy: -flashLine).intersects(rect) {
                guard let p = PageCanvasOverlayView.roundedPath(f, radius) else { continue }
                fill(ctx, p, flashFill)
                stroke(ctx, p, orange, width: flashLine, dash: [])
            }
        }
    }

    private func fill(_ ctx: CGContext, _ path: UIBezierPath, _ color: UIColor) {
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func stroke(_ ctx: CGContext, _ path: UIBezierPath, _ color: UIColor, width: CGFloat, dash: [CGFloat]) {
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: - Answer field

/// One answer on the page: blue text on light purple, growing downwards with its text.
/// Only the field that should get the keyboard takes touches; all others are hit-tested by the page.
fileprivate final class PageCanvasAnswerField: UIView {
    let answerId: UUID
    let textView = UITextView(frame: .zero, textContainer: nil)
    /// Wants the keyboard as soon as the view can take it.
    var focusPending = false
    private(set) var editable = false
    private var answerRect = CGRect.zero
    private var th: CGFloat = 20
    private var fontSize: CGFloat = 0
    private var pulsing = false

    init(answerId: UUID, delegate: UITextViewDelegate) {
        self.answerId = answerId
        super.init(frame: .zero)
        clipsToBounds = false
        isUserInteractionEnabled = false
        backgroundColor = PageCanvasPalette.answerBackground
        layer.borderColor = PageCanvasPalette.purple.cgColor
        layer.shadowColor = PageCanvasPalette.purple.cgColor
        layer.shadowOffset = CGSize.zero
        layer.shadowOpacity = 0

        textView.backgroundColor = .clear
        textView.textColor = PageCanvasPalette.answerInk
        textView.tintColor = PageCanvasPalette.purple
        textView.isScrollEnabled = false
        textView.scrollsToTop = false
        textView.textContainerInset = UIEdgeInsets.zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.returnKeyType = .done
        textView.isEditable = false
        textView.isSelectable = false
        textView.accessibilityLabel = "Antwort"
        textView.delegate = delegate
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    static func answerFont(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: rounded, size: size)
        }
        return base
    }

    func update(answer: Answer, textHeight: CGFloat, editable newEditable: Bool, active: Bool,
                listening: Bool, erasing: Bool) {
        th = max(4, textHeight)
        answerRect = answer.rect
        let size = th * 1.1
        if size != fontSize {
            fontSize = size
            textView.font = PageCanvasAnswerField.answerFont(size)
        }
        // (not while the keyboard composes a word, and the cursor stays where it is when nothing changed)
        if textView.text != answer.text && textView.markedTextRange == nil {
            textView.text = answer.text
        }
        if newEditable != editable {
            editable = newEditable
            textView.isEditable = newEditable
            textView.isSelectable = newEditable
            isUserInteractionEnabled = newEditable
            focusPending = newEditable
            if !newEditable && textView.isFirstResponder { textView.resignFirstResponder() }
        }

        let line = max(2, th * 0.06)
        layer.cornerRadius = th * 0.3
        layer.borderWidth = active ? line * 2 : line
        layer.borderColor = (erasing ? PageCanvasPalette.slate : PageCanvasPalette.purple).cgColor
        backgroundColor = listening ? PageCanvasPalette.answerListening : PageCanvasPalette.answerBackground
        layer.shadowRadius = th * 0.35
        layer.shadowOpacity = active ? 0.45 : 0
        setPulsing(listening)
        relayout()
    }

    /// Width as stored (at least two letters), height as the text needs, never smaller than stored.
    func relayout() {
        let padX = th * 0.15
        let padY = th * 0.06
        let width = max(answerRect.width, th * 2)
        let innerWidth = max(1, width - 2 * padX)
        let fitted = textView.sizeThatFits(CGSize(width: innerWidth, height: CGFloat.greatestFiniteMagnitude))
        let textHeight = max(fitted.height, fontSize * 1.25)
        let height = max(answerRect.height, th * 1.5, textHeight + 2 * padY)
        let newFrame = CGRect(x: answerRect.minX, y: answerRect.minY, width: width, height: height)
        if frame != newFrame { frame = newFrame }
        let textFrame = CGRect(x: padX, y: max(padY, (height - textHeight) / 2), width: innerWidth, height: textHeight)
        if textView.frame != textFrame { textView.frame = textFrame }
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: min(layer.cornerRadius, height / 2)).cgPath
    }

    /// The glow pulses while the app listens for this field.
    private func setPulsing(_ on: Bool) {
        if on == pulsing { return }
        pulsing = on
        if on {
            let anim = CABasicAnimation(keyPath: "shadowOpacity")
            anim.fromValue = 0.2
            anim.toValue = 0.95
            anim.duration = 0.55
            anim.autoreverses = true
            anim.repeatCount = Float.infinity
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "hoerblattListen")
        } else {
            layer.removeAnimation(forKey: "hoerblattListen")
        }
    }
}
