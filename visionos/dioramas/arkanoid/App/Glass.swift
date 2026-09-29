// license:BSD-3-Clause
//
// Glass - the bricks as luminous glass, and the studio light they reflect.
//
// RealityKit on visionOS has no refraction or transmission, so the look is
// built from what it does have:
//   - a clear, mirror-smooth tinted shell (transparent, clear-coated) that
//     reflects a designed studio environment (softboxes, coloured rim
//     strips) instead of whatever room it's in;
//   - a lit core inside it, the light that seems to live in the glass
//     (it blooms on visionOS 27);
//   - a caustic: a soft pool of the glass's colour on the board beside it,
//     as if light passed through it, prismatic for silver.
// Moving lights (PlayfieldScene) sweep reflections across it.
//
// DIORAMA_BRICKS=solid keeps the earlier opaque bricks.

import CoreGraphics
import Foundation
import RealityKit
import UIKit

enum BrickStyle {
    nonisolated static let glass = ProcessInfo.processInfo.environment["DIORAMA_BRICKS"] != "solid"
}

/// One brick: `shell` alone for the solid style; shell, core and caustic for glass.
@MainActor
final class GlassBrick: Entity {
    let shell = ModelEntity()
    private let core = ModelEntity()
    private let caustic = ModelEntity()

    required init() { super.init() }

    init(width: Float, height: Float, depth: Float) {
        super.init()
        shell.model = ModelComponent(mesh: .generateBox(width: width, height: height, depth: depth, cornerRadius: min(height, depth) * 0.28),
                                     materials: [SimpleMaterial()])
        addChild(shell)
        guard BrickStyle.glass else { return }
        core.model = ModelComponent(mesh: .generateBox(width: width * 0.6, height: height * 0.4, depth: depth * 0.4,
                                                       cornerRadius: min(height, depth) * 0.2),
                                    materials: [SimpleMaterial()])
        addChild(core)
        // on the board, nudged away from the key light (the viewer's upper left)
        caustic.model = ModelComponent(mesh: .generatePlane(width: width * 1.5, depth: depth * 2.6), materials: [SimpleMaterial()])
        caustic.position = [width * 0.1, -height / 2 + 0.0004, depth * 0.55]
        addChild(caustic)
    }

    /// Glass look for a brick of colour `rgb`; `kind` is ark3d's (silver,
    /// gold, or a coloured brick); `flashing` while the game animates a hit.
    func setGlass(rgb: (UInt8, UInt8, UInt8), kind: UInt8, flashing: Bool) {
        let look = GlassLook.for(rgb: rgb, kind: kind, flashing: flashing)
        shell.model?.materials = [look.shell]
        core.model?.materials = [look.core]
        caustic.model?.materials = [look.caustic]
    }

    /// For debris when the brick breaks.
    var pieceMaterial: RealityKit.Material? {
        BrickStyle.glass ? core.model?.materials.first : shell.model?.materials.first
    }
}

/// The three materials of a glass brick, cached per colour and kind.
@MainActor
struct GlassLook {
    let shell: RealityKit.Material
    let core: RealityKit.Material
    let caustic: RealityKit.Material

    private static var cache: [UInt32: GlassLook] = [:]
    private static var causticTexture: TextureResource?
    private static var prismTexture: TextureResource?

    static func `for`(rgb: (UInt8, UInt8, UInt8), kind: UInt8, flashing: Bool) -> GlassLook {
        let key = UInt32(rgb.0) << 16 | UInt32(rgb.1) << 8 | UInt32(rgb.2) | UInt32(kind) << 24 | (flashing ? 1 << 31 : 0)
        if let look = cache[key] { return look }
        let silver = kind == UInt8(ARK3D_KIND_BRICK_SILVER.rawValue)
        let gold = kind == UInt8(ARK3D_KIND_BRICK_GOLD.rawValue)
        var c = SIMD3<Float>(Float(rgb.0), Float(rgb.1), Float(rgb.2)) / 255
        if silver { c = [0.85, 0.92, 1] }
        if gold { c = [1, 0.72, 0.22] }
        let color = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        let tint = c * 0.75 + SIMD3(repeating: 0.25)

        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: UIColor(red: CGFloat(tint.x), green: CGFloat(tint.y), blue: CGFloat(tint.z), alpha: 1))
        shell.metallic = .init(floatLiteral: gold ? 0.35 : 0)
        shell.roughness = .init(floatLiteral: 0.03)
        shell.specular = .init(floatLiteral: 1)
        shell.clearcoat = .init(floatLiteral: 1)
        shell.clearcoatRoughness = .init(floatLiteral: 0)
        shell.blending = .transparent(opacity: .init(floatLiteral: silver ? 0.4 : 0.5))

