// license:BSD-3-Clause
//
// GeometryStore - latest 3D geometry frame exported by the running driver
// (libmame geometry_frame callback; src/emu/geomexport.h), copied off the
// MAME thread for per-game renderers.
//
// Camera space is +x right, +y up, +z forward (away from the viewer).  The
// game's own projection to its screen is
//     screen_x = centerX + (x/z) * scaleX + offsetX
//     screen_y = centerY - ((y/z) * scaleY + offsetY)
// so a renderer can match the original framing (e.g. a perspective camera
// with vertical FOV 2*atan((screenHeight/2) / scaleY)) and then render it in
// stereo, at any resolution, or as a diorama.

import Foundation
import simd
import libmame

struct GeometryPolygon {
    var vertices: [SIMD3<Float>]    // 3 or 4, camera space
    var rgb: SIMD3<Float>           // 0...1, already lit by the game
    var moire: Bool                 // stippled/translucent (shadows)
    var wireframe: Bool             // a line from vertices[0] to vertices[2]
    var sortZ: Float                // game's depth-sort key (larger = further)
}

struct GeometryBatch {
    var center: SIMD2<Float>
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var clipMin: SIMD2<Int32>
    var clipMax: SIMD2<Int32>
    var screenSize: SIMD2<Int32>
    var polygons: [GeometryPolygon]
}

final class GeometryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [GeometryBatch] = []
    private(set) var serial = 0

    /// Called on the MAME thread; copies everything (the C data is only valid during the call).
    func store(_ frame: myosd_geometry_frame) {
        var out: [GeometryBatch] = []
        if let cBatches = frame.batches {
            out.reserveCapacity(Int(frame.count))
            for b in UnsafeBufferPointer(start: cBatches, count: Int(frame.count)) {
                var polys: [GeometryPolygon] = []
                if let cPolys = b.polygons {
                    polys.reserveCapacity(Int(b.count))
                    for p in UnsafeBufferPointer(start: cPolys, count: Int(b.count)) {
                        var verts: [SIMD3<Float>] = []
                        withUnsafeBytes(of: p.v) { raw in
                            let v = raw.bindMemory(to: myosd_vertex.self)
                            for i in 0..<Int(min(max(p.count, 0), 4)) {
                                verts.append(SIMD3(v[i].x, v[i].y, v[i].z))
                            }
                        }
                        let rgb = SIMD3<Float>(Float((p.rgb >> 16) & 0xff),
                                               Float((p.rgb >> 8) & 0xff),
                                               Float(p.rgb & 0xff)) / 255
                        polys.append(GeometryPolygon(vertices: verts,
                                                     rgb: rgb,
                                                     moire: (p.flags & UInt32(MYOSD_POLY_MOIRE)) != 0,
                                                     wireframe: (p.flags & UInt32(MYOSD_POLY_WIREFRAME)) != 0,
                                                     sortZ: p.sort_z))
                    }
                }
                out.append(GeometryBatch(center: SIMD2(b.center_x, b.center_y),
                                         scale: SIMD2(b.scale_x, b.scale_y),
                                         offset: SIMD2(b.offset_x, b.offset_y),
                                         clipMin: SIMD2(b.clip_min_x, b.clip_min_y),
                                         clipMax: SIMD2(b.clip_max_x, b.clip_max_y),
                                         screenSize: SIMD2(b.screen_width, b.screen_height),
                                         polygons: polys))
            }
        }
        lock.lock()
        batches = out
        serial &+= 1
        lock.unlock()
    }

    /// Latest frame's batches and its serial (compare with a previous serial to skip unchanged frames).
    func latest() -> (batches: [GeometryBatch], serial: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (batches, serial)
    }
}
