import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// The ONE pure compositing function shared by preview and export (BUILD_PLAN §5.4). Given a
/// source frame + camera + cursor + theme, it returns the finished output image. Because preview
/// and export both call this, they are pixel-identical by construction.
///
/// Core Image is y-UP; all top-left→bottom-left conversion is confined to `CameraGeometry`
/// (the single coordinate adapter) and the small `toCI` helper below. Nothing introduces a flip.
///
/// `@unchecked Sendable`: every stored member is immutable and thread-safe — `CIContext` and
/// `CIImage` are documented safe to share across threads — so the same compositor is used from the
/// preview handler, the offline export task, and the MainActor coordinator without a data race.
final class Compositor: @unchecked Sendable {

    let ciContext: CIContext
    let colorSpace: CGColorSpace
    private let cursorImage: CIImage

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        // ONE Metal-backed context, reused (creation is expensive).
        if let device {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        cursorImage = CursorSprite.arrowCIImage()
    }

    struct Frame {
        var camera: CameraState
        var cursor: CGPoint?          // source pixels, top-left; nil ⇒ no cursor this frame
        var ripples: [RippleTrack.Ripple] = []   // click ripples active this frame (source px)
    }

    /// Compose one output frame. `outputSize` is the final canvas size in pixels.
    func compose(source: CIImage, sourceSize: CGSize, frame: Frame, theme: Theme, outputSize: CGSize) -> CIImage {
        let outRect = CGRect(origin: .zero, size: outputSize)
        let content = CameraGeometry.contentRect(outputSize: outputSize, sourceSize: sourceSize,
                                                  paddingFraction: theme.paddingFraction)

        // 1) Background (full-bleed).
        var image = background(theme.background, size: outputSize)

        // 2) Drop shadow under the card.
        if theme.shadow.opacity > 0 {
            image = shadow(theme: theme, content: content, outputSize: outputSize).composited(over: image)
        }

        // 3) Screen card: transform source into the content rect, then round the corners.
        let cardTransform = CameraGeometry.cardTransform(
            camera: frame.camera, sourceSize: sourceSize, contentRect: content, outputSize: outputSize)
        let transformed = source.transformed(by: cardTransform).cropped(to: toCI(content, outputSize))
        let card = roundCorners(transformed, content: content, outputSize: outputSize, radius: theme.cornerRadius)
        image = card.composited(over: image)

        // 4) Click ripples (under the cursor), fixed on-screen scale, expanding + fading.
        for ripple in frame.ripples {
            let outPtTL = CameraGeometry.projectPointTopLeft(
                ripple.center, camera: frame.camera, sourceSize: sourceSize,
                contentRect: content, outputSize: outputSize)
            guard content.contains(outPtTL) else { continue }
            if let layer = rippleLayer(atTopLeft: outPtTL, progress: ripple.progress, outputSize: outputSize) {
                image = layer.composited(over: image)
            }
        }

        // 5) Cursor at a FIXED on-screen size (does not scale with zoom).
        if let cursor = frame.cursor {
            let outPtTL = CameraGeometry.projectPointTopLeft(
                cursor, camera: frame.camera, sourceSize: sourceSize,
                contentRect: content, outputSize: outputSize)
            if content.insetBy(dx: -2, dy: -2).contains(outPtTL) {
                image = cursorLayer(atTopLeft: outPtTL, outputSize: outputSize).composited(over: image)
            }
        }

        return image.cropped(to: outRect)
    }

    /// Render an image into a pixel buffer (export path). Pass an sRGB color space explicitly or
    /// colors shift (§5.4).
    func render(_ image: CIImage, to buffer: CVPixelBuffer, size: CGSize) {
        ciContext.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
    }

    // MARK: Layers

