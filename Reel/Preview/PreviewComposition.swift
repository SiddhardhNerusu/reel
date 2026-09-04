import AVFoundation
import CoreImage
import Foundation

/// Live preview built on the SAME compose function as export (BUILD_PLAN §5.6), guaranteeing
/// preview == export pixel-for-pixel. Attach the returned `AVVideoComposition` to an
/// `AVPlayerItem` playing `raw.mov` and scrub freely.
enum PreviewComposition {

    static func make(asset: AVAsset,
                     document: ReelDocument,
                     tracks: RenderTracks,
                     compositor: Compositor,
                     outputSize: CGSize,
                     editedTimeline: Bool = false) async throws -> AVVideoComposition {
        let project = document.project
        let sourceSize = project.geometry.sourceSize
        let trimIn = project.trimIn
        let camera = tracks.camera
        let cursor = tracks.cursor
        let ripples = tracks.ripples

        // Non-deprecated async factory (the appendix's `init(asset:applyingCIFiltersWithHandler:)`
        // is deprecated on macOS 15 in favor of the completion-handler form — appendix drift, §5.6).
        let comp = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            // Raw asset: composition time is raw-movie time, project time subtracts trimIn.
            // Edited composition (kept spans spliced together): composition time IS project time.
            let t = editedTimeline ? request.compositionTime.seconds : request.compositionTime.seconds - trimIn
            let clamped = max(0, t)
            let cam = camera.state(at: clamped)
            let frame = Compositor.Frame(camera: cam, cursor: cursor.point(at: clamped),
                                         ripples: ripples.active(at: clamped),
                                         cursorScale: tracks.cursorScale,
                                         caption: tracks.captions.line(at: clamped))
            let image = compositor.compose(source: request.sourceImage, sourceSize: sourceSize,
                                           frame: frame, theme: project.theme, outputSize: outputSize)
            request.finish(with: image, context: compositor.ciContext)
        }
        comp.renderSize = outputSize
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, project.fps)))
        return comp
    }
}
