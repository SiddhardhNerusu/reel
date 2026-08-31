import Foundation

/// Decides which spans to auto-cut: places with NO input activity (long idle gaps) that are ALSO
/// silent. On-device, deterministic, free — no LLM (REVAMP_BRIEF §5.2). Pure + testable; the audio
/// silence intervals are computed separately (AudioSilence) and passed in.
enum IdleCutPlanner {
    struct Config {
        /// Only cut a gap longer than this (short pauses are kept — they're demo pacing).
        var minIdleGap: Double = 1.5
        /// Keep a little breathing room around the surrounding actions so we never clip them.
        var edgePad: Double = 0.25
    }

    /// Spans with no input for longer than `minIdleGap` (in video-timeline seconds).
    static func idleGaps(eventTimes: [Double], duration: Double, config: Config = Config()) -> [ClosedRange<Double>] {
        let ts = ([0.0] + eventTimes.filter { $0 >= 0 && $0 <= duration }.sorted() + [duration])
        var gaps: [ClosedRange<Double>] = []
        for i in 1..<ts.count {
            let a = ts[i - 1], b = ts[i]
            if b - a > config.minIdleGap + 2 * config.edgePad {
                gaps.append((a + config.edgePad)...(b - config.edgePad))
            }
        }
        return gaps
    }

    /// Final cut list. `silence == nil` ⇒ no audio track, so an idle gap is trivially silent and we
    /// cut it; otherwise cut only the idle gaps that overlap real silence.
    static func cuts(eventTimes: [Double], duration: Double,
                     silence: [ClosedRange<Double>]?, config: Config = Config()) -> [ClosedRange<Double>] {
        let idle = idleGaps(eventTimes: eventTimes, duration: duration, config: config)
        guard let silence else { return idle }
        return intersect(idle, silence).filter { $0.upperBound - $0.lowerBound > config.minIdleGap }
    }

    static func intersect(_ a: [ClosedRange<Double>], _ b: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for x in a {
            for y in b {
                let lo = max(x.lowerBound, y.lowerBound), hi = min(x.upperBound, y.upperBound)
                if hi > lo { out.append(lo...hi) }
            }
        }
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }
}