        var core = PhysicallyBasedMaterial()
        core.baseColor = .init(tint: .black)
        core.emissiveColor = .init(color: flashing ? .white : color)
        core.emissiveIntensity = flashing ? 5 : (silver ? 1.1 : 1.4)
        core.roughness = .init(floatLiteral: 0.4)

        var caustic = UnlitMaterial(color: silver ? .white : color)
        if let t = silver ? prismTexture ?? makePrism() : causticTexture ?? makeCaustic() {
            caustic.color = .init(tint: silver ? .white : color, texture: .init(t))
        }
        caustic.blending = .transparent(opacity: .init(floatLiteral: silver ? 0.8 : 0.7))

        let look = GlassLook(shell: shell, core: core, caustic: caustic)
        cache[key] = look
        return look
    }

    /// A soft pool of light: white in the middle, fading out (alpha).
    private static func makeCaustic() -> TextureResource? {
        causticTexture = pool { d, _ in (1, 1, 1, pow(max(0, 1 - d), 2.2)) }
        return causticTexture
    }

    /// The same pool split into a spectrum along its length, for silver.
    private static func makePrism() -> TextureResource? {
        prismTexture = pool { d, u in
            let hue = u
            let rgb = hsv(hue, 0.55, 1)
            return (rgb.0, rgb.1, rgb.2, pow(max(0, 1 - d), 2.0))
        }
        return prismTexture
    }

    private static func pool(_ f: (Float, Float) -> (Float, Float, Float, Float)) -> TextureResource? {
        let w = 128, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let u = (Float(x) + 0.5) / Float(w), v = (Float(y) + 0.5) / Float(h)
                let d = min(1, simd_length(SIMD2((u - 0.5) * 2, (v - 0.5) * 2)))
                let (r, g, b, a) = f(d, u)
                let i = (y * w + x) * 4
                px[i] = UInt8(r * a * 255); px[i + 1] = UInt8(g * a * 255); px[i + 2] = UInt8(b * a * 255); px[i + 3] = UInt8(a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color))
    }

    private static func hsv(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

/// A studio for the glass to reflect: dark indigo, a row of softboxes above,
/// a warm rim strip on one side and a cool one on the other.
@MainActor
enum GlassStudio {
    static func environment() async -> EnvironmentResource? {
        let w = 1024, h = 512
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext's origin is bottom-left: y = h is the top of the sky
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: [CGColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1),
                                      CGColor(red: 0.07, green: 0.06, blue: 0.16, alpha: 1),
                                      CGColor(red: 0.03, green: 0.03, blue: 0.08, alpha: 1)] as CFArray,
                             locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        func softbox(_ x: Int, _ y: Int, _ bw: Int, _ bh: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            for k in stride(from: 10, through: 0, by: -1) {       // a soft edge
                let grow = CGFloat(k) * 3
                ctx.setFillColor(red: r, green: g, blue: b, alpha: k == 0 ? 1 : 0.08)
                ctx.fill(CGRect(x: CGFloat(x) - grow, y: CGFloat(y) - grow, width: CGFloat(bw) + 2 * grow, height: CGFloat(bh) + 2 * grow))
            }
        }
        for i in 0..<4 { softbox(90 + i * 250, 400, 120, 40, 1, 1, 1) }   // overhead softboxes
        softbox(0, 250, 1024, 10, 1, 0.55, 0.2)                           // warm horizon strip
        softbox(380, 300, 180, 14, 0.3, 0.8, 1)                           // cool strip in front
        softbox(870, 320, 90, 60, 1, 0.3, 0.8)                            // magenta accent
        guard let image = ctx.makeImage() else { return nil }
        return try? await EnvironmentResource(equirectangular: image, withName: "diorama-studio")
    }
}
