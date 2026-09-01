import Foundation

/// Burned-in captions (Shorts-ready story). Pure data + timing — the compositor draws whatever
/// `line(at:)` returns, so preview == export holds for captions like everything else.
struct CaptionLine: Codable, Equatable {
    var start: Double     // video-timeline seconds (raw timeline when persisted)
    var end: Double
    var text: String
}

struct CaptionTrack {
    let lines: [CaptionLine]

    static let empty = CaptionTrack(lines: [])

    func line(at t: Double) -> String? {
        lines.first { t >= $0.start && t <= $0.end }?.text
    }

    /// Group word-level timings into readable lines: ≤ maxWords words, ≤ maxSpan seconds,
    /// broken early at long inter-word gaps (sentence-ish boundaries).
    static func group(words: [(text: String, start: Double, end: Double)],
                      maxWords: Int = 4, maxSpan: Double = 2.2, gapBreak: Double = 0.7) -> [CaptionLine] {
        var out: [CaptionLine] = []
        var current: [(String, Double, Double)] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(CaptionLine(start: first.1, end: last.2 + 0.15,
                                   text: current.map(\.0).joined(separator: " ")))
            current = []
        }
        for w in words {
            if let last = current.last {
                let span = w.end - current[0].1
                if current.count >= maxWords || span > maxSpan || w.start - last.2 > gapBreak {
                    flush()
                }
            }
            current.append(w)
        }
        flush()
        return out
    }
}
