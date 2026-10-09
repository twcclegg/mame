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

/// Grounding shadows for the table-top board; upright, the key light casts
/// the shadows (PlayfieldScene).
private func shadowed(_ e: ModelEntity) -> ModelEntity {
    if !PlayfieldScene.upright { e.components.set(GroundingShadowComponent(castsShadow: true)) }
    return e
}

/// Rotation that lays a (y-axis) cylinder along x.
private let alongX = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])

/// Every style but classic: polished chrome, light that blooms.
private let modern = DioramaStyle.current != .classic
private let chrome = pbr(UIColor(white: 0.93, alpha: 1), metallic: 1, roughness: 0.05, clearcoat: 1)
private func neon(_ color: UIColor, _ intensity: Float) -> PhysicallyBasedMaterial {
    pbr(color, roughness: 0.2, emissive: color, emissiveIntensity: intensity)
}

// MARK: - Vaus

/// The Vaus: a silver hull that stretches with the game's width, red pods at
/// the ends with a glowing blue band between hull and pods.  With the laser
/// (L capsule) it changes form as in the game: the red pods give way to
/// tapered grey ends with cyan tips, orange trim, and two cannons on the hull
/// 6.5 px either side of its centre, where the game's twin beams come from.
/// Origin at its centre, resting on the floor.
@MainActor
final class VausModel: Entity {
    private let hull = ModelEntity()
    private let pods = [Entity(), Entity()]
    private let bands = [ModelEntity(), ModelEntity()]
    private let barrels = [ModelEntity(), ModelEntity()]
    private let laserEnds = [Entity(), Entity()]
    /// The game's twin beams leave the laser Vaus this far either side of its centre.
    static let cannonOffset: Float = 6.5
    static let height: Float = 7          // px, the sprite's 8 minus its outline
    private static let podLength: Float = 7

    required init() {
        super.init()
        let r = Self.height / 2 * px
        hull.model = ModelComponent(mesh: .generateCylinder(height: 1, radius: r * 0.8),
                                    materials: [modern ? chrome : pbr(UIColor(white: 0.82, alpha: 1), metallic: 1, roughness: 0.15)])
        hull.orientation = alongX
        hull.position.y = r
        addChild(shadowed(hull))

        // modern: all chrome, with rings of cyan light that bloom
        let podMat = modern ? chrome : pbr(UIColor(red: 0.8, green: 0.08, blue: 0.06, alpha: 1), metallic: 0.5, roughness: 0.2, clearcoat: 1,
                                           emissive: UIColor(red: 0.5, green: 0, blue: 0, alpha: 1), emissiveIntensity: 0.3)
        let bandMat = modern ? neon(UIColor(red: 0.3, green: 0.85, blue: 1, alpha: 1), 3.5)
                             : pbr(UIColor(red: 0.2, green: 0.6, blue: 1, alpha: 1), roughness: 0.2,
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

            bands[i].model = ModelComponent(mesh: .generateCylinder(height: 1.2 * px, radius: r * (modern ? 1.04 : 0.9)), materials: [bandMat])
            bands[i].orientation = alongX
            bands[i].position.y = r
            addChild(bands[i])

            barrels[i].model = ModelComponent(mesh: .generateCylinder(height: 6 * px, radius: 0.9 * px), materials: [barrelMat])
            barrels[i].orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])      // pointing up the field (-z)
            barrels[i].isEnabled = false
            addChild(barrels[i])

            // the laser form's end: a short grey drum tapering to a point
            // with a cyan tip, an orange ring where it meets the hull
            let end = laserEnds[i]
            let grey = modern ? chrome : pbr(UIColor(white: 0.7, alpha: 1), metallic: 1, roughness: 0.2)
            let drum = shadowed(ModelEntity(mesh: .generateCylinder(height: 2.5 * px, radius: r), materials: [grey]))
            drum.orientation = alongX
            drum.position.x = side * 1.25 * px
            let taper = shadowed(ModelEntity(mesh: .generateCone(height: 4 * px, radius: r), materials: [grey]))
            // cone apex along +y: lay it along x, pointing outward
            taper.orientation = simd_quatf(angle: -side * .pi / 2, axis: [0, 0, 1])
            taper.position.x = side * (2.5 + 2) * px
            let tip = ModelEntity(mesh: .generateSphere(radius: 0.9 * px),
                                  materials: [neon(UIColor(red: 0.3, green: 0.95, blue: 1, alpha: 1), 3)])
            tip.position.x = side * 5.8 * px
            let trim = ModelEntity(mesh: .generateCylinder(height: 0.8 * px, radius: r * 1.06),
                                   materials: [neon(UIColor(red: 1, green: 0.35, blue: 0.05, alpha: 1), 1.5)])
            trim.orientation = alongX
            for e in [drum, taper, tip, trim] { end.addChild(e) }
            end.position.y = r
            end.isEnabled = false
            addChild(end)
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
            laserEnds[i].position.x = side * (hullLength / 2) * px
        }
    }

    func setLaser(_ on: Bool) {
        for (i, b) in barrels.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            b.isEnabled = on
            b.position = [side * Self.cannonOffset * px, Self.height * px * 0.8, -2 * px]
            pods[i].isEnabled = !on
            bands[i].isEnabled = !on
            laserEnds[i].isEnabled = on
        }
    }
}

