// license:BSD-3-Clause
//
// MAMEVision - minimal visionOS host for libmame.
//
// Launch arguments are passed through to MAME, e.g.
//   xcrun simctl launch booted org.mamedev.mamevision pacman
// With no arguments MAME shows its own system-selection menu (drive it with
// a game controller: d-pad + A/B; see GameControllerInput for combos).
// ROMs go in the app's Documents/roms (Files app / Finder file sharing).

import SwiftUI

@main
struct MAMEVisionApp: App {
    var body: some Scene {
        WindowGroup {
            FrameView(frames: MAMEEngine.shared.frames)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .background(.black)
                .onAppear {
                    MAMEEngine.shared.start(arguments: Array(CommandLine.arguments.dropFirst()))
                }
        }
        .defaultSize(width: 1280, height: 960)
        .windowResizability(.contentSize)
    }
}
