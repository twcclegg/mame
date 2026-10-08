// license:BSD-3-Clause
//
// HandTracking - the right index fingertip as the paddle position, and a
// left-hand pinch (thumb tip to index tip) as the fire button.  ARKit hand tracking only runs while an immersive space is open, so
// this is used by the "arena" space, not the volumetric window.
// Needs NSHandsTrackingUsageDescription (project.yml).

import ARKit
import Foundation
import simd

@MainActor
final class HandTracker {
    /// Fingertips closer than this start a pinch, farther than `pinchOff` end it.
    static let pinchOn: Float = 0.015, pinchOff: Float = 0.03

    /// Streams the right index fingertip's world position, and calls `onPinch`
    /// when a left-hand pinch begins, until the task is cancelled.  A data
    /// provider can only run once, so each call makes a new one.
    func run(_ onTip: @escaping @MainActor (SIMD3<Float>?) -> Void,
             onPinch: @escaping @MainActor () -> Void = {}) async {
        guard HandTrackingProvider.isSupported else { return }
        let session = ARKitSession()
        let provider = HandTrackingProvider()
        do {
            try await session.run([provider])
        } catch {
            return
        }
        var pinching = false
        for await update in provider.anchorUpdates {
            if Task.isCancelled { break }
            let anchor = update.anchor
            if anchor.chirality == .left {
                guard anchor.isTracked, let skeleton = anchor.handSkeleton else { pinching = false; continue }
                let thumb = skeleton.joint(.thumbTip), index = skeleton.joint(.indexFingerTip)
                guard thumb.isTracked, index.isTracked else { continue }
                let d = simd_distance(thumb.anchorFromJointTransform.columns.3, index.anchorFromJointTransform.columns.3)
                if !pinching && d < Self.pinchOn {
                    pinching = true
                    onPinch()
                } else if pinching && d > Self.pinchOff {
                    pinching = false
                }
                continue
            }
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
