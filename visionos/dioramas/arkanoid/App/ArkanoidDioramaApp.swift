// license:BSD-3-Clause
//
// Arkanoid Diorama - the original arcade Arkanoid, emulated by MAME (libmame,
// taito/arkanoid.cpp), presented as a RealityKit scene.  MAME runs the real
// game; every emulated frame its video RAM is decoded (Decoder/ark3d.c) and
// drives 3D bricks, Vaus, balls, capsules and enemies.  Sound is MAME's.
//
// Scenes: a control window, the table-top volume, and an immersive "arena".

import SwiftUI

@main
struct ArkanoidDioramaApp: App {
    static let controlsID = "controls"
    static let volumeID = "playfield"
    static let arenaID = "arena"

    @State private var model = ArkModel.shared

    var body: some Scene {
        WindowGroup(id: Self.controlsID) {
            ControlPanel()
        }
        .defaultSize(width: 560, height: 640)

        WindowGroup(id: Self.volumeID) {
            PlayfieldView(immersive: false)
                .onAppear { model.volumeOpen = true }
                .onDisappear { model.volumeOpen = false }
        }
        .windowStyle(.volumetric)
        .defaultSize(width: PlayfieldScene.upright ? 0.95 : 0.7, height: PlayfieldScene.upright ? 0.85 : 0.6,
                     depth: PlayfieldScene.upright ? 0.35 : 0.75, in: .meters)
        // next to the control window rather than on top of it
        .defaultWindowPlacement { _, context in
            if let controls = context.windows.first(where: { $0.id == Self.controlsID }) {
                return WindowPlacement(.trailing(controls))
            }
            return WindowPlacement()
        }

        ImmersiveSpace(id: Self.arenaID) {
            PlayfieldView(immersive: true)
                .onDisappear { model.arenaOpen = false }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