// MARK: - enemies

/// One enemy: a shape per type, after the game's sprites (rendered from the
/// ROM to compare): the molecule, three glossy balls turning as a cluster;
/// the "cube", which morphs between a red cube and a shiny red ball; the
/// pyramid, a hollow green wireframe with a red eye inside, tumbling; the
/// cone, a light-blue spinning top with a ring, tumbling.
@MainActor
final class EnemyModel: Entity {
    private var shapes: [Int: Entity] = [:]
    private(set) var type = -1
    private let morphCube = ModelEntity()
    private let morphBall = ModelEntity()

    required init() {
        super.init()
        let molecule = Entity()
        // colours from the game's palette (colour group 0d): red, green, cyan
        let ballColors: [UIColor] = [UIColor(red: 1, green: 0.05, blue: 0.05, alpha: 1),
                                     UIColor(red: 0.05, green: 0.95, blue: 0.1, alpha: 1),
                                     UIColor(red: 0, green: 0.85, blue: 1, alpha: 1)]
        for i in 0..<3 {
            let a = Float(i) * 2 * .pi / 3
            let b = shadowed(ModelEntity(mesh: .generateSphere(radius: 3.8 * px),
                                         materials: [pbr(ballColors[i], roughness: 0.12, clearcoat: 1)]))
            b.position = [cos(a) * 3.6 * px, sin(a) * 1.2 * px, sin(a) * 3.6 * px]
            molecule.addChild(b)
        }
        shapes[Int(ARK3D_ENEMY_MOLECULE.rawValue)] = molecule

        // red, shaded darker in the game (colour group 10); it turns into a ball and back
        let red = pbr(UIColor(red: 0.95, green: 0.05, blue: 0.05, alpha: 1), metallic: 0.3, roughness: 0.2, clearcoat: 1,
                      emissive: UIColor(red: 0.4, green: 0, blue: 0, alpha: 1), emissiveIntensity: 0.4)
        let morph = Entity()
        morphCube.model = ModelComponent(mesh: .generateBox(size: 10 * px, cornerRadius: 1.2 * px), materials: [red])
        morphBall.model = ModelComponent(mesh: .generateSphere(radius: 6 * px),
                                         materials: [pbr(UIColor(red: 1, green: 0.08, blue: 0.08, alpha: 1), roughness: 0.05, clearcoat: 1,
                                                         emissive: UIColor(red: 0.35, green: 0, blue: 0, alpha: 1), emissiveIntensity: 0.4)])
        morph.addChild(shadowed(morphCube))
        morph.addChild(shadowed(morphBall))
        shapes[Int(ARK3D_ENEMY_CUBE.rawValue)] = morph

        shapes[Int(ARK3D_ENEMY_PYRAMID.rawValue)] = Self.wirePyramid(base: 12 * px, height: 11 * px)

        let cone = Entity()
        // blues from the game's palette (colour group 12)
        let coneBody = shadowed(ModelEntity(mesh: .generateCone(height: 11 * px, radius: 4.5 * px),
                                            materials: [pbr(UIColor(red: 0.25, green: 0.75, blue: 1, alpha: 1), metallic: 0.3,
                                                            roughness: 0.15, clearcoat: 1)]))
        coneBody.position.y = 1 * px
        let ring = shadowed(ModelEntity(mesh: .generateCylinder(height: 1.4 * px, radius: 6.8 * px),
                                        materials: [pbr(UIColor(red: 0.1, green: 0.45, blue: 1, alpha: 1), metallic: 0.6, roughness: 0.15,
                                                        clearcoat: 1)]))
        ring.position.y = -3 * px
        cone.addChild(coneBody)
        cone.addChild(ring)
        shapes[Int(ARK3D_ENEMY_CONE.rawValue)] = cone

        shapes[Int(ARK3D_ENEMY_UNKNOWN.rawValue)] = shadowed(ModelEntity(
            mesh: .generateSphere(radius: 5 * px), materials: [pbr(.gray, roughness: 0.4)]))

        for shape in shapes.values {
            shape.isEnabled = false
            addChild(shape)
        }
    }

