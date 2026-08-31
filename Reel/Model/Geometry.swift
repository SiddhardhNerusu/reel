import CoreGraphics
import Foundation

/// Record-time geometry snapshot (BUILD_PLAN §5.2). Captured once at `startCapture`
/// so the CGEvent→source-pixel mapping (SP-5) stays a pure function forever after.
///
/// Convention (§5.3 preamble): source pixel space, **top-left origin, y-down**.
struct GeometrySnapshot: Codable, Equatable {
    /// Captured content rect in **global points, top-left origin** (`SCContentFilter.contentRect`
    /// expressed in the global display coordinate space).
    var contentRect: CGRect
    /// Retina backing scale (`SCContentFilter.pointPixelScale`), usually 2.0.
    var pointPixelScale: Double
    /// Pixel dimensions of `raw.mov` = contentRect.size × pointPixelScale.
    var sourceWidth: Int
    var sourceHeight: Int

    var sourceSize: CGSize { CGSize(width: sourceWidth, height: sourceHeight) }

    /// Map a global, top-left, points location (`CGEvent.location`) into source pixel space.
    /// ⚠️ SP-5 validates this against Retina + multi-display before it is trusted.
    func toSourcePixel(globalTopLeft p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - contentRect.minX) * pointPixelScale,
                y: (p.y - contentRect.minY) * pointPixelScale)
    }

    func contains(sourcePixel p: CGPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x < Double(sourceWidth) && p.y < Double(sourceHeight)
    }

    /// Map a global, top-left, points RECT (e.g. an Accessibility element frame) to source pixels.
    func toSourceRect(globalTopLeft r: CGRect) -> CGRect {
        let o = toSourcePixel(globalTopLeft: r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * pointPixelScale, height: r.height * pointPixelScale)
    }

    static func make(contentRect: CGRect, pointPixelScale: Double) -> GeometrySnapshot {
        GeometrySnapshot(
            contentRect: contentRect,
            pointPixelScale: pointPixelScale,
            sourceWidth: Int((contentRect.width * pointPixelScale).rounded()),
            sourceHeight: Int((contentRect.height * pointPixelScale).rounded())
        )
    }
}
