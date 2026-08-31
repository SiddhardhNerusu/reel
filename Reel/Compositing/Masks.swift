import CoreGraphics
import CoreImage
import Foundation

/// Rounded-rectangle alpha masks built with CoreGraphics — the safe fallback for rounded corners
/// (BUILD_PLAN §5.4). We deliberately avoid `CIRoundedRectangleGenerator` until SP-6 confirms its
/// availability + param keys on the target OS.
enum Masks {

    /// A white, opaque rounded rect on a transparent background, with its origin at (0,0).
    /// Cached by (rounded size, radius) since a whole export reuses one card shape.
    static func roundedRect(size: CGSize, cornerRadius: Double) -> CIImage? {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        let key = "\(w)x\(h)@\(Int(cornerRadius.rounded()))"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let radius = min(cornerRadius, Double(min(w, h)) / 2)
        let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()

        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        cache[key] = image
        return image
    }

    private static var cache: [String: CIImage] = [:]
    private static let cacheLock = NSLock()
}
