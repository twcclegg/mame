// license:BSD-3-Clause
//
// ArkModel - UI state for Arkanoid Diorama: which ROM sets are present, whether
// MAME is running, the presentation options.

import Foundation
import Observation
import libmame

@Observable
final class ArkModel {
    static let shared = ArkModel()

    /// Arkanoid sets found in Documents/roms.
    var sets: [String] = []
    var selected: String = "arkanoid"
    var running = false
    var volumeOpen = false
    var arenaOpen = false

    var paddleSource: PaddleController.Source = .pinch {
        didSet { ArkanoidStateReader.shared.paddle.source = paddleSource }
    }
    /// How far the Vaus moves per unit of pinch / hand movement.
    var paddleSensitivity: Float = 2 {
        didSet { ArkanoidStateReader.shared.paddle.sensitivity = paddleSensitivity }
    }
    /// How the controller's left stick moves the Vaus.
    var stickMode: PaddleController.StickMode = .speed {
        didSet { ArkanoidStateReader.shared.paddle.stickMode = stickMode }
    }
    /// The original 2D picture as a small screen behind the playfield.
    var showOriginalScreen = true
    /// The floor shows the round's background from the game, or a plain one.
    var showGameBackground = ProcessInfo.processInfo.environment["DIORAMA_BACKGROUND"] != "0"

    private init() {
        ArkanoidStateReader.shared.install(on: MAMEEngine.shared)
        ArkanoidStateReader.shared.paddle.source = paddleSource
        ArkanoidStateReader.shared.paddle.sensitivity = paddleSensitivity
        PresentSettings.effect = .sharp
        // MAME lays its UI and the software-rendered frame out for this size;
        // Arkanoid is 256x224 native, so 3x is plenty for the debug screen.
        MAMEEngine.shared.renderSize = (width: 768, height: 896)
    }

    /// Development: playing a capture instead of running MAME (ReplayPlayer).
    private(set) var replaying = false
    private var replay: ReplayPlayer?

    /// Starts a replay if DIORAMA_REPLAY is set.  Returns whether it did.
    func startReplayIfRequested() -> Bool {
        guard !running, !replaying, let options = ReplayPlayer.optionsFromEnvironment(),
              let player = ReplayPlayer(url: options.url) else { return false }
        replay = player
        replaying = true
        showOriginalScreen = false              // no MAME, no 2D picture
        player.start(store: ArkanoidStateReader.shared.store, options: options)
        return true
    }

    func refresh() {
        let dir = MAMEEngine.prepareDocuments().appendingPathComponent("roms")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        sets = Set(names.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() })
            .intersection(ArkanoidStateReader.supportedSets)
            .sorted()
        if !sets.contains(selected), let first = sets.first {
            selected = first
        }
    }

    // Buttons for playing without a controller (the HUD, the control window,
    // pinches); they press player 1's buttons alongside any gamepad.
    // Each also lets a quick-started game go (QuickStart holds it, ready, until then).
    func insertCoin() { press(MYOSD_SELECT.rawValue) }
    func pressStart() { press(MYOSD_START.rawValue) }
    /// Fire / launch (button 1).
    func fire() { press(MYOSD_A.rawValue) }

    private func press(_ bits: UInt32) {
        ArkanoidStateReader.shared.quick.release()
        MAMEEngine.shared.input.pulseVirtual(bits)
    }

    /// Round 1 again, ready to play.
    func newGame() {
        guard running else { launch(); return }
        ArkanoidStateReader.shared.quick.restart(set: selected)
    }

    /// The volume calls autoStart() once, when it first appears.
    var didAutoStart = false

    /// At app launch: straight into a game (QuickStart), unless there's no ROM
    /// set yet.  Returns false then, so the caller can show the control window.
    func autoStart() -> Bool {
        refresh()
        guard !running, !replaying else { return true }
        // launch arguments (e.g. `xcrun simctl launch booted <id> arkanoid`) pick the set
        let args = MAMEEngine.stripSystemArguments(Array(CommandLine.arguments.dropFirst()))
        if let first = args.first {
            selected = first
            launch(extraArguments: Array(args.dropFirst()))
            return true
        }
        guard !sets.isEmpty else { return false }
        launch()
        return true
    }

    /// Clones (e.g. arkanoidj) also need the parent set's zip; MAME finds it in the same folder.
    /// `quick`: straight to round 1, ready to play (QuickStart).
    func launch(extraArguments: [String] = [], quick: Bool = true) {
        guard !running else { return }
        running = true
        let quickStart = ArkanoidStateReader.shared.quick
        let quickArgs = quick ? quickStart.arguments(for: selected) : []
        MAMEEngine.shared.start(arguments: [selected] + quickArgs + extraArguments) { [weak self] in
            quickStart.stop()
            self?.running = false
        }
    }
}
