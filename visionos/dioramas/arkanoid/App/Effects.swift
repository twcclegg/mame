// license:BSD-3-Clause
//
// Effects - one-shot particle bursts: sparks when a brick breaks or a silver
// brick is hit, and a big burst when the Vaus explodes.

import Foundation
import RealityKit
import UIKit

@MainActor
enum Effects {
    /// A burst of sparks at `position` (in `parent`'s space) that removes
    /// itself afterwards.  `scale` sizes the burst (1 = a brick).
    /// `gravity` is down in the room, in `parent`'s space.
    static func sparks(in parent: Entity, gravity: SIMD3<Float> = [0, -1, 0], at position: SIMD3<Float>, color: UIColor,
                       count: Int = 40, scale: Float = 1) {
        let e = Entity()
        e.position = position
        var p = ParticleEmitterComponent()
        p.emitterShape = .sphere
        p.emitterShapeSize = SIMD3(repeating: 0.004 * scale)
        p.birthDirection = .normal
        p.speed = 0.25 * scale
        p.speedVariation = 0.1 * scale
        p.timing = .once(warmUp: 0, emit: .init(duration: 0.05))
        p.mainEmitter.birthRate = 0
        p.burstCount = count
        p.mainEmitter.lifeSpan = 0.45
        p.mainEmitter.lifeSpanVariation = 0.15
        p.mainEmitter.size = 0.0022 * scale
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.1
        p.mainEmitter.color = .evolving(start: .single(.white), end: .single(color))
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.acceleration = gravity * 0.6
        p.isEmitting = true
        p.burst()
        e.components.set(p)
        parent.addChild(e)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            e.removeFromParent()
        }
    }
}
