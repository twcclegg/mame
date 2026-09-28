// license:BSD-3-Clause
//
// MAMEVision - visionOS host for libmame.
//
// The main window lists ROM sets in the app's Documents/roms (Files app /
// Finder file sharing) and shows the game once one is running.  Launch
// arguments are passed through to MAME, e.g.
//   xcrun simctl launch booted org.mamedev.mamevision pacman
// "Theater" moves the picture to a large screen in an immersive space.
// Game controller combos are listed in GameControllerInput.swift.

import SwiftUI

@main
struct MAMEVisionApp: App {
    static let theaterID = "theater"

    @State private var immersion: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 960)

        // mixed: the screen floats in your room; full: a dark theater
        ImmersiveSpace(id: Self.theaterID) {
            TheaterView()
        }
        .immersionStyle(selection: $immersion, in: .mixed, .full)
    }
}