    private func background(_ style: BackgroundStyle, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        switch style {
        case let .solid(c):
            return CIImage(color: ci(c)).cropped(to: rect)
        case let .linearGradient(from, to, angle):
            let f = CIFilter.linearGradient()
            let rad = angle * .pi / 180
            let r = max(size.width, size.height)
            let cx = size.width / 2, cy = size.height / 2
            f.point0 = CGPoint(x: cx - cos(rad) * r / 2, y: cy - sin(rad) * r / 2)
            f.point1 = CGPoint(x: cx + cos(rad) * r / 2, y: cy + sin(rad) * r / 2)
            f.color0 = ci(from)
            f.color1 = ci(to)
            return (f.outputImage ?? CIImage(color: ci(from))).cropped(to: rect)
        case let .image(path):
            if let img = CIImage(contentsOf: URL(fileURLWithPath: path)) {
                return Self.aspectFill(img, to: rect)
            }
            return CIImage(color: ci(.black)).cropped(to: rect)
        }
    }

    /// Scale a CIImage to fill `rect` (aspect-fill), centered — for image backgrounds.
    private static func aspectFill(_ image: CIImage, to rect: CGRect) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let scale = max(rect.width / ext.width, rect.height / ext.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let s = scaled.extent
        return scaled
            .transformed(by: CGAffineTransform(translationX: rect.midX - s.midX, y: rect.midY - s.midY))
            .cropped(to: rect)
    }

    private func shadow(theme: Theme, content: CGRect, outputSize: CGSize) -> CIImage {
        guard let mask = Masks.roundedRect(size: content.size, cornerRadius: theme.cornerRadius) else {
            return CIImage.empty()
        }
        // Black silhouette at the card's shape, built at origin.
        let silhouette = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: theme.shadow.opacity))
            .cropped(to: CGRect(origin: .zero, size: content.size))
            .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputMaskImageKey: mask])
        // Place at the content rect (CI space), pushed DOWN by offsetY (top-left down = CI −y).
        let ciOrigin = toCI(content, outputSize).origin
        return silhouette
            .transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y - theme.shadow.offsetY))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: theme.shadow.blurRadius])
    }

    private func roundCorners(_ image: CIImage, content: CGRect, outputSize: CGSize, radius: Double) -> CIImage {
        guard radius > 0, let mask = Masks.roundedRect(size: content.size, cornerRadius: radius) else {
            return image
        }
        let ciOrigin = toCI(content, outputSize).origin
        let placedMask = mask.transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y))
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputMaskImageKey: placedMask])
    }

    private func cursorLayer(atTopLeft p: CGPoint, outputSize: CGSize) -> CIImage {
        // Align the arrow tip (hotspot) to p. Convert the sprite's top-left origin to CI.
        let originX = p.x - CursorSprite.hotspot.x
        let topLeftY = p.y - CursorSprite.hotspot.y
        let ciY = outputSize.height - topLeftY - CursorSprite.size.height
        return cursorImage.transformed(by: CGAffineTransform(translationX: originX, y: ciY))
    }

    /// An expanding, fading ring centered at a click. Radius grows and alpha fades with progress.
    private func rippleLayer(atTopLeft p: CGPoint, progress: Double, outputSize: CGSize) -> CIImage? {
        let maxRadius = 46.0
        let radius = 8 + maxRadius * progress
        let alpha = max(0, 0.55 * (1 - progress))
        guard let ring = RippleSprite.ring(radius: radius, lineWidth: 3, alpha: alpha) else { return nil }
        // Center the ring sprite (its own center = the click point). Convert to CI space.
        let ext = ring.extent
        let originX = p.x - ext.width / 2
        let ciY = outputSize.height - p.y - ext.height / 2
        return ring.transformed(by: CGAffineTransform(translationX: originX, y: ciY))
    }

    // MARK: Helpers

    /// Convert a top-left output rect to Core Image (bottom-left) space.
    private func toCI(_ r: CGRect, _ outputSize: CGSize) -> CGRect {
        CGRect(x: r.minX, y: outputSize.height - r.maxY, width: r.width, height: r.height)
    }

    private func ci(_ c: RGBAColor) -> CIColor {
        CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a, colorSpace: colorSpace)
            ?? CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
