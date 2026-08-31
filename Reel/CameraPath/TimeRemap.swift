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
}
