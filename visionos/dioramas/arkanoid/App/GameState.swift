// license:BSD-3-Clause
//
// GameState - reads the arkanoid driver's state out of libmame once per
// emulated frame (MAME thread, machine_frame callback), decodes it with
// ark3d (Decoder/ark3d.c) and hands the result to the renderer.
//
// What's read (all through the generic libmame API, nothing Arkanoid-specific
// in MAME itself):
//   shares  ":videoram" (e000-e7ff), ":spriteram" (e800-e83f)
//   regions ":gfx1" (tile/sprite graphics), ":proms" (palette), once per game
//   RAM     ":maincpu" program c000-c7ff, for the high score
//   save items of the driver (tag ":"): m_gfxbank, m_palettebank,
//           m_flip_screen_x, m_flip_screen_y (the write-only d008 latch)
// See ARKANOID_STATE.md.

import Foundation
import os
import libmame

private let log = Logger(subsystem: "org.mamedev.diorama.arkanoid", category: "state")

/// Latest decoded frame, handed from the MAME thread to RealityKit.
final class GameStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private let state = UnsafeMutablePointer<ark3d_state>.allocate(capacity: 1)
    private var serial = 0
    private var available = false

    init() { state.initialize(to: ark3d_state()) }

    private var _art: RomArt?
    /// The game's graphics, for textures; set by the state source once per game.
    var art: RomArt? {
        get { lock.lock(); defer { lock.unlock() }; return _art }
        set { lock.lock(); _art = newValue; lock.unlock() }
    }

    func publish(_ s: UnsafePointer<ark3d_state>) {
        lock.lock()
        state.update(from: s, count: 1)
        serial &+= 1
        available = true
        lock.unlock()
    }

    func clear() {
        lock.lock()
        available = false
        serial &+= 1
        lock.unlock()
    }

    /// Copies the latest state into `into` if it is newer than `since`.
    /// Returns the new serial, or nil if nothing changed or no game state exists.
    func copy(since: Int, into: UnsafeMutablePointer<ark3d_state>) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard serial != since, available else { return nil }
        into.update(from: state, count: 1)
        return serial
    }

    /// A few numbers for the HUD (any thread).
    struct Summary { var available = false; var bricks = 0; var score = -1; var highScore = -1; var balls = 0; var lives = -1 }
    func summary() -> Summary {
        lock.lock(); defer { lock.unlock() }
        guard available else { return Summary() }
        return Summary(available: true, bricks: Int(state.pointee.brick_count),
                       score: Int(state.pointee.score), highScore: Int(state.pointee.high_score),
                       balls: Int(state.pointee.ball_count),
                       lives: state.pointee.spare_lives >= 0 ? Int(state.pointee.spare_lives) + 1 : -1)
    }

    var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return available
    }
}

/// Runs on the MAME thread: libmame hooks -> ark3d_decode -> GameStateStore.
final class ArkanoidStateReader: @unchecked Sendable {
    static let shared = ArkanoidStateReader()

    let store = GameStateStore()
    let paddle = PaddleController()
    let quick = QuickStart()

    /// Sets from taito/arkanoid.cpp that run the original Arkanoid program
    /// (parents and clones; not Hexa, Tetris, Brixian or Cruisin 5).
    static let supportedSets: Set<String> = [
        "arkanoid", "arkanoidu", "arkanoiduo", "arkanoidj", "arkanoidja", "arkanoidjb", "arkanoidpe",
        "arkanoidjbl", "arkanoidjbl2", "ark1ball", "arkangc", "arkangc2", "arkblock", "arkbloc2", "arkbloc3",
        "block2", "arkgcbl", "arkgcbla", "paddle2", "arkatayt", "arktayt2", "arkaboot", "arkatour", "arkatour2",
    ]

    private let graphics = UnsafeMutablePointer<ark3d_graphics>.allocate(capacity: 1)
    private let decoded = UnsafeMutablePointer<ark3d_state>.allocate(capacity: 1)
    private let calibration = UnsafeMutablePointer<ark3d_calibration>.allocate(capacity: 1)
    private var layout = ark3d_layout()

