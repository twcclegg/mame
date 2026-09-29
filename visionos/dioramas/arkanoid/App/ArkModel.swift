// license:BSD-3-Clause
//
// ArkModel - UI state for Arkanoid Diorama: which ROM sets are present, whether
// MAME is running, the presentation options.

import Foundation
import Observation

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
    /// The original 2D picture as a small screen behind the playfield.
    var showOriginalScreen = true
    /// The floor shows the round's background from the game, or a plain one.
    var showGameBackground = ProcessInfo.processInfo.environment["DIORAMA_BACKGROUND"] != "0"

    private init() {
        ArkanoidStateReader.shared.install(on: MAMEEngine.shared)
        ArkanoidStateReader.shared.paddle.source = paddleSource
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

    /// Clones (e.g. arkanoidj) also need the parent set's zip; MAME finds it in the same folder.
    func launch(extraArguments: [String] = []) {
        guard !running else { return }
        running = true
        MAMEEngine.shared.start(arguments: [selected] + extraArguments) { [weak self] in
            self?.running = false
        }
    }
}
