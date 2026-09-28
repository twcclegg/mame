// license:BSD-3-Clause
//
// Models - the 3D stand-ins for the game's sprites, built from primitives in
// view-pixel units (1 unit = PlayfieldScene.metresPerPixel): the Vaus, the
// enemies (one shape per type the decoder reports) and the ball with its
// trail.  Colours come from the game's own palette where the decoder has
// them.

import Foundation
import RealityKit
import UIKit

private let px = PlayfieldScene.metresPerPixel

private func pbr(_ color: UIColor, metallic: Float = 0, roughness: Float = 0.35, clearcoat: Float = 0,
                 emissive: UIColor? = nil, emissiveIntensity: Float = 0) -> PhysicallyBasedMaterial {
    var m = PhysicallyBasedMaterial()
    m.baseColor = .init(tint: color)
    m.metallic = .init(floatLiteral: metallic)
    m.roughness = .init(floatLiteral: roughness)
    m.clearcoat = .init(floatLiteral: clearcoat)
    if let emissive {
        m.emissiveColor = .init(color: emissive)
        m.emissiveIntensity = emissiveIntensity
    }
    return m
}

private func shadowed(_ e: ModelEntity) -> ModelEntity {
    e.components.set(GroundingShadowComponent(castsShadow: true))
    return e
}

/// Rotation that lays a (y-axis) cylinder along x.
private let alongX = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])

// MARK: - Vaus

/// The Vaus: a silver hull that stretches with the game's width, red pods at
/// the ends with a glowing blue band between hull and pods, and laser
/// barrels when it has them.  Origin at its centre, resting on the floor.
@MainActor
final class VausModel: Entity {
    private let hull = ModelEntity()
    private let pods = [Entity(), Entity()]
    private let bands = [ModelEntity(), ModelEntity()]
    private let barrels = [ModelEntity(), ModelEntity()]
    static let height: Float = 7          // px, the sprite's 8 minus its outline
    private static let podLength: Float = 7

    required init() {
        super.init()
        let r = Self.height / 2 * px
        hull.model = ModelComponent(mesh: .generateCylinder(height: 1, radius: r * 0.8),
                                    materials: [pbr(UIColor(white: 0.82, alpha: 1), metallic: 1, roughness: 0.15)])
        hull.orientation = alongX
        hull.position.y = r
        addChild(shadowed(hull))

        let podMat = pbr(UIColor(red: 0.8, green: 0.08, blue: 0.06, alpha: 1), metallic: 0.5, roughness: 0.2, clearcoat: 1,
                         emissive: UIColor(red: 0.5, green: 0, blue: 0, alpha: 1), emissiveIntensity: 0.3)
        let bandMat = pbr(UIColor(red: 0.2, green: 0.6, blue: 1, alpha: 1), roughness: 0.2,
                          emissive: UIColor(red: 0.3, green: 0.7, blue: 1, alpha: 1), emissiveIntensity: 1.2)
        let barrelMat = pbr(UIColor(white: 0.35, alpha: 1), metallic: 1, roughness: 0.3)
        for (i, pod) in pods.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            let body = shadowed(ModelEntity(mesh: .generateCylinder(height: (Self.podLength - 2) * px, radius: r), materials: [podMat]))
            body.orientation = alongX
            let cap = shadowed(ModelEntity(mesh: .generateSphere(radius: r), materials: [podMat]))
            cap.position.x = side * (Self.podLength - 2) / 2 * px
            pod.addChild(body)
            pod.addChild(cap)
            pod.position.y = r
            addChild(pod)

            bands[i].model = ModelComponent(mesh: .generateCylinder(height: 1.2 * px, radius: r * 0.9), materials: [bandMat])
            bands[i].orientation = alongX
            bands[i].position.y = r
            addChild(bands[i])

            barrels[i].model = ModelComponent(mesh: .generateCylinder(height: 6 * px, radius: 0.9 * px), materials: [barrelMat])
            barrels[i].orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])      // pointing up the field (-z)
            barrels[i].isEnabled = false
            pod.addChild(barrels[i])
        }
    }

    /// Width in view pixels, as the game draws it (32, or 48 enlarged).
    func setWidth(_ width: Float) {
        let hullLength = max(width - 2 * Self.podLength, 2)
        hull.scale = [1, hullLength * px, 1]            // cylinder height is along its (rotated) y
        for (i, pod) in pods.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            pod.position.x = side * (hullLength / 2 + (Self.podLength - 2) / 2) * px
            bands[i].position.x = side * (hullLength / 2) * px
        }
    }

    func setLaser(_ on: Bool) {
        for b in barrels {
            b.isEnabled = on
            b.position = [0, Self.height / 2 * px, -3 * px]
        }
    }
}

// MARK: - enemies

