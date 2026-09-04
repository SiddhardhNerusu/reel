import Foundation

/// Maps raw video-timeline seconds → edited output seconds, removing BOTH the trim boundaries and
/// any auto-cut idle spans in one place (REVAMP_BRIEF §5.2/§5.3). Used by the exporter (which frames
/// to skip) and the track builder (event/cursor times), so they always agree. Pure + testable.
struct TimeRemap {
    var trimIn: Double
    var trimOut: Double
    var cuts: [ClosedRange<Double>]     // raw video seconds, within [trimIn, trimOut]

    /// Output time for a raw time, or nil if it's trimmed away or inside a cut.
    func output(_ rawT: Double) -> Double? {
        guard rawT >= trimIn, rawT <= trimOut else { return nil }
        for c in cuts where rawT >= c.lowerBound && rawT <= c.upperBound { return nil }
        var cutBefore = 0.0
        for c in cuts where c.upperBound <= rawT {
            cutBefore += clampedLength(c)
        }
        return (rawT - trimIn) - cutBefore
    }

    var editedDuration: Double {
        var cut = 0.0
        for c in cuts { cut += clampedLength(c) }
        return max(0, (trimOut - trimIn) - cut)
    }

    private func clampedLength(_ c: ClosedRange<Double>) -> Double {
        max(0, min(c.upperBound, trimOut) - max(c.lowerBound, trimIn))
    }

    /// Kept raw spans in order: [trimIn, trimOut] minus the cuts. What the edited timeline is made of.
    var keptRanges: [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var cursor = trimIn
        for c in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lo = max(c.lowerBound, trimIn), hi = min(c.upperBound, trimOut)
            guard hi > lo else { continue }
            if lo > cursor + 1e-6 { out.append(cursor...lo) }
            cursor = max(cursor, hi)
        }
        if trimOut > cursor + 1e-6 { out.append(cursor...trimOut) }
        return out
    }

    /// Inverse of `output`: the raw time for an edited-timeline time (clamped to the edit).
    func rawTime(forOutput t: Double) -> Double {
        var remaining = max(0, t)
        for r in keptRanges {
            let len = r.upperBound - r.lowerBound
            if remaining <= len { return r.lowerBound + remaining }
            remaining -= len
        }
        return trimOut
    }

    /// Nearest edited time for a raw time (raw times inside a cut snap to the cut's end).
    func nearestOutput(_ rawT: Double) -> Double {
        if let o = output(rawT) { return o }
        let clamped = min(max(rawT, trimIn), trimOut)
        if let c = cuts.first(where: { clamped >= $0.lowerBound && clamped <= $0.upperBound }) {
            return output(min(c.upperBound + 1e-3, trimOut)) ?? editedDuration
        }
        return clamped <= trimIn ? 0 : editedDuration
    }

    /// Sort, clip to [0, ∞) and merge overlapping/touching spans; drops empty ones.
    static func normalize(_ cuts: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let sorted = cuts.filter { $0.upperBound > $0.lowerBound }.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Double>] = []
        for c in sorted {
            if let last = out.last, c.lowerBound <= last.upperBound + 1e-6 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, c.upperBound)
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `a` minus `b` (span subtraction) — used to restore an auto-cut the user clicked away.
    static func subtract(_ a: [ClosedRange<Double>], _ b: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result = a
        for cut in b {
            var next: [ClosedRange<Double>] = []
            for r in result {
                if cut.upperBound <= r.lowerBound || cut.lowerBound >= r.upperBound { next.append(r); continue }
                if r.lowerBound < cut.lowerBound { next.append(r.lowerBound...cut.lowerBound) }
                if cut.upperBound < r.upperBound { next.append(cut.upperBound...r.upperBound) }
            }
            result = next
        }
        return result.filter { $0.upperBound - $0.lowerBound > 0.05 }
    }
}
