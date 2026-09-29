// license:BSD-3-Clause
//
// PlayfieldView - shows PlayfieldScene, in the volumetric window (table-top
// size) or the "arena" immersive space (bigger, with hand tracking).
//
// Paddle input: in "Pinch & drag" mode, look at the field, pinch and move
// your hand sideways; the Vaus follows the point you drag over.  In "Hand"
// mode (immersive only), it follows your right index fingertip.

import SwiftUI
import RealityKit

/// Holds the scene: @State's initial value is evaluated on every init of the
/// view struct, so the (expensive) scene is made once, on first use.
@MainActor
final class PlayfieldHolder {
    private var _scene: PlayfieldScene?
    var scene: PlayfieldScene {
        if let s = _scene { return s }
        let s = PlayfieldScene(store: ArkanoidStateReader.shared.store, frames: MAMEEngine.shared.frames)
        _scene = s
        return s
    }
    let tracker = HandTracker()
}

struct PlayfieldView: View {
    let immersive: Bool

    @State private var model = ArkModel.shared
    @State private var holder = PlayfieldHolder()
    private var scene: PlayfieldScene { holder.scene }

    private var paddle: PaddleController { ArkanoidStateReader.shared.paddle }

    var body: some View {
        RealityView { content, attachments in
            if immersive, let pose = Self.closeupPose() {
                scene.root.scale = SIMD3(repeating: pose.scale)
                scene.root.position = pose.position
                scene.root.orientation = simd_quatf(angle: pose.yaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.pitch, axis: [1, 0, 0])
            } else if immersive && PlayfieldScene.upright {
                // a big screen in front of you: 224 px -> ~1 m wide, at eye height
                scene.root.scale = SIMD3(repeating: 1.8)
                scene.root.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                scene.root.position = [0, 1.35, -1.3]
            } else if immersive {
                // a big table in front of you: 224 px -> ~1 m wide, at table height
                scene.root.scale = SIMD3(repeating: 1.8)
                scene.root.position = [0, 0.8, -0.9]
            } else if PlayfieldScene.upright {
                // standing up like a monitor, depth toward the viewer
                scene.root.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                scene.root.position = [0, 0, -0.08]
            } else {
                // A volume opens at about eye height, so a flat table would be
                // seen edge-on: tilt it toward the viewer like an arcade
                // board, near end low (the volume's origin is its centre).
                scene.root.orientation = simd_quatf(angle: Self.volumeTilt, axis: [1, 0, 0])
                scene.root.position = [0, -0.1, 0.02]
            }
            content.add(scene.root)
            if let hud = attachments.entity(for: "hud") {
                if immersive {
                    hud.position = scene.local(Float(ARK3D_VIEW_W) / 2, 0, 0.36)
                    scene.root.addChild(hud)
                } else {
                    // upright, above the board
                    hud.position = PlayfieldScene.upright ? [0, 0.38, -0.05] : [0, 0.24, -0.3]
                    content.add(hud)
                }
            }
            let scene = self.scene
            scene.subscription = content.subscribe(to: SceneEvents.Update.self) { event in
                scene.update(deltaTime: Float(event.deltaTime))
            }
        } update: { _, attachments in
            scene.showDebugScreen = model.showOriginalScreen
            scene.showGameBackground = model.showGameBackground
            // frosted style: mount each brick's glass pane on its brick
            for cell in scene.panes.cells {
                if let pane = attachments.entity(for: cell.id) { scene.mount(pane: pane, for: cell) }
            }
        } attachments: {
            Attachment(id: "hud") { HUDView() }
            ForEach(scene.panes.cells) { cell in
                Attachment(id: cell.id) { FrostedPaneView(pane: cell) }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .targetedToAnyEntity()
                .onChanged { value in
                    guard model.paddleSource == .pinch, value.entity === scene.touchSurface else { return }
                    let p = value.convert(value.location3D, from: .local, to: scene.root)
                    paddle.setPointerTarget(scene.viewX(fromLocal: p))
                }
                .onEnded { _ in paddle.setPointerTarget(nil) }
        )
        .task(id: immersive && model.paddleSource == .hand) {
            guard immersive && model.paddleSource == .hand else { return }
            let scene = self.scene, paddle = self.paddle
            await holder.tracker.run { tip in
                guard let tip else { paddle.setPointerTarget(nil); return }
                let p = scene.root.convert(position: tip, from: nil)
                paddle.setPointerTarget(scene.viewX(fromLocal: p))
            }
            paddle.setPointerTarget(nil)
        }
    }
}

extension PlayfieldView {
    /// How far the table-top view tilts the field toward the viewer.
    static let volumeTilt: Float = 28 * .pi / 180

    /// Development: with DIORAMA_CLOSEUP=1 the arena puts the table close in
    /// front of the viewer, tilted toward them.  DIORAMA_POSE="y z pitch
    /// scale" (metres, degrees) overrides the default "1.4 -0.9 60 0.75".
    static func closeupPose() -> (position: SIMD3<Float>, pitch: Float, scale: Float, yaw: Float)? {
        let env = ProcessInfo.processInfo.environment
        guard env["DIORAMA_CLOSEUP"] == "1" else { return nil }
        var v: [Float] = PlayfieldScene.upright ? [1.3, -1.0, 90, 0.75] : [1.4, -0.9, 60, 0.75]
        var yaw: Float = 0
        if let pose = env["DIORAMA_POSE"] {
            let parts = pose.split(separator: " ").compactMap { Float($0) }
            if parts.count >= 4 { v = Array(parts.prefix(4)) }
            if parts.count == 5 { yaw = parts[4] }      // degrees, to see the depth from the side
        }
        return ([0, v[0], v[1]], v[2] * .pi / 180, v[3], yaw * .pi / 180)
    }
}

/// Floating score board above the far wall.
struct HUDView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let s = ArkanoidStateReader.shared.store.summary()
            HStack(spacing: 24) {
                if s.available {
                    label("1UP", s.score >= 0 ? String(s.score) : "—")
                    label("HIGH SCORE", s.highScore >= 0 ? String(s.highScore) : "—")
                    label("LIVES", s.lives >= 0 ? String(s.lives) : "—")
                    label("BRICKS", String(s.bricks))
                } else {
                    Text("Start an Arkanoid set from the control window")
                        .font(.headline)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .glassBackgroundEffect()
        }
    }

    private func label(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.red)
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
        }
    }
}
