import UIKit
import Vision
import ImageIO

/// One recognised word with its place on the page (fractions of the upright image, origin top-left).
struct Word: Identifiable {
    let id = UUID()
    let text: String
    let box: CGRect
    let line: Int
}

/// Text recognition on the device (the same engine as Live Text).
enum Reader {
    /// Runs off the main thread so the screen stays responsive while reading.
    static func read(_ image: UIImage) async throws -> [Word] {
        try await Task.detached(priority: .userInitiated) { try readNow(image) }.value
    }

    static func readNow(_ image: UIImage) throws -> [Word] {
        guard let cg = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
        try handler.perform([request])
        var words: [Word] = []
        // lines come in reading order; words get their own box from the candidate
        let lines = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        for (li, obs) in lines.enumerated() {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cand.string
            var from = text.startIndex
            for piece in text.split(separator: " ") {
                let w = String(piece)
                guard let r = text.range(of: w, range: from..<text.endIndex) else { continue }
                from = r.upperBound
                let bb = (try? cand.boundingBox(for: r))?.boundingBox ?? obs.boundingBox
                // Vision: origin bottom-left → ours: origin top-left
                let box = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
                words.append(Word(text: w, box: box, line: li))
            }
        }
        return words
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Sentences: from the word after the last sentence end up to the next word ending in . ! ? :  (also before a closing quote).
enum Sentences {
    static func ends(_ w: Word) -> Bool {
        let t = w.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”»«‘’)"))
        if let last = t.last, ".!?:".contains(last) {
            // "1." (task number) is no end
            return !(t.dropLast().allSatisfy { $0.isNumber } && t.count <= 3)
        }
        return false
    }
    static func around(_ index: Int, in words: [Word]) -> [Word] {
        var start = index
        while start > 0, !ends(words[start - 1]) { start -= 1 }
        var end = index
        while end < words.count - 1, !ends(words[end]) { end += 1 }
        return Array(words[start...end])
    }
}
