import CoreGraphics
import Foundation

/// Pure viewport/transform geometry (BUILD_PLAN §5.3 steps 4–5 + the ONE coordinate adapter).
/// No pixels, no device — fully unit-tested by SP-10.
enum CameraGeometry {

    /// The visible viewport rect for a camera, in **source pixels, top-left**, already clamped
    /// fully inside the source (§5.3 step 4). scale is forced ≥ 1.
    static func viewport(for camera: CameraState, sourceSize: CGSize) -> CGRect {
        let s = max(1.0, camera.scale)
        let vw = sourceSize.width / s
        let vh = sourceSize.height / s
        let cx = clampCenterComponent(camera.center.x, halfViewport: vw / 2, source: sourceSize.width)
        let cy = clampCenterComponent(camera.center.y, halfViewport: vh / 2, source: sourceSize.height)
        return CGRect(x: cx - vw / 2, y: cy - vh / 2, width: vw, height: vh)
    }

    /// Clamp a viewport center so the viewport never shows pixels outside the source.
    static func clampCenter(_ center: CGPoint, scale: Double, sourceSize: CGSize) -> CGPoint {
        let s = max(1.0, scale)
        let vw = sourceSize.width / s
        let vh = sourceSize.height / s
        return CGPoint(
            x: clampCenterComponent(center.x, halfViewport: vw / 2, source: sourceSize.width),
            y: clampCenterComponent(center.y, halfViewport: vh / 2, source: sourceSize.height))
    }

    private static func clampCenterComponent(_ c: Double, halfViewport half: Double, source: Double) -> Double {
        // If the viewport is at least as wide as the source, it must be centered.
        if half * 2 >= source { return source / 2 }
        return min(max(c, half), source - half)
    }

    /// The **single coordinate adapter** (§5.3 preamble): the affine transform that maps the
    /// source image (Core Image space, bottom-left) so the camera's viewport lands exactly in
    /// `contentRect` of the output (also CI/bottom-left). The top-left→bottom-left flip is folded
    /// into converting the two rects here — there is NO negative scale and NO flip anywhere else,
    /// which is what prevents the classic "zoom goes the wrong way" bug.
    ///
    /// - Parameters:
    ///   - contentRect: destination rect in **output pixels, top-left** (where the card sits).
    ///   - outputSize:  full output canvas in pixels.
    static func cardTransform(camera: CameraState,
                              sourceSize: CGSize,
                              contentRect: CGRect,
                              outputSize: CGSize) -> CGAffineTransform {
        let vpTL = viewport(for: camera, sourceSize: sourceSize)
        // top-left rect → Core Image bottom-left rect (flip about the containing height):
        let vpCI = flipYToBottomLeft(vpTL, in: sourceSize.height)
        let cCI  = flipYToBottomLeft(contentRect, in: outputSize.height)
        let sx = cCI.width / vpCI.width
        let sy = cCI.height / vpCI.height
        return CGAffineTransform(translationX: cCI.minX, y: cCI.minY)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -vpCI.minX, y: -vpCI.minY)
    }

    /// Map a **source-pixel, top-left** point (e.g. the cursor) to its **output, top-left**
    /// position under the same camera. Used for cursor placement (size stays fixed, §5.4).
    static func projectPointTopLeft(_ p: CGPoint,
                                    camera: CameraState,
                                    sourceSize: CGSize,
                                    contentRect: CGRect,
                                    outputSize: CGSize) -> CGPoint {
        let t = cardTransform(camera: camera, sourceSize: sourceSize,
                              contentRect: contentRect, outputSize: outputSize)
        // Convert the point to CI space, apply, convert back to top-left output space.
        let pCI = CGPoint(x: p.x, y: sourceSize.height - p.y)
        let outCI = pCI.applying(t)
        return CGPoint(x: outCI.x, y: outputSize.height - outCI.y)
    }

    private static func flipYToBottomLeft(_ r: CGRect, in height: Double) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    /// The padded content rect (where the screen card is drawn) for a given output size + theme
    /// padding, preserving the source aspect ratio inside the padded box.
    static func contentRect(outputSize: CGSize, sourceSize: CGSize, paddingFraction: Double) -> CGRect {
        let pad = min(outputSize.width, outputSize.height) * max(0, min(paddingFraction, 0.49))
        let box = CGRect(x: pad, y: pad,
                         width: outputSize.width - 2 * pad,
                         height: outputSize.height - 2 * pad)
        return aspectFit(sourceSize, in: box)
    }

    /// Fit `size`'s aspect ratio inside `box`, centered.
    static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}