    private var supported = false
    private var ready = false
    private var videoram = myosd_memory_block()
    private var spriteram = myosd_memory_block()
    private var bankItems: [myosd_memory_block?] = [nil, nil, nil, nil]  // gfxbank, palettebank, flip x, flip y
    private var workRAM = [UInt8](repeating: 0, count: 0x800)
    private var highRAM = [UInt8](repeating: 0, count: Int(ARK3D_HIGH_RAM_BYTES))   // e840-efff: DOH's hits

    private init() {
        graphics.initialize(to: ark3d_graphics())
        decoded.initialize(to: ark3d_state())
        calibration.initialize(to: ark3d_calibration())
        ark3d_default_calibration(calibration)
        ark3d_default_layout(&layout)
    }

    /// Wire the hooks into the shared engine (call once, before starting MAME).
    func install(on engine: MAMEEngine) {
        engine.onGameInit = { [unowned self] info in self.gameInit(info) }
        engine.onGameExit = { [unowned self] in self.gameExit() }
        engine.onMachineFrame = { [unowned self] info in self.frame(info) }
    }

    // MARK: - MAME thread

    private func gameInit(_ info: myosd_game_info) {
        let name = info.name.map { String(cString: $0) } ?? ""
        supported = Self.supportedSets.contains(name)
        ready = false
        store.clear()
        paddle.reset()
        loadCalibration()
        log.info("game \(name, privacy: .public): 3D view \(self.supported ? "on" : "off (not an Arkanoid set)", privacy: .public)")
    }

    private func gameExit() {
        supported = false
        ready = false
        store.clear()
    }

    /// Look everything up on the first frame: shares and regions exist once
    /// the machine is running (not yet at game_init).
    private func setUp() {
        guard myosd_get_memory_share(":videoram", &videoram) == 0, videoram.bytes >= Int(ARK3D_VIDEORAM_BYTES),
              myosd_get_memory_share(":spriteram", &spriteram) == 0, spriteram.bytes >= Int(ARK3D_SPRITERAM_BYTES) else {
            log.error("videoram/spriteram shares not found; 3D view off")
            supported = false
            return
        }
        var gfx = myosd_memory_block(), proms = myosd_memory_block()
        let haveGfx = myosd_get_memory_region(":gfx1", &gfx) == 0
        let haveProms = myosd_get_memory_region(":proms", &proms) == 0
        ark3d_analyze_graphics(graphics,
                               haveGfx ? gfx.base?.assumingMemoryBound(to: UInt8.self) : nil, haveGfx ? gfx.bytes : 0,
                               haveProms ? proms.base?.assumingMemoryBound(to: UInt8.self) : nil, haveProms ? proms.bytes : 0)
        if graphics.pointee.valid == 0 {
            log.warning("gfx1/proms not usable: decoding without graphics (much less accurate)")
        }
        store.art = RomArt(gfx: haveGfx ? gfx.base?.assumingMemoryBound(to: UInt8.self) : nil,
                           gfxBytes: haveGfx ? gfx.bytes : 0, graphics: graphics)
        for (i, name) in ["m_gfxbank", "m_palettebank", "m_flip_screen_x", "m_flip_screen_y"].enumerated() {
            var block = myosd_memory_block()
            bankItems[i] = myosd_get_state_item(":", name, &block) == 0 ? block : nil
            if bankItems[i] == nil { log.warning("save item \(name, privacy: .public) not found, assuming 0") }
        }
        ready = true
    }

    private func readItem(_ i: Int) -> Int32 {
        guard let block = bankItems[i], let base = block.base else { return 0 }
        switch block.bitwidth {
        case 8:  return Int32(base.load(as: UInt8.self))
        case 16: return Int32(base.load(as: UInt16.self))
        case 32: return Int32(bitPattern: base.load(as: UInt32.self))
        default: return 0
        }
    }

