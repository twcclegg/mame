// license:BSD-3-Clause
//
// AppModel - UI state shared by the windows and the theater space.

import Foundation
import Observation
import simd

/// Screen presentation effect.  Raw values must match apply_effect() in Shaders.metal.
enum ScreenEffect: Int32, CaseIterable, Identifiable {
    case pixels = 0
    case sharp = 1
    case crt = 2

    var id: Int32 { rawValue }
    var label: String {
        switch self {
        case .pixels: return "Pixels"
        case .sharp:  return "Sharp"
        case .crt:    return "CRT"
        }
    }
}

/// Mirrors `struct PresentParams` in Shaders.metal (stride 32 on both sides).
struct PresentParams {
    var srcSize: SIMD2<Float>
    var dstSize: SIMD2<Float>
    var scale: SIMD2<Float>
    var effect: Int32
}

/// Effect as read by the renderers, which run outside SwiftUI's update cycle.
enum PresentSettings {
    private static let lock = NSLock()
    private static var _effect: ScreenEffect = .sharp
    static var effect: ScreenEffect {
        get { lock.lock(); defer { lock.unlock() }; return _effect }
        set { lock.lock(); _effect = newValue; lock.unlock() }
    }
}

@Observable
final class AppModel {
    static let shared = AppModel()

    /// MAME is running (a game or MAME's own menu).
    var running = false
    /// ROM sets found in Documents/roms (short names, e.g. "pacman").
    var roms: [String] = []
    var theaterOpen = false

    /// Mirrored into PresentSettings by the UI (onChange), for the renderers.
    var effect: ScreenEffect = PresentSettings.effect

    func refreshROMs() {
        let dir = MAMEEngine.prepareDocuments().appendingPathComponent("roms")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        roms = Set(names.compactMap { name -> String? in
            let url = URL(fileURLWithPath: name)
            switch url.pathExtension.lowercased() {
            case "zip", "7z": return url.deletingPathExtension().lastPathComponent
            case "": return name   // unpacked ROM directory
            default: return nil
            }
        }).sorted()
    }

    /// Start MAME with a game (short name), or with no game to get MAME's own menu.
    func launch(_ game: String?, extraArguments: [String] = []) {
        guard !running else { return }
        running = true
        let args = (game.map { [$0] } ?? []) + extraArguments
        MAMEEngine.shared.start(arguments: args) { [weak self] in
            self?.running = false
            self?.refreshROMs()
        }
    }
}
