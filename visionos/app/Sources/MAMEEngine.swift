// license:BSD-3-Clause
//
// MAMEEngine - runs libmame (src/osd/ios/libmame.h) on its own thread and
// bridges its C callbacks to Swift.
//
// Video uses the optional video_draw_pixels callback: MAME rasterizes each
// frame with its software renderer and hands us a BGRA buffer, which we copy
// into a FrameStore for the Metal view to pick up.  (The primitive-list
// video_draw path is what a later spatial renderer will use.)

import Foundation
import AVFoundation
import os
import libmame

private let log = Logger(subsystem: "org.mamedev.mamevision", category: "mame")

/// Describes the frame currently held by a FrameStore.
struct FrameInfo {
    var width = 0           // framebuffer size (an integer multiple of the source size)
    var height = 0
    var sourceWidth = 0     // machine's native resolution, for scanline/mask effects
    var sourceHeight = 0
    var aspect: Float = 4.0 / 3.0   // intended display aspect (pixels may be non-square)
    var serial = 0
}

/// Latest emulator frame, handed from the MAME thread to the renderers.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels = [UInt32]()
    private var info = FrameInfo()

    func store(_ frame: myosd_video_frame) {
        guard let src = frame.pixels, frame.width > 0, frame.height > 0 else { return }
        let width = Int(frame.width), height = Int(frame.height), pitch = Int(frame.pitch)
        lock.lock()
        defer { lock.unlock() }
        if pixels.count < width * height {
            pixels = [UInt32](repeating: 0, count: width * height)
        }
        pixels.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                (dst.baseAddress! + y * width).update(from: src + y * pitch, count: width)
            }
        }
        info.width = width
        info.height = height
        info.sourceWidth = Int(frame.source_width)
        info.sourceHeight = Int(frame.source_height)
        info.aspect = frame.aspect > 0 ? frame.aspect : Float(width) / Float(height)
        info.serial &+= 1
    }

    /// Calls body with the latest frame if it is newer than `since` (a previous serial).
    func read(since: Int, _ body: (UnsafePointer<UInt32>, FrameInfo) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard info.serial != since, info.width > 0, info.height > 0 else { return }
        pixels.withUnsafeBufferPointer { body($0.baseAddress!, info) }
    }
}

final class MAMEEngine: @unchecked Sendable {
    static let shared = MAMEEngine()

    let frames = FrameStore()
    let input = GameControllerInput()
    private var thread: Thread?

    /// Size MAME lays its render target out for.  The software renderer draws
    /// at this size; the GPU scales the result to the window.
    var renderSize = (width: 1280, height: 960)

    var isRunning: Bool { thread != nil }

    /// Runs MAME on its own thread; `onExit` is called on the main queue when it returns.
    func start(arguments: [String], onExit: @escaping () -> Void = {}) {
        guard thread == nil else { return }

        configureAudioSession()
        let documents = Self.prepareDocuments()

        let args = ["mame", "-rompath", "roms"] + Self.stripSystemArguments(arguments)
        log.info("starting MAME in \(documents.path, privacy: .public) with \(args.joined(separator: " "), privacy: .public)")

        let t = Thread { [self] in
            FileManager.default.changeCurrentDirectoryPath(documents.path)
            myosd_set(Int32(MYOSD_DISPLAY_WIDTH), renderSize.width)
            myosd_set(Int32(MYOSD_DISPLAY_HEIGHT), renderSize.height)
            let result = Self.runMAME(args)
            log.info("MAME exited with \(result)")
            DispatchQueue.main.async {
                self.thread = nil
                onExit()
            }
        }
        t.name = "MAME"
        t.stackSize = 16 << 20   // MAME's drivers and UI recurse deeply
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    // MARK: - libmame

    private static func runMAME(_ args: [String]) -> Int32 {
        var callbacks = myosd_callbacks()

        callbacks.output_text = { channel, text in
            guard let text else { return }
            let s = String(cString: text).trimmingCharacters(in: .newlines)
            if !s.isEmpty { log.log("\(s, privacy: .public)") }
        }
        callbacks.video_draw_pixels = { frame in
            guard let frame else { return }
            MAMEEngine.shared.frames.store(frame.pointee)
        }
        callbacks.input_poll = { state, size in
            guard let state, size >= MemoryLayout<myosd_input_state>.size else { return }
            MAMEEngine.shared.input.poll(into: state)
        }
        // sound callbacks left nil: libmame falls back to its own AudioQueue output

        // argv must stay alive for the whole run
        var cargs = args.map { strdup($0) }
        defer { cargs.forEach { free($0) } }
        return cargs.withUnsafeMutableBufferPointer { argv in
            myosd_main(Int32(argv.count), argv.baseAddress, &callbacks, MemoryLayout<myosd_callbacks>.size)
        }
    }

    // MARK: - setup

    /// Xcode and the OS add launch arguments such as `-NSDocumentRevisionsDebugMode YES`
    /// or `-AppleLanguages (en)`; MAME would reject them as unknown options.
    static func stripSystemArguments(_ args: [String]) -> [String] {
        var result: [String] = []
        var skipValue = false
        for arg in args {
            if skipValue { skipValue = false; continue }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") || arg.hasPrefix("-com.apple.") {
                skipValue = true
                continue
            }
            result.append(arg)
        }
        return result
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Documents is MAME's working directory; it is visible in the Files app.
    @discardableResult
    static func prepareDocuments() -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for dir in ["roms", "cfg", "nvram", "ini", "artwork", "samples", "snap", "sta"] {
            try? fm.createDirectory(at: docs.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        return docs
    }
}
