// license:BSD-3-Clause
//
// RomArt - the game's own pixels, from the ROM's graphics (gfx1) and palette
// (proms), for textures: the round's background pattern for the floor.  The
// decoder tells which tiles are what; this turns codes into images.  (All
// the objects are 3D models; the floor texture is optional and may go.)
//
// Built by whichever source supplies game state (MAME or a replay) once per
// game, then read-only, so it's shared across threads.

import CoreGraphics
import Foundation

final class RomArt: @unchecked Sendable {
    private let gfx: [UInt8]                    // ARK3D_GFX_BYTES
    private let palette: [SIMD3<UInt8>]         // ARK3D_NUM_PENS

    init?(gfx: UnsafePointer<UInt8>?, gfxBytes: Int, graphics: UnsafePointer<ark3d_graphics>) {
        guard let gfx, gfxBytes >= Int(ARK3D_GFX_BYTES), graphics.pointee.valid != 0 else { return nil }
        self.gfx = Array(UnsafeBufferPointer(start: gfx, count: Int(ARK3D_GFX_BYTES)))
        var palette: [SIMD3<UInt8>] = []
        withUnsafeBytes(of: graphics.pointee.rgb) { raw in
            for i in 0..<Int(ARK3D_NUM_PENS) {
                palette.append(SIMD3(raw[3 * i], raw[3 * i + 1], raw[3 * i + 2]))
            }
        }
        self.palette = palette
    }

    func rgb(color: Int, pen: Int) -> SIMD3<UInt8> {
        palette[((color & 63) * 8 + (pen & 7)) & (Int(ARK3D_NUM_PENS) - 1)]
    }

    private func pen(_ code: Int, _ px: Int, _ py: Int) -> Int {
        gfx.withUnsafeBufferPointer { Int(ark3d_char_pen($0.baseAddress, Int32(code), Int32(px), Int32(py))) }
    }

    /// Pen at view pixel (u, v) of an 8x8 background tile (the game is ROT90:
    /// view x runs down the character's rows, view y along its columns).
    func tilePen(code: Int, u: Int, v: Int) -> Int { pen(code, v, 7 - u) }

    // MARK: - images

    /// The round's background under the whole playfield (view pixels
    /// field_left..field_right x field_top..field_bottom), with bricks, shadows
    /// and anything else lifted off: every cell shows the background tile that
    /// belongs there.  The pattern repeats every 3 columns and 4 rows, and the
    /// band the decoder learns it from (rows 26-29) has a lit copy of each.
    /// Returns nil if there's no round on screen or the band is incomplete.
    func backgroundImage(_ state: UnsafePointer<ark3d_state>, layout: ark3d_layout, scale: Int) -> CGImage? {
        let s = state.pointee
        guard s.in_play != 0 else { return nil }
        let colMin = Int(layout.field_left) / 8, colMax = Int(layout.field_right) / 8
        let rowMin = Int(layout.field_top) / 8, rowMax = Int(layout.field_bottom) / 8
        let bandTop = Int(layout.reference_top) / 8
        let codes = withUnsafeBytes(of: s.tile_code) { Array($0.bindMemory(to: UInt16.self)) }
        let colors = withUnsafeBytes(of: s.tile_color) { Array($0.bindMemory(to: UInt8.self)) }
        let kinds = withUnsafeBytes(of: s.tile_kind) { Array($0.bindMemory(to: UInt8.self)) }
        let cols = Int(ARK3D_VIEW_COLS)
        let background = UInt8(ARK3D_KIND_BACKGROUND.rawValue)

        // lit background tile for each (column, row phase), from the band
        func source(_ c: Int, _ r: Int) -> (code: Int, color: Int)? {
            let phase = ((r - bandTop) % 4 + 4) % 4
            for dc in stride(from: 0, to: colMax - colMin, by: 3) {
                for cc in [c + dc, c - dc] where cc >= colMin && cc < colMax {
                    let i = (bandTop + phase) * cols + cc
                    if kinds[i] == background { return (Int(codes[i]), Int(colors[i])) }
                }
            }
            return nil
        }

        let w = (colMax - colMin) * 8, h = (rowMax - rowMin) * 8
        var pixels = [UInt8](repeating: 255, count: w * scale * h * scale * 4)
        for r in rowMin..<rowMax {
            for c in colMin..<colMax {
                let i = r * cols + c
                let tile = kinds[i] == background ? (Int(codes[i]), Int(colors[i])) : source(c, r)
                guard let (code, color) = tile else { return nil }
                for v in 0..<8 {
                    for u in 0..<8 {
                        let p = rgb(color: color, pen: tilePen(code: code, u: u, v: v))
                        let x0 = ((c - colMin) * 8 + u) * scale, y0 = ((r - rowMin) * 8 + v) * scale
                        for dy in 0..<scale {
                            var o = ((y0 + dy) * w * scale + x0) * 4
                            for _ in 0..<scale {
                                pixels[o] = p.x; pixels[o + 1] = p.y; pixels[o + 2] = p.z
                                o += 4
                            }
                        }
                    }
                }
            }
        }
        return Self.image(pixels, width: w * scale, height: h * scale)
    }

    private static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
