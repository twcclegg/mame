// license:BSD-3-Clause
//
// HandTracking - the right index fingertip as the paddle position (stretch
// goal).  ARKit hand tracking only runs while an immersive space is open, so
// this is used by the "arena" space, not the volumetric window.
// Needs NSHandsTrackingUsageDescription (project.yml).

import ARKit
import Foundation
import simd

@MainActor
final class HandTracker {
    /// Streams the right index fingertip's world position until the task is
    /// cancelled.  A data provider can only run once, so each call makes a new one.
    func run(_ onTip: @escaping @MainActor (SIMD3<Float>?) -> Void) async {
        guard HandTrackingProvider.isSupported else { return }
        let session = ARKitSession()
        let provider = HandTrackingProvider()
        do {
            try await session.run([provider])
        } catch {
            return
        }
        for await update in provider.anchorUpdates {
            if Task.isCancelled { break }
            let anchor = update.anchor
            guard anchor.chirality == .right else { continue }
            guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
                onTip(nil)
                continue
            }
            let joint = skeleton.joint(.indexFingerTip)
            guard joint.isTracked else { onTip(nil); continue }
            let m = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
            onTip(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
        }
        session.stop()
    }
}
