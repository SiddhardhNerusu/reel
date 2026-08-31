import CoreGraphics
import CoreImage
import Foundation

/// Draws the expanding click-ripple ring (BUILD_PLAN §5.4). A stroked circle centered in its own
/// bounding box, so the compositor can place it by center. Radius/alpha vary per frame, so these
/// are not cached.
enum RippleSprite {
    static func ring(radius: Double, lineWidth: Double, alpha: Double, scale: CGFloat = 2) -> CIImage? {
        let pad = lineWidth + 2
        let dim = Int(((radius + pad) * 2 * scale).rounded())
        guard dim > 0, let ctx = CGContext(
            data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        let c = (radius + pad)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: CGRect(x: c - radius, y: c - radius, width: radius * 2, height: radius * 2))

        guard let cg = ctx.makeImage() else { return nil }
        // Downscale from @2x so the returned extent is in output pixels.
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
    }
}
