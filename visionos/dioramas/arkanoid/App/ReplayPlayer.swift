// license:BSD-3-Clause
//
// ReplayPlayer - plays a capture recorded by lua/ark3d_capture.lua into the
// scene, instead of running MAME: the same decoder and calibration, so the
// scene sees exactly what it would have seen live.  A development tool for
// working on the scene's look (reproducible rounds, capsules, enemies, and a
// frame that can be held still), and the second source of game state next to
// MAME.
//
// Set with environment variables (from a shell: SIMCTL_CHILD_<name>=...
// before `xcrun simctl launch`):
//   DIORAMA_REPLAY       capture file, relative to Documents (or absolute)
//   DIORAMA_REPLAY_FROM  first frame number to play (default: the first)
//   DIORAMA_REPLAY_HOLD  1 = stay on that frame
//
// Captures contain the ROM's graphics: keep them out of the repository.

import Foundation
import os

private let log = Logger(subsystem: "org.mamedev.diorama.arkanoid", category: "replay")

final class ReplayPlayer: @unchecked Sendable {
    struct Options {
        var url: URL
        var from: UInt32 = 0
        var hold = false
    }

    static func optionsFromEnvironment() -> Options? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DIORAMA_REPLAY"], !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                      : MAMEEngine.prepareDocuments().appendingPathComponent(path)
        var options = Options(url: url)
        options.from = env["DIORAMA_REPLAY_FROM"].flatMap { UInt32($0) } ?? 0
        options.hold = env["DIORAMA_REPLAY_HOLD"] == "1"
        return options
    }

    // capture format: see Tests/ark3d_dump.c
    private static let headerBytes = 20
    private static let frameBytes = 12 + Int(ARK3D_VIDEORAM_BYTES) + Int(ARK3D_SPRITERAM_BYTES) + 0x800

    private let data: Data
    private var frameOffsets: [Int] = []
    private var frameNumbers: [UInt32] = []
    private let graphics = UnsafeMutablePointer<ark3d_graphics>.allocate(capacity: 1)
    private let calibration = UnsafeMutablePointer<ark3d_calibration>.allocate(capacity: 1)
    private let decoded = UnsafeMutablePointer<ark3d_state>.allocate(capacity: 1)
    private var layout = ark3d_layout()
    private var thread: Thread?

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= Self.headerBytes,
              data.prefix(8) == Data("ARK3DCAP".utf8) else {
            log.error("not a capture: \(url.path, privacy: .public)")
            return nil
        }
        self.data = data
        let gfxBytes = Int(data.readU32(at: 12)), promBytes = Int(data.readU32(at: 16))
        var offset = Self.headerBytes + gfxBytes + promBytes
        while offset + Self.frameBytes <= data.count {
            frameOffsets.append(offset)
            frameNumbers.append(data.readU32(at: offset + 4))
            offset += Self.frameBytes
        }
        guard !frameOffsets.isEmpty else { return nil }

        graphics.initialize(to: ark3d_graphics())
        calibration.initialize(to: ark3d_calibration())
        decoded.initialize(to: ark3d_state())
        ark3d_default_calibration(calibration)
        ark3d_default_layout(&layout)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            ark3d_analyze_graphics(graphics, base + Self.headerBytes, gfxBytes,
                                   base + Self.headerBytes + gfxBytes, promBytes)
        }
        log.info("replay \(url.lastPathComponent, privacy: .public): \(self.frameOffsets.count) frames")
    }

    /// Plays at the game's 60 Hz on its own thread, publishing to `store`.
    func start(store: GameStateStore, options: Options) {
        guard thread == nil else { return }
        data.withUnsafeBytes { raw in
            let gfxBytes = Int(data.readU32(at: 12))
            store.art = RomArt(gfx: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + Self.headerBytes,
                               gfxBytes: gfxBytes, graphics: graphics)
        }
        let first = frameNumbers.firstIndex { $0 >= options.from } ?? 0
        let t = Thread { [self] in
            var index = first
            var next = Date()
            while !Thread.current.isCancelled {
                decode(index)
                store.publish(decoded)
                if !options.hold {
                    index = index + 1 < frameOffsets.count ? index + 1 : first
                }
                next += 1.0 / 60
                Thread.sleep(until: next)
            }
        }
        t.name = "Replay"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func decode(_ index: Int) {
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + frameOffsets[index]
            var input = ark3d_input()
            input.gfxbank = Int32(base[8])
            input.palettebank = Int32(base[9])
            input.flip_x = Int32(base[10])
            input.flip_y = Int32(base[11])
            input.videoram = UnsafePointer(base + 12)
            input.spriteram = UnsafePointer(base + 12 + Int(ARK3D_VIDEORAM_BYTES))
            input.work_ram = UnsafePointer(base + 12 + Int(ARK3D_VIDEORAM_BYTES) + Int(ARK3D_SPRITERAM_BYTES))
            input.work_ram_bytes = 0x800
            ark3d_decode(&input, &layout, graphics.pointee.valid != 0 ? UnsafePointer(graphics) : nil,
                         UnsafePointer(calibration), decoded)
        }
    }
}

private extension Data {
    func readU32(at offset: Int) -> UInt32 {
        withUnsafeBytes { raw in
            var value: UInt32 = 0
            for i in (0..<4).reversed() { value = value << 8 | UInt32(raw[offset + i]) }
            return value
        }
    }
}
