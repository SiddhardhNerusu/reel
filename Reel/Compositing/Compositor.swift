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
/// `@unchecked Sendable`: `CIContext`/`CIImage` are documented thread-safe, and the one mutable
/// member (the static-base cache) is guarded by its own lock — so the same compositor is used from
/// the preview handler, the offline export task, and the MainActor coordinator without a data race.
final class Compositor: @unchecked Sendable {

    let ciContext: CIContext
    let colorSpace: CGColorSpace
    private let cursorImage: CIImage

    // Background + shadow are identical on every frame of a render, but as a lazy CIImage recipe
    // they were re-EXECUTED per frame — including a full-canvas Gaussian blur, the single most
    // expensive node in the graph (visible as stuttering preview zooms). Render them to real
    // pixels once per (theme, size) and reuse.
    private let baseLock = NSLock()
    private var baseKey: String = ""
    private var baseImage: CIImage?

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
        var cursorScale: Double = 1   // drawn cursor size multiplier (1.0…2.0, Darkroom §2.4)
        var caption: String?          // burned-in caption line active this frame
        /// Trial watermark chip (EXPORT ONLY — the one sanctioned preview/export divergence,
        /// because the watermark IS the trial mechanic, brief §2.5).
        var watermark = false
    }

    /// Compose one output frame. `outputSize` is the final canvas size in pixels.
    func compose(source: CIImage, sourceSize: CGSize, frame: Frame, theme: Theme, outputSize: CGSize) -> CIImage {
        let outRect = CGRect(origin: .zero, size: outputSize)
        let content = CameraGeometry.contentRect(outputSize: outputSize, sourceSize: sourceSize,
                                                  paddingFraction: theme.paddingFraction)

        // 1+2) Background + drop shadow — static per (theme, size); served from the pixel cache.
        var image = staticBase(theme: theme, content: content, outputSize: outputSize)

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
                image = cursorLayer(atTopLeft: outPtTL, outputSize: outputSize,
                                    scale: frame.cursorScale).composited(over: image)
            }
        }

        // 6) Burned-in caption (Shorts-ready story) — bottom-center, inside platform safe areas.
        if let caption = frame.caption, !caption.isEmpty {
            let fontSize = max(18, outputSize.height * 0.030)
            if let chip = captionImage(caption, fontSize: fontSize) {
                let ext = chip.extent
                let x = (outputSize.width - ext.width) / 2
                // Vertical formats keep clear of the Reels/Shorts UI band (~18% bottom).
                let bottomInset = outputSize.height * (outputSize.height > outputSize.width ? 0.20 : 0.08)
                image = chip.transformed(by: CGAffineTransform(translationX: x, y: bottomInset))
                    .composited(over: image)
            }
        }

        // 7) Trial watermark, bottom-right corner.
        if frame.watermark, let wm = watermarkImage {
            let ext = wm.extent
            let margin = outputSize.height * 0.025
            image = wm.transformed(by: CGAffineTransform(
                translationX: outputSize.width - ext.width - margin, y: margin))
                .composited(over: image)
        }

        return image.cropped(to: outRect)
    }

    // Caption chips are rendered pixels cached per (text, size) — a line stays on screen for
    // dozens of frames; re-rendering CoreText each frame would waste the preview budget.
    private let captionLock = NSLock()
    private var captionKey = ""
    private var captionCache: CIImage?

    private func captionImage(_ text: String, fontSize: CGFloat) -> CIImage? {
        let key = "\(text)|\(Int(fontSize))"
        captionLock.lock()
        if captionKey == key, let cached = captionCache { captionLock.unlock(); return cached }
        captionLock.unlock()
        let img = TextSprite.caption(text, fontSize: fontSize)
        captionLock.lock()
        captionKey = key
        captionCache = img
        captionLock.unlock()
        return img
    }

    private lazy var watermarkImage: CIImage? = TextSprite.watermark()

    /// Render an image into a pixel buffer (export path). Pass an sRGB color space explicitly or
    /// colors shift (§5.4).
    func render(_ image: CIImage, to buffer: CVPixelBuffer, size: CGSize) {
        ciContext.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
    }

    // MARK: Layers

    /// Background + shadow composited and RENDERED to pixels, cached per (theme, content, size).
    /// Falls back to the lazy recipe if the render fails (identical output, just slower).
    private func staticBase(theme: Theme, content: CGRect, outputSize: CGSize) -> CIImage {
        let key = "\(theme.cacheKey)|\(content)|\(outputSize)"
        baseLock.lock()
        if baseKey == key, let cached = baseImage { baseLock.unlock(); return cached }
        baseLock.unlock()

        var image = background(theme.background, size: outputSize)
        if theme.shadow.opacity > 0 {
            image = shadow(theme: theme, content: content, outputSize: outputSize).composited(over: image)
        }
        let rect = CGRect(origin: .zero, size: outputSize)
        guard let cg = ciContext.createCGImage(image.cropped(to: rect), from: rect,
                                               format: .RGBA8, colorSpace: colorSpace) else {
            return image
        }
        let rendered = CIImage(cgImage: cg)
        baseLock.lock()
        baseKey = key
        baseImage = rendered
        baseLock.unlock()
        return rendered
    }

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
        case let .radialGradient(from, to):
            // Center slightly above middle (the artboards' lit-backdrop look), edges in `to`.
            let f = CIFilter.gaussianGradient()
            f.center = CGPoint(x: size.width / 2, y: size.height * 0.58)
            f.radius = Float(max(size.width, size.height) * 0.75)
            f.color0 = ci(from)
            f.color1 = ci(to)
            return (f.outputImage ?? CIImage(color: ci(to))).cropped(to: rect)
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

    private func cursorLayer(atTopLeft p: CGPoint, outputSize: CGSize, scale: Double = 1) -> CIImage {
        // Align the arrow tip (hotspot) to p. Convert the sprite's top-left origin to CI.
        let s = max(0.5, scale)
        let originX = p.x - CursorSprite.hotspot.x * s
        let topLeftY = p.y - CursorSprite.hotspot.y * s
        let ciY = outputSize.height - topLeftY - CursorSprite.size.height * s
        let scaled = s == 1 ? cursorImage : cursorImage.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return scaled.transformed(by: CGAffineTransform(translationX: originX, y: ciY))
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
