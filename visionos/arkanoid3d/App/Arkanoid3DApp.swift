// license:BSD-3-Clause
//
// Arkanoid 3D - the original arcade Arkanoid, emulated by MAME (libmame,
// taito/arkanoid.cpp), presented as a RealityKit scene.  MAME runs the real
// game; every emulated frame its video RAM is decoded (Decoder/ark3d.c) and
// drives 3D bricks, Vaus, balls, capsules and enemies.  Sound is MAME's.
//
// Scenes: a control window, the table-top volume, and an immersive "arena".

import SwiftUI

@main
struct Arkanoid3DApp: App {
    static let volumeID = "playfield"
    static let arenaID = "arena"

    @State private var model = ArkModel.shared

    var body: some Scene {
        WindowGroup {
            ControlPanel()
        }
        .defaultSize(width: 560, height: 640)

        WindowGroup(id: Self.volumeID) {
            PlayfieldView(immersive: false)
                .onAppear { model.volumeOpen = true }
                .onDisappear { model.volumeOpen = false }
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.7, height: 0.5, depth: 0.75, in: .meters)

        ImmersiveSpace(id: Self.arenaID) {
            PlayfieldView(immersive: true)
                .onDisappear { model.arenaOpen = false }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
