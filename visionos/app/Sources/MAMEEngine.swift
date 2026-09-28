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

/// Latest emulator frame, handed from the MAME thread to the renderer.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels = [UInt32]()
    private(set) var width = 0
    private(set) var height = 0
    private(set) var serial = 0

    func store(_ src: UnsafePointer<UInt32>, width: Int, height: Int, pitch: Int) {
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
        self.width = width
        self.height = height
        serial &+= 1
    }

    /// Calls body with the latest frame if it is newer than `since`.
    func read(since: Int, _ body: (UnsafePointer<UInt32>, Int, Int, Int) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard serial != since, width > 0, height > 0 else { return }
        pixels.withUnsafeBufferPointer { body($0.baseAddress!, width, height, serial) }
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

    func start(arguments: [String]) {
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
            DispatchQueue.main.async { self.thread = nil }
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
        callbacks.video_draw_pixels = { pixels, width, height, pitch in
            guard let pixels else { return }
            MAMEEngine.shared.frames.store(pixels, width: Int(width), height: Int(height), pitch: Int(pitch))
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
    private static func stripSystemArguments(_ args: [String]) -> [String] {
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
    private static func prepareDocuments() -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for dir in ["roms", "cfg", "nvram", "ini", "artwork", "samples", "snap", "sta"] {
            try? fm.createDirectory(at: docs.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        return docs
    }
}
