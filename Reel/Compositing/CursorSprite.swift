import CoreGraphics
import CoreImage
import Foundation

/// A bundled, synthetic macOS-style arrow pointer drawn with CoreGraphics (BUILD_PLAN §5.4).
/// We composite THIS at render time — never the live `NSCursor`, which is meaningless offline.
/// The hotspot is the arrow tip at the sprite's top-left.
enum CursorSprite {

    /// Logical size in output pixels of the arrow's bounding box (composited at a FIXED size,
    /// i.e. it does NOT scale with zoom — matches Screen Studio).
    static let size = CGSize(width: 26, height: 40)

    /// Hotspot (the click point) in sprite-local, top-left coordinates.
    static let hotspot = CGPoint(x: 3, y: 2)

    static func arrowCGImage(scale: CGFloat = 2) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        // CoreGraphics is y-up here; build the classic arrow with the tip at the visual top-left.
        // Points below are in a y-DOWN sketch then flipped so the tip sits at top-left.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        let tip = CGPoint(x: 3, y: 2)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: 3, y: 30))
        path.addLine(to: CGPoint(x: 10, y: 23))
        path.addLine(to: CGPoint(x: 15, y: 34))
        path.addLine(to: CGPoint(x: 19, y: 32))
        path.addLine(to: CGPoint(x: 14, y: 21))
        path.addLine(to: CGPoint(x: 23, y: 21))
        path.closeSubpath()

        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
        ctx.setLineWidth(1.4)
        ctx.strokePath()

        return ctx.makeImage()
    }

    static func arrowCIImage() -> CIImage {
        if let cg = arrowCGImage() {
            // Downscale from @2x back to logical size so `.size` is in output pixels.
            return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        }
        return CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
    }
}