/// One enemy: a shape per type, spinning and bobbing.  Colours follow the
/// sprite's own where that helps (the sphere and cube take theirs).
@MainActor
final class EnemyModel: Entity {
    private var shapes: [Int: Entity] = [:]
    private(set) var type = -1

    required init() {
        super.init()
        let molecule = Entity()
        let ballColors: [UIColor] = [.systemRed, .systemGreen, .systemBlue]
        for i in 0..<3 {
            let a = Float(i) * 2 * .pi / 3
            let b = shadowed(ModelEntity(mesh: .generateSphere(radius: 3.2 * px),
                                         materials: [pbr(ballColors[i], roughness: 0.2, clearcoat: 1)]))
            b.position = [cos(a) * 3.4 * px, 0, sin(a) * 3.4 * px]
            molecule.addChild(b)
        }
        shapes[Int(ARK3D_ENEMY_MOLECULE.rawValue)] = molecule

        shapes[Int(ARK3D_ENEMY_CUBE.rawValue)] = shadowed(ModelEntity(
            mesh: .generateBox(size: 8 * px, cornerRadius: 1 * px),
            materials: [pbr(.systemTeal, metallic: 0.3, roughness: 0.25, clearcoat: 1)]))

        shapes[Int(ARK3D_ENEMY_SPHERE.rawValue)] = shadowed(ModelEntity(
            mesh: .generateSphere(radius: 5.5 * px),
            materials: [pbr(.systemOrange, metallic: 0.2, roughness: 0.3, clearcoat: 1)]))

        shapes[Int(ARK3D_ENEMY_PYRAMID.rawValue)] = shadowed(ModelEntity(
            mesh: Self.pyramid(base: 11 * px, height: 10 * px),
            materials: [pbr(UIColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1), roughness: 0.3, clearcoat: 1,
                            emissive: UIColor(red: 0, green: 0.3, blue: 0.1, alpha: 1), emissiveIntensity: 0.5)]))

        let cone = Entity()
        let coneBody = shadowed(ModelEntity(mesh: .generateCone(height: 11 * px, radius: 4.5 * px),
                                            materials: [pbr(.systemYellow, metallic: 0.4, roughness: 0.25)]))
        let disc = shadowed(ModelEntity(mesh: .generateCylinder(height: 1 * px, radius: 6.5 * px),
                                        materials: [pbr(.systemBlue, metallic: 0.6, roughness: 0.2)]))
        disc.position.y = -4 * px
        cone.addChild(coneBody)
        cone.addChild(disc)
        shapes[Int(ARK3D_ENEMY_CONE.rawValue)] = cone

        shapes[Int(ARK3D_ENEMY_UNKNOWN.rawValue)] = shadowed(ModelEntity(
            mesh: .generateSphere(radius: 5 * px), materials: [pbr(.gray, roughness: 0.4)]))

        for shape in shapes.values {
            shape.isEnabled = false
            addChild(shape)
        }
    }

    func show(type: Int) {
        guard type != self.type else { return }
        shapes[self.type]?.isEnabled = false
        self.type = shapes[type] != nil ? type : Int(ARK3D_ENEMY_UNKNOWN.rawValue)
        shapes[self.type]?.isEnabled = true
    }

    /// Spin and bob; `t` in seconds, `seed` keeps enemies out of step.
    func animate(t: Float, seed: Float) {
        position.y = (8 + 1.5 * sin(t * 4 + seed)) * px
        let spin = simd_quatf(angle: t * 1.8 + seed, axis: [0, 1, 0])
        let tumble = type == Int(ARK3D_ENEMY_CUBE.rawValue) ? simd_quatf(angle: t * 1.3, axis: simd_normalize([1, 0, 1])) : simd_quatf()
        shapes[type]?.orientation = spin * tumble
    }

    /// Square pyramid on the xz plane, apex up, centred on its middle height.
    static func pyramid(base: Float, height: Float) -> MeshResource {
        let b = base / 2, h = height / 2
        let apex: SIMD3<Float> = [0, h, 0]
        let corners: [SIMD3<Float>] = [[-b, -h, -b], [b, -h, -b], [b, -h, b], [-b, -h, b]]
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let n = simd_normalize(simd_cross(b - a, c - a))
            let base = UInt32(positions.count)
            positions += [a, b, c]
            normals += [n, n, n]
            indices += [base, base + 1, base + 2]
        }
        for i in 0..<4 { face(corners[i], apex, corners[(i + 1) % 4]) }
        face(corners[0], corners[1], corners[2])
        face(corners[0], corners[2], corners[3])
        var d = MeshDescriptor(name: "pyramid")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [d])) ?? .generateBox(size: base)
    }
}

// MARK: - banner

/// "ROUND n" and "READY" as extruded text standing on the table, facing the
/// player; pops in when the game shows its banner and shrinks away after.
@MainActor
final class BannerModel: Entity {
    private let roundText = ModelEntity()
    private let readyText = ModelEntity()
    private let holder = Entity()
    private var shownRound = 0
    private var show: Float = 0             // 0 hidden .. 1 fully shown
    private var readyShow: Float = 0
    private var t: Float = 0