    /// The pyramid enemy: glowing green edges, faint faces, a red eye inside.
    private static func wirePyramid(base: Float, height: Float) -> Entity {
        let root = Entity()
        let edgeMat = pbr(UIColor(red: 0.2, green: 1, blue: 0.3, alpha: 1), roughness: 0.3,
                          emissive: UIColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1), emissiveIntensity: 1.5)
        let h = base / 2, top = SIMD3<Float>(0, height / 2, 0)
        let corners: [SIMD3<Float>] = [[-h, -height / 2, -h], [h, -height / 2, -h], [h, -height / 2, h], [-h, -height / 2, h]]
        var edges: [(SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<4 {
            edges.append((corners[i], corners[(i + 1) % 4]))
            edges.append((corners[i], top))
        }
        let bar = MeshResource.generateBox(width: 1 * px, height: 1 * px, depth: 1)
        for (a, b) in edges {
            let e = ModelEntity(mesh: bar, materials: [edgeMat])
            e.look(at: b, from: (a + b) / 2, relativeTo: nil)
            e.scale = [1, 1, simd_distance(a, b) + 1 * px]
            root.addChild(e)
        }
        var faceMat = PhysicallyBasedMaterial()
        faceMat.baseColor = .init(tint: UIColor(red: 0, green: 0.4, blue: 0.1, alpha: 1))
        faceMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        root.addChild(ModelEntity(mesh: pyramid(base: base, height: height), materials: [faceMat]))
        let eye = ModelEntity(mesh: .generateSphere(radius: 1.8 * px),
                              materials: [pbr(UIColor(red: 1, green: 0.1, blue: 0.05, alpha: 1), roughness: 0.2,
                                              emissive: UIColor(red: 1, green: 0.1, blue: 0.05, alpha: 1), emissiveIntensity: 2)])
        eye.position.y = -height / 2 + height * 0.3
        root.addChild(eye)
        return root
    }

    func show(type: Int) {
        guard type != self.type else { return }
        shapes[self.type]?.isEnabled = false
        self.type = shapes[type] != nil ? type : Int(ARK3D_ENEMY_UNKNOWN.rawValue)
        shapes[self.type]?.isEnabled = true
    }

    /// Spin, tumble and bob; `t` in seconds, `seed` keeps enemies out of step.
    func animate(t: Float, seed: Float) {
        position.y = (9 + 1.5 * sin(t * 4 + seed)) * px
        let spin = simd_quatf(angle: t * 1.8 + seed, axis: [0, 1, 0])
        var orientation = spin
        switch type {
        case Int(ARK3D_ENEMY_CUBE.rawValue):
            orientation = spin * simd_quatf(angle: t * 1.3, axis: simd_normalize([1, 0, 1]))
            // cube -> ball -> cube, about every 3.5 s, as in the game
            let w = 0.5 + 0.5 * sin(t * 1.8 + seed)
            let k = min(1, max(0, (w - 0.35) / 0.3))
            let ball = k * k * (3 - 2 * k)
            morphCube.scale = SIMD3(repeating: max(0.001, 1 - ball))
            morphBall.scale = SIMD3(repeating: max(0.001, ball))
        case Int(ARK3D_ENEMY_PYRAMID.rawValue), Int(ARK3D_ENEMY_CONE.rawValue):
            // tumbling end over end, not just turning
            orientation = spin * simd_quatf(angle: 0.6 * sin(t * 2.2 + seed), axis: [1, 0, 0])
        case Int(ARK3D_ENEMY_MOLECULE.rawValue):
            orientation = spin * simd_quatf(angle: t * 0.9, axis: simd_normalize([1, 0, 0.4]))
        default:
            break
        }
        // the shapes are built standing on the board (+y out of it); upright,
        // that's toward the viewer, so stand them up the screen (-z) instead,
        // as the game draws them: the cone's point and the pyramid's apex up
        let stand = PlayfieldScene.upright ? simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]) : simd_quatf()
        shapes[type]?.orientation = stand * orientation
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

// MARK: - capsules

/// A power-up capsule: a glossy pill in the letter's colour with the letter
/// raised on it, rolling toward the player as it falls, as in the game.
/// Slightly bigger than the game's 16x8 so the letter reads at table-top scale.
@MainActor
final class CapsuleModel: Entity {
    static let colors: [UIColor] = [
        .gray,                                                   // unknown
        UIColor(red: 1, green: 0.55, blue: 0, alpha: 1),         // S slow
        UIColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1),      // C catch
        UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),      // L laser
        UIColor(red: 0.1, green: 0.3, blue: 1, alpha: 1),        // E enlarge
        UIColor(red: 0, green: 0.8, blue: 1, alpha: 1),          // D disruption
        UIColor(red: 1, green: 0.35, blue: 0.8, alpha: 1),       // B break
        UIColor(white: 0.65, alpha: 1),                          // P player
    ]
    static let radius: Float = 4.5          // px
    private static let length: Float = 12   // px, the straight part
    private let roller = Entity()
    private let parts: [ModelEntity]
    private let letters: [ModelEntity]      // two, opposite each other, so one is up more often
    private var rings: [ModelEntity] = []    // modern: neon rings round the ends
    private var type = -1

    required init() {
        let r = Self.radius * px, l = Self.length * px
        let tube = ModelEntity(mesh: .generateCylinder(height: l, radius: r))
        tube.orientation = alongX
        let caps = [ModelEntity(mesh: .generateSphere(radius: r)), ModelEntity(mesh: .generateSphere(radius: r))]
        caps[0].position.x = -l / 2
        caps[1].position.x = l / 2
        parts = [tube] + caps
        letters = [ModelEntity(), ModelEntity()]
        super.init()
        for p in parts {
            if !PlayfieldScene.upright { p.components.set(GroundingShadowComponent(castsShadow: true)) }
            roller.addChild(p)
        }
        let white = pbr(.white, metallic: 0.2, roughness: 0.25, emissive: .white, emissiveIntensity: 0.35)
        for (i, letter) in letters.enumerated() {
            letter.model = ModelComponent(mesh: .generateBox(size: 0.001), materials: [white])
            // lying on the surface, facing out: 0 on top, 1 underneath
            let holder = Entity()
            holder.orientation = simd_quatf(angle: i == 0 ? 0 : .pi, axis: [1, 0, 0])
            letter.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            letter.position.y = r - 0.4 * px
            holder.addChild(letter)
            roller.addChild(holder)
        }
        if modern {
            for x in [-l / 2, l / 2] {
                let ring = ModelEntity(mesh: .generateCylinder(height: 1.1 * px, radius: r * 1.06))
                ring.orientation = alongX
                ring.position.x = x
                roller.addChild(ring)
                rings.append(ring)
            }
        }
        addChild(roller)
    }

    func show(type: Int) {
        guard type != self.type else { return }
        self.type = type
        let color = Self.colors[max(0, min(type, Self.colors.count - 1))]
        if modern {
            // smoked glass in the capsule's colour, lit by neon rings and letter
            var body = pbr(color.withAlphaComponent(1), metallic: 0, roughness: 0.05, clearcoat: 1)
            var c: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.getRed(&c.0, green: &c.1, blue: &c.2, alpha: &c.3)
            body.baseColor = .init(tint: UIColor(red: c.0 * 0.35, green: c.1 * 0.35, blue: c.2 * 0.35, alpha: 1))
            body.blending = .transparent(opacity: .init(floatLiteral: 0.75))
            for p in parts { p.model?.materials = [body] }
            for ring in rings { ring.model?.materials = [neon(color, 3.5)] }
            for letter in letters { letter.model?.materials = [neon(color, 3)] }
        } else {
            let body = pbr(color, metallic: 0.2, roughness: 0.18, clearcoat: 1)
            for p in parts { p.model?.materials = [body] }
        }
        let name = String(cString: ark3d_capsule_name(Int32(type)))
        let mesh = MeshResource.generateText(name, extrusionDepth: 1.2 * px, font: .systemFont(ofSize: CGFloat(8 * px), weight: .black),
                                             containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
        for letter in letters {
            letter.model?.mesh = mesh
            let b = mesh.bounds
            // centre on the pill (the text lies in x/z after its rotation)
            letter.position.x = -(b.min.x + b.max.x) / 2
            letter.position.z = (b.min.y + b.max.y) / 2
        }
    }

    /// Roll toward the player (about x); `t` in seconds.
    func roll(t: Float) {
        roller.orientation = simd_quatf(angle: -t * 5, axis: [1, 0, 0])
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
        // (upright, it lies flat against the board, facing the viewer)
        holder.orientation = simd_quatf(angle: PlayfieldScene.upright ? -.pi / 2 : -.pi / 4, axis: [1, 0, 0])
        holder.position.y = 16 * px
        readyText.position.y = -2 * px
        roundText.position.y = 10 * px
        // no grounding shadow: leaning back, it would throw a big smear on the floor
        for e in [roundText, readyText] { holder.addChild(e) }
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
        // modern: a chrome sphere, the trail carries the light
        core = shadowed(ModelEntity(mesh: .generateSphere(radius: Self.radius * px), materials: [modern ? chrome : m]))
        super.init()
        core.components.set(PointLightComponent(color: UIColor(red: 0.6, green: 0.85, blue: 1, alpha: 1),
                                                intensity: 400, attenuationRadius: 0.2))
        addChild(core)
        for i in 0..<6 {
            var t = UnlitMaterial(color: modern ? UIColor(red: 0.75, green: 0.95, blue: 1, alpha: 1) : UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1))
            t.blending = .transparent(opacity: .init(floatLiteral: (modern ? 0.7 : 0.45) * (1 - Float(i) / 6)))
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
