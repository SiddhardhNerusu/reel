import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// CoreText → CIImage rendering for burned-in text (captions, the trial watermark). CoreGraphics
/// only — no AppKit — so it stays test-target friendly like the other sprites (§5.4).
enum TextSprite {

    /// A caption chip: bold rounded text on a soft dark pill, the short-form-video idiom.
    /// `fontSize` in output pixels. Cached by the caller (Compositor) per unique string+size.
    static func caption(_ text: String, fontSize: CGFloat) -> CIImage? {
        let font = CTFontCreateWithName("SFPro-Semibold" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard width > 0 else { return nil }

        let padX = fontSize * 0.55, padY = fontSize * 0.32
        let w = Int((width + padX * 2).rounded(.up))
        let h = Int((ascent + descent + padY * 2).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Soft dark pill behind the text (readable over any footage).
        let r = CGFloat(h) / 2
        let pill = CGPath(roundedRect: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                          cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.addPath(pill)
        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 0.72))
        ctx.fillPath()

        ctx.textPosition = CGPoint(x: padX, y: descent + padY)
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    /// The trial watermark: a quiet "● Made with Reel" chip (brief §2.5 — the watermark IS the
    /// trial mechanic; tasteful, corner, never nagging).
    static func watermark(fontSize: CGFloat = 26) -> CIImage? {
        let font = CTFontCreateWithName("SFPro-Medium" as CFString, fontSize, nil)
        let dot: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 0.886, green: 0.639, blue: 0.243, alpha: 1),
        ]
        let txt: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
        ]
        let s = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(s, CFRange(), "● Made with Reel" as CFString)
        CFAttributedStringSetAttributes(s, CFRange(location: 0, length: 1), dot as CFDictionary, true)
        CFAttributedStringSetAttributes(s, CFRange(location: 1, length: CFAttributedStringGetLength(s) - 1),
                                        txt as CFDictionary, true)
        let line = CTLineCreateWithAttributedString(s)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard width > 0 else { return nil }

        let padX = fontSize * 0.6, padY = fontSize * 0.38
        let w = Int((width + padX * 2).rounded(.up))
        let h = Int((ascent + descent + padY * 2).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGFloat(h) / 2
        let pill = CGPath(roundedRect: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                          cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.addPath(pill)
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.07, blue: 0.06, alpha: 0.62))
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: padX, y: descent + padY)
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