    required init() {
        super.init()
        // bright chrome-white reads on every round's background; READY in red
        roundText.model = ModelComponent(mesh: .generateBox(size: 0.001), materials: [
            pbr(.white, metallic: 0.7, roughness: 0.12, clearcoat: 1, emissive: .white, emissiveIntensity: 0.55)])
        readyText.model = ModelComponent(mesh: Self.text("READY", size: 9 * px), materials: [
            pbr(UIColor(red: 0.95, green: 0.15, blue: 0.1, alpha: 1), metallic: 0.5, roughness: 0.2, clearcoat: 1,
                emissive: UIColor(red: 0.9, green: 0.1, blue: 0, alpha: 1), emissiveIntensity: 0.7)])
        center(readyText)
        // hover above the bricks, leaning back toward the player so it reads
        // whether the table is seen from above or tilted up
        holder.orientation = simd_quatf(angle: -.pi / 4, axis: [1, 0, 0])
        holder.position.y = 16 * px
        readyText.position.y = -2 * px
        roundText.position.y = 10 * px
        for e in [roundText, readyText] {
            e.components.set(GroundingShadowComponent(castsShadow: true))
            holder.addChild(e)
        }
        addChild(holder)
        isEnabled = false
    }

    private static func text(_ s: String, size: Float) -> MeshResource {
        .generateText(s, extrusionDepth: 2.5 * px, font: .systemFont(ofSize: CGFloat(size), weight: .black),
                      containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
    }

    /// Centre a text entity on x (text meshes start at their left edge).
    private func center(_ e: ModelEntity) {
        guard let b = e.model?.mesh.bounds else { return }
        e.position.x = -(b.min.x + b.max.x) / 2
    }

    /// Per frame: `round` is the banner's number (0 = none shown), `ready` whether READY is up.
    func update(round: Int, ready: Bool, dt: Float) {
        t += dt
        if round > 0 && round != shownRound {
            shownRound = round
            roundText.model?.mesh = Self.text("ROUND \(round)", size: 14 * px)
            center(roundText)
        }
        show += ((round > 0 ? 1 : 0) - show) * min(1, dt * (round > 0 ? 9 : 6))
        readyShow += ((ready ? 1 : 0) - readyShow) * min(1, dt * 9)
        isEnabled = show > 0.02
        guard isEnabled else { return }
        // a little overshoot on the way in, then a gentle bob
        let pop = show < 0.98 ? show * (1 + 0.25 * sin(show * .pi)) : 1
        scale = SIMD3(repeating: max(0.01, pop))
        holder.position.y = (16 + 1.5 * sin(t * 2.5)) * px
        readyText.scale = SIMD3(repeating: max(0.01, readyShow))
        readyText.isEnabled = readyShow > 0.02
    }
}

// MARK: - ball

/// The energy ball: bright core, its own light, and a short fading trail.
@MainActor
final class BallModel: Entity {
    static let radius: Float = 3            // px (the sprite is 5x4)
    private let core: ModelEntity
    private var trail: [ModelEntity] = []
    private var history: [SIMD3<Float>] = []

    required init() {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .white)
        m.emissiveColor = .init(color: UIColor(red: 0.75, green: 0.95, blue: 1, alpha: 1))
        m.emissiveIntensity = 3
        core = shadowed(ModelEntity(mesh: .generateSphere(radius: Self.radius * px), materials: [m]))
        super.init()
        core.components.set(PointLightComponent(color: UIColor(red: 0.6, green: 0.85, blue: 1, alpha: 1),
                                                intensity: 400, attenuationRadius: 0.2))
        addChild(core)
        for i in 0..<6 {
            var t = UnlitMaterial(color: UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1))
            t.blending = .transparent(opacity: .init(floatLiteral: 0.45 * (1 - Float(i) / 6)))
            let e = ModelEntity(mesh: .generateSphere(radius: Self.radius * px * (0.85 - Float(i) * 0.1)), materials: [t])
            trail.append(e)
        }
    }

    /// The trail lives in the parent's space, so it's added next to the ball.
    func attachTrail(to parent: Entity) { trail.forEach { parent.addChild($0) } }

    func place(_ p: SIMD3<Float>, visible: Bool) {
        isEnabled = visible
        guard visible else {
            history.removeAll()
            trail.forEach { $0.isEnabled = false }
            return
        }
        position = p
        history.insert(p, at: 0)
        if history.count > trail.count * 2 + 1 { history.removeLast() }
        for (i, e) in trail.enumerated() {
            let h = 2 * (i + 1)
            e.isEnabled = h < history.count
            if h < history.count { e.position = history[h] }
        }
    }
}