    private func frame(_ info: myosd_frame_info) {
        guard supported else { return }
        if !ready {
            setUp()
            guard ready else { return }
        }
        guard let vram = videoram.base?.assumingMemoryBound(to: UInt8.self),
              let sram = spriteram.base?.assumingMemoryBound(to: UInt8.self) else { return }

        let gotRAM = workRAM.withUnsafeMutableBytes { raw in
            myosd_read_memory(":maincpu", Int32(MYOSD_AS_PROGRAM), 0xc000, raw.baseAddress, raw.count) == raw.count
        }

        let gotHighRAM = highRAM.withUnsafeMutableBytes { raw in
            myosd_read_memory(":maincpu", Int32(MYOSD_AS_PROGRAM), UInt32(ARK3D_HIGH_RAM_BASE), raw.baseAddress, raw.count) == raw.count
        }

        workRAM.withUnsafeBufferPointer { ram in highRAM.withUnsafeBufferPointer { high in
            var input = ark3d_input()
            input.videoram = UnsafePointer(vram)
            input.spriteram = UnsafePointer(sram)
            input.gfxbank = readItem(0)
            input.palettebank = readItem(1)
            input.flip_x = readItem(2)
            input.flip_y = readItem(3)
            input.work_ram = gotRAM ? ram.baseAddress : nil
            input.work_ram_bytes = gotRAM ? ram.count : 0
            input.high_ram = gotHighRAM ? high.baseAddress : nil
            input.high_ram_bytes = gotHighRAM ? high.count : 0
            ark3d_decode(&input, &layout, graphics.pointee.valid != 0 ? UnsafePointer(graphics) : nil,
                         UnsafePointer(calibration), decoded)
        } }

        paddle.frame(state: decoded, layout: layout)
        quick.frame(state: decoded)
        store.publish(decoded)
        PerfLog.shared.emulatedFrame()
    }

    // MARK: - calibration

    /// The verified code tables (ark3d_default_calibration), plus optional
    /// overrides from Documents/arkanoid-diorama.json, e.g.
    ///   { "tiles":    { "0x1a0": "gold", "0x1a1": "gold", "0x1c0": "silver" },
    ///     "sprites":  { "0x010": "vaus", "0x011": "vaus", "0x020": "ball" },
    ///     "capsules": { "0x040": "L" },
    ///     "layout":   { "grid_top": 32, "grid_rows": 18 } }
    /// Codes include the gfx bank (+0x800 for tiles, +0x400 for sprites).
    /// Kind names are ark3d_kind_name()'s.  See README.md for how to find codes.
    private func loadCalibration() {
        ark3d_default_calibration(calibration)
        ark3d_default_layout(&layout)
        let url = MAMEEngine.prepareDocuments().appendingPathComponent("arkanoid-diorama.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        var kinds: [String: UInt8] = [:]
        for k in 0..<Int32(ARK3D_KIND_COUNT.rawValue) {
            kinds[String(cString: ark3d_kind_name(k))] = UInt8(k)
        }
        var capsules: [String: UInt8] = [:]
        for c in 1..<Int32(ARK3D_CAPSULE_COUNT.rawValue) {
            capsules[String(cString: ark3d_capsule_name(c))] = UInt8(c)
        }
        func code(_ s: String) -> Int? { s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }

        withUnsafeMutableBytes(of: &calibration.pointee.tile_kind) { raw in
            for (key, value) in (json["tiles"] as? [String: String]) ?? [:] {
                if let c = code(key), c >= 0, c < raw.count, let k = kinds[value] { raw[c] = k }
            }
        }
        withUnsafeMutableBytes(of: &calibration.pointee.sprite_kind) { raw in
            for (key, value) in (json["sprites"] as? [String: String]) ?? [:] {
                if let c = code(key), c >= 0, c < raw.count, let k = kinds[value] { raw[c] = k }
            }
        }
        withUnsafeMutableBytes(of: &calibration.pointee.sprite_capsule) { raw in
            for (key, value) in (json["capsules"] as? [String: String]) ?? [:] {
                if let c = code(key), c >= 0, c < raw.count, let k = capsules[value] { raw[c] = k }
            }
        }
        if let l = json["layout"] as? [String: Int] {
            func set(_ key: String, _ path: WritableKeyPath<ark3d_layout, Int32>) {
                if let v = l[key] { layout[keyPath: path] = Int32(v) }
            }
            set("field_left", \.field_left); set("field_right", \.field_right)
            set("field_top", \.field_top); set("field_bottom", \.field_bottom)
            set("grid_left", \.grid_left); set("grid_top", \.grid_top)
            set("grid_cols", \.grid_cols); set("grid_rows", \.grid_rows)
            set("brick_w", \.brick_w); set("brick_h", \.brick_h)
            set("reference_top", \.reference_top); set("reference_bottom", \.reference_bottom)
            set("vaus_min_y", \.vaus_min_y)
        }
        log.info("loaded calibration from \(url.path, privacy: .public)")
    }
}
