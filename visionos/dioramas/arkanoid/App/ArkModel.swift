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

    private init() {
        ArkanoidStateReader.shared.install(on: MAMEEngine.shared)
        ArkanoidStateReader.shared.paddle.source = paddleSource
        PresentSettings.effect = .sharp
        // MAME lays its UI and the software-rendered frame out for this size;
        // Arkanoid is 256x224 native, so 3x is plenty for the debug screen.
        MAMEEngine.shared.renderSize = (width: 768, height: 896)
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
