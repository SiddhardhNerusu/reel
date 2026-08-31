import Accelerate
import AVFoundation

/// Detects silent spans in a recording's audio, fully on-device with Accelerate/vDSP (no API cost).
/// Returns intervals in video-timeline seconds, or nil if there's no audio track (REVAMP_BRIEF §5.2).
enum AudioSilence {

    /// A per-buffer RMS envelope thresholded with a content-relative noise floor + minimum duration.
    static func intervals(url: URL, minSilence: Double = 0.6) async -> [ClosedRange<Double>]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }

        // Envelope: (time, dBFS) per sample buffer.
        var env: [(t: Double, db: Float)] = []
        var scratch = [Float]()
        while let sb = out.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let ok = scratch.withUnsafeMutableBytes { raw -> Bool in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!) == kCMBlockBufferNoErr
            }
            guard ok else { continue }
            var rms: Float = 0
            scratch.withUnsafeBufferPointer { p in vDSP_rmsqv(p.baseAddress!, 1, &rms, vDSP_Length(count)) }
            let db = 20 * log10f(max(rms, 1e-7))
            env.append((t, db))
        }
        guard env.count > 4 else { return [] }

        // Noise floor: 10th-percentile of the envelope; anything within +6 dB of it is "silent".
        let sortedDB = env.map { $0.db }.sorted()
        let floor = sortedDB[sortedDB.count / 10]
        let threshold = floor + 6

        // Group consecutive silent buffers into intervals, keep those ≥ minSilence.
        var intervals: [ClosedRange<Double>] = []
        var runStart: Double?
        var lastT = env[0].t
        for e in env {
            if e.db < threshold {
                if runStart == nil { runStart = e.t }
            } else if let s = runStart {
                if lastT - s >= minSilence { intervals.append(s...lastT) }
                runStart = nil
            }
            lastT = e.t
        }
        if let s = runStart, lastT - s >= minSilence { intervals.append(s...lastT) }
        return intervals
    }
}
