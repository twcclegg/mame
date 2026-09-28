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
            if immersive {
                // a big table in front of you: 224 px -> ~1 m wide, at table height
                scene.root.scale = SIMD3(repeating: 1.8)
                scene.root.position = [0, 0.8, -0.9]
            } else {
                // floor of the volume (the volume's origin is its centre)
                scene.root.position = [0, -0.18, 0]
            }
            content.add(scene.root)
            if let hud = attachments.entity(for: "hud") {
                hud.position = scene.local(Float(ARK3D_VIEW_W) / 2, 0, 0.36)
                scene.root.addChild(hud)
            }
            let scene = self.scene
            scene.subscription = content.subscribe(to: SceneEvents.Update.self) { event in
                scene.update(deltaTime: Float(event.deltaTime))
            }
        } update: { _, _ in
            scene.showDebugScreen = model.showOriginalScreen
        } attachments: {
            Attachment(id: "hud") { HUDView() }
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

/// Floating score board above the far wall.
struct HUDView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let s = ArkanoidStateReader.shared.store.summary()
            HStack(spacing: 24) {
                if s.available {
                    label("1UP", s.score >= 0 ? String(s.score) : "—")
                    label("HIGH SCORE", s.highScore >= 0 ? String(s.highScore) : "—")
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
