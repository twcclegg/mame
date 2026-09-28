// license:BSD-3-Clause
//
// PlayfieldScene - the 3D Arkanoid playfield, driven by the decoded state.
//
// Layout: the game's (rotated) 224x256 screen lies flat like a table top.
// View x -> RealityKit +x, view y (down the screen) -> +z (toward the
// player), so the bricks are at the far end and the Vaus is nearest you.
// One view pixel is `metresPerPixel`; the root entity can be scaled.
//
// Everything is pooled and created once; each RealityKit update copies the
// newest ark3d_state (if any) and eases entities toward it, so motion stays
// smooth at the display rate (90 Hz) although the game runs at 60.

import Foundation
import RealityKit
import UIKit

@MainActor
final class PlayfieldScene {
    static let metresPerPixel: Float = 0.0025       // 224 px -> 0.56 m wide
    static let brickHeight: Float = 0.012
    static let wallHeight: Float = 0.03

    let root = Entity()
    /// RealityKit update subscription, owned by the view that shows this scene.
    var subscription: EventSubscription?
    /// Invisible slab over the field that takes the pinch-drag gesture.
    let touchSurface = Entity()
    private let field = Entity()                    // everything in view-pixel placement
    private var screen: ScreenUpdater?

    private let store: GameStateStore
    private let state = UnsafeMutablePointer<ark3d_state>.allocate(capacity: 1)
    private var serial = -1
    private var hasState = false
    private var layout = ark3d_layout()

    private var bricks: [[ModelEntity]] = []
    private var brickShown: [[UInt8]] = []          // kind shown per cell, for break effects
    private var brickColor: [[UInt32]] = []
    private let vaus = Entity()
    private let vausBody = ModelEntity()
    private let vausCaps = [ModelEntity(), ModelEntity()]
    private var vausX: Float = 112
    private var vausWidth: Float = 32
    private var balls: [ModelEntity] = []
    private var ballPos: [SIMD2<Float>] = []
    private var capsules: [ModelEntity] = []
    private var enemies: [ModelEntity] = []
    private var lasers: [ModelEntity] = []
    private var smoothed: [ObjectIdentifier: SIMD2<Float>] = [:]
    private var debris: [(entity: ModelEntity, velocity: SIMD3<Float>, life: Float)] = []
    private var materials: [UInt32: RealityKit.Material] = [:]
    private var spin: Float = 0

    init(store: GameStateStore, frames: FrameStore) {
        self.store = store
        state.initialize(to: ark3d_state())
        ark3d_default_layout(&layout)
        root.addChild(field)
        buildStatic()
        buildPools()
        let updater = ScreenUpdater(frames: frames)
        screen = updater
        buildDebugScreen(updater.entity)
    }

    // MARK: - coordinates

    /// View pixel (x, y) at height h (metres above the floor) -> field-local metres.
    func local(_ x: Float, _ y: Float, _ h: Float = 0) -> SIMD3<Float> {
        let s = Self.metresPerPixel
        let cy = Float(layout.field_top + layout.field_bottom) / 2
        return SIMD3((x - Float(ARK3D_VIEW_W) / 2) * s, h, (y - cy) * s)
    }

    /// Field-local position (metres) -> view pixel x.
    func viewX(fromLocal p: SIMD3<Float>) -> Float {
        p.x / Self.metresPerPixel + Float(ARK3D_VIEW_W) / 2
    }

    // MARK: - construction

    private func buildStatic() {
        let s = Self.metresPerPixel
        let left = Float(layout.field_left), right = Float(layout.field_right)
        let top = Float(layout.field_top), bottom = Float(layout.field_bottom)
        let depth = (bottom - top) * s

        // floor
        var floorMat = PhysicallyBasedMaterial()
        floorMat.baseColor = .init(tint: UIColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1))
        floorMat.roughness = .init(floatLiteral: 0.6)
        floorMat.metallic = .init(floatLiteral: 0.1)
        let floor = ModelEntity(mesh: .generateBox(width: (right - left) * s, height: 0.004, depth: depth),
                                materials: [floorMat])
        floor.position = local((left + right) / 2, (top + bottom) / 2, -0.002)
        field.addChild(floor)

        // walls: left, right, top (the original's metal pipes)
        var wallMat = PhysicallyBasedMaterial()
        wallMat.baseColor = .init(tint: UIColor(white: 0.7, alpha: 1))
        wallMat.metallic = .init(floatLiteral: 1)
        wallMat.roughness = .init(floatLiteral: 0.3)
        let wallW = Float(layout.field_left) * s
        let h = Self.wallHeight
        for x in [left / 2, right + (Float(ARK3D_VIEW_W) - right) / 2] {
            let wall = ModelEntity(mesh: .generateBox(width: wallW, height: h, depth: depth + wallW, cornerRadius: wallW / 3),
                                   materials: [wallMat])
            wall.position = local(x, (top + bottom) / 2 - Float(layout.field_left) / 2, h / 2)
            field.addChild(wall)
        }
        let topWall = ModelEntity(mesh: .generateBox(width: Float(ARK3D_VIEW_W) * s, height: h, depth: wallW, cornerRadius: wallW / 3),
                                  materials: [wallMat])
        topWall.position = local(Float(ARK3D_VIEW_W) / 2, top - Float(layout.field_left) / 2, h / 2)
        field.addChild(topWall)

        // pinch target over the whole field
        touchSurface.components.set(InputTargetComponent())
        touchSurface.components.set(CollisionComponent(shapes: [.generateBox(width: (right - left) * s, height: 0.12, depth: depth)]))
        touchSurface.position = local((left + right) / 2, (top + bottom) / 2, 0.06)
        field.addChild(touchSurface)

        // soft light from above
        let light = Entity()
        light.components.set(PointLightComponent(color: .white, intensity: 2000, attenuationRadius: 2))
        light.position = local(Float(ARK3D_VIEW_W) / 2, (top + bottom) / 2, 0.4)
        field.addChild(light)
    }

    private func buildPools() {
        let s = Self.metresPerPixel
        let bw = Float(layout.brick_w) * s * 0.94, bd = Float(layout.brick_h) * s * 0.9
        let brickMesh = MeshResource.generateBox(width: bw, height: Self.brickHeight, depth: bd, cornerRadius: 0.0015)
        let rows = Int(min(layout.grid_rows, ARK3D_MAX_GRID_ROWS)), cols = Int(min(layout.grid_cols, ARK3D_MAX_GRID_COLS))
        for r in 0..<rows {
            var row: [ModelEntity] = []
            for c in 0..<cols {
                let e = ModelEntity(mesh: brickMesh, materials: [SimpleMaterial()])
                let x = Float(layout.grid_left) + (Float(c) + 0.5) * Float(layout.brick_w)
                let y = Float(layout.grid_top) + (Float(r) + 0.5) * Float(layout.brick_h)
                e.position = local(x, y, Self.brickHeight / 2)
                e.isEnabled = false
                field.addChild(e)
                row.append(e)
            }
            bricks.append(row)
            brickShown.append([UInt8](repeating: 0, count: cols))
            brickColor.append([UInt32](repeating: 0, count: cols))
        }

        // Vaus: a metallic capsule body with red end caps
        var bodyMat = PhysicallyBasedMaterial()
        bodyMat.baseColor = .init(tint: UIColor(white: 0.85, alpha: 1))
        bodyMat.metallic = .init(floatLiteral: 1)
        bodyMat.roughness = .init(floatLiteral: 0.18)
        vausBody.model = ModelComponent(mesh: .generateBox(width: 1, height: 0.012, depth: 6 * s, cornerRadius: 0.004), materials: [bodyMat])
        vaus.addChild(vausBody)
        var capMat = PhysicallyBasedMaterial()
        capMat.baseColor = .init(tint: UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        capMat.metallic = .init(floatLiteral: 0.6)
        capMat.roughness = .init(floatLiteral: 0.25)
        capMat.emissiveColor = .init(color: UIColor(red: 0.6, green: 0, blue: 0, alpha: 1))
        capMat.emissiveIntensity = 0.4
        for cap in vausCaps {
            cap.model = ModelComponent(mesh: .generateBox(width: 6 * s, height: 0.014, depth: 7 * s, cornerRadius: 0.005), materials: [capMat])
            vaus.addChild(cap)
        }
        vaus.isEnabled = false
        field.addChild(vaus)

        // balls: glowing, each with its own little light
        var ballMat = PhysicallyBasedMaterial()
        ballMat.baseColor = .init(tint: .white)
        ballMat.emissiveColor = .init(color: UIColor(red: 0.8, green: 0.9, blue: 1, alpha: 1))
        ballMat.emissiveIntensity = 2
        for _ in 0..<Int(ARK3D_MAX_BALLS) {
            let b = ModelEntity(mesh: .generateSphere(radius: 2.5 * s), materials: [ballMat])
            b.components.set(PointLightComponent(color: UIColor(red: 0.7, green: 0.85, blue: 1, alpha: 1), intensity: 300, attenuationRadius: 0.15))
            b.isEnabled = false
            field.addChild(b)
            balls.append(b)
            ballPos.append(.zero)
        }

        // capsules: a cylinder lying across the field, letter on top
        for _ in 0..<4 {
            let c = ModelEntity(mesh: .generateCylinder(height: 14 * s, radius: 3.5 * s), materials: [SimpleMaterial()])
            c.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            c.isEnabled = false
            field.addChild(c)
            capsules.append(c)
        }

        for _ in 0..<6 {
            let e = ModelEntity(mesh: .generateSphere(radius: 6 * s), materials: [SimpleMaterial()])
            e.isEnabled = false
            field.addChild(e)
            enemies.append(e)
        }

        var laserMat = UnlitMaterial(color: UIColor(red: 1, green: 0.9, blue: 0.3, alpha: 1))
        laserMat.blending = .transparent(opacity: .init(floatLiteral: 0.9))
        for _ in 0..<6 {
            let l = ModelEntity(mesh: .generateBox(width: 1.5 * s, height: 1.5 * s, depth: 8 * s), materials: [laserMat])
            l.isEnabled = false
            field.addChild(l)
            lasers.append(l)
        }
    }

    /// The original 2D picture, small and upright behind the far wall.
    private func buildDebugScreen(_ screenEntity: ModelEntity) {
        let holder = Entity()
        // ScreenUpdater sizes its plane for a 4.5 m theater screen; a vertical
        // game gets 4.5*0.75 = 3.375 m tall.  Scale that to ~0.3 m.
        holder.scale = SIMD3(repeating: 0.3 / 3.375)
        holder.position = local(Float(ARK3D_VIEW_W) / 2, Float(layout.field_top) - 12, 0.17)
        holder.addChild(screenEntity)
        field.addChild(holder)
        debugScreen = holder
    }
    private var debugScreen: Entity?

    // MARK: - materials

    private func material(rgb: (UInt8, UInt8, UInt8), kind: UInt8) -> RealityKit.Material {
        let key = UInt32(rgb.0) << 16 | UInt32(rgb.1) << 8 | UInt32(rgb.2) | UInt32(kind) << 24
        if let m = materials[key] { return m }
        var m = PhysicallyBasedMaterial()
        let color = UIColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        switch Int(kind) {
        case Int(ARK3D_KIND_BRICK_SILVER.rawValue):
            m.baseColor = .init(tint: UIColor(white: 0.8, alpha: 1))
            m.metallic = .init(floatLiteral: 1)
            m.roughness = .init(floatLiteral: 0.15)
        case Int(ARK3D_KIND_BRICK_GOLD.rawValue):
            m.baseColor = .init(tint: UIColor(red: 1, green: 0.78, blue: 0.3, alpha: 1))
            m.metallic = .init(floatLiteral: 1)
            m.roughness = .init(floatLiteral: 0.2)
        default:
            m.baseColor = .init(tint: color)
            m.metallic = .init(floatLiteral: 0)
            m.roughness = .init(floatLiteral: 0.35)
            m.clearcoat = .init(floatLiteral: 0.8)
        }
        materials[key] = m
        return m
    }

    private static let capsuleColors: [UIColor] = [
        .gray,                                                   // unknown
        UIColor(red: 1, green: 0.55, blue: 0, alpha: 1),         // S slow
        UIColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1),      // C catch
        UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),      // L laser
        UIColor(red: 0.1, green: 0.3, blue: 1, alpha: 1),        // E enlarge
        UIColor(red: 0, green: 0.8, blue: 1, alpha: 1),          // D disruption
        UIColor(red: 1, green: 0.35, blue: 0.8, alpha: 1),       // B break
        UIColor(white: 0.65, alpha: 1),                          // P player
    ]
    private var capsuleMaterials: [Int: RealityKit.Material] = [:]
    private func capsuleMaterial(_ type: Int) -> RealityKit.Material {
        if let m = capsuleMaterials[type] { return m }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: Self.capsuleColors[max(0, min(type, Self.capsuleColors.count - 1))])
        m.metallic = .init(floatLiteral: 0.3)
        m.roughness = .init(floatLiteral: 0.25)
        m.clearcoat = .init(floatLiteral: 1)
        capsuleMaterials[type] = m
        return m
    }

    // MARK: - per frame

    var showDebugScreen = true {
        didSet { debugScreen?.isEnabled = showDebugScreen }
    }

    func update(deltaTime dt: Float) {
        if showDebugScreen { screen?.update() }

        if let newSerial = store.copy(since: serial, into: state) {
            serial = newSerial
            hasState = true
            applyBricks()
        } else if !store.isAvailable {
            hasState = false
        }
        field.isEnabled = true
        animate(dt: dt)
        updateDebris(dt: dt)
    }

    private func applyBricks() {
        let s = state
        for r in 0..<bricks.count {
            for c in 0..<bricks[r].count {
                guard let b = ark3d_brick_at(s, Int32(r), Int32(c))?.pointee else { continue }
                let e = bricks[r][c]
                if b.kind == 0 {
                    if brickShown[r][c] != 0 { shatter(e) }
                    brickShown[r][c] = 0
                    e.isEnabled = false
                    continue
                }
                let key = UInt32(b.rgb.0) << 16 | UInt32(b.rgb.1) << 8 | UInt32(b.rgb.2) | UInt32(b.kind) << 24
                if brickShown[r][c] != b.kind || brickColor[r][c] != key {
                    e.model?.materials = [material(rgb: b.rgb, kind: b.kind)]
                    brickColor[r][c] = key
                    brickShown[r][c] = b.kind
                }
                e.isEnabled = true
            }
        }
    }

    /// exponential ease toward `target`; snaps across big jumps (new round, teleports)
    private func ease(_ current: SIMD2<Float>, _ target: SIMD2<Float>, dt: Float, rate: Float = 35) -> SIMD2<Float> {
        if simd_length(target - current) > 40 { return target }
        return current + (target - current) * (1 - exp(-dt * rate))
    }

    private func animate(dt: Float) {
        spin += dt
        let s = state.pointee
        guard hasState else {
            vaus.isEnabled = false
            balls.forEach { $0.isEnabled = false }
            capsules.forEach { $0.isEnabled = false }
            enemies.forEach { $0.isEnabled = false }
            lasers.forEach { $0.isEnabled = false }
            for row in bricks { row.forEach { $0.isEnabled = false } }
            return
        }

        // Vaus
        vaus.isEnabled = s.vaus_visible != 0
        if s.vaus_visible != 0 {
            let p = ease(SIMD2(vausX, s.vaus_y), SIMD2(s.vaus_x, s.vaus_y), dt: dt, rate: 40)
            vausX = p.x
            vausWidth += (max(s.vaus_w, 8) - vausWidth) * min(1, dt * 12)
            let m = Self.metresPerPixel
            vaus.position = local(vausX, s.vaus_y, 0.008)
            let capW: Float = 6
            vausBody.scale = SIMD3(max(vausWidth - capW, 4) * m, 1, 1)
            vausCaps[0].position = [-(vausWidth - capW) / 2 * m, 0, 0]
            vausCaps[1].position = [(vausWidth - capW) / 2 * m, 0, 0]
        }

        // balls (matched to the nearest previous position so easing follows the right one)
        var used = [Bool](repeating: false, count: balls.count)
        for i in 0..<Int(s.ball_count) {
            guard let o = ark3d_ball_at(state, Int32(i))?.pointee else { continue }
            let target = SIMD2(o.x, o.y)
            var best = -1, bestD = Float.infinity
            for j in 0..<balls.count where !used[j] {
                let d = balls[j].isEnabled ? simd_length(ballPos[j] - target) : 1000 + Float(j)
                if d < bestD { bestD = d; best = j }
            }
            guard best >= 0 else { continue }
            used[best] = true
            ballPos[best] = balls[best].isEnabled ? ease(ballPos[best], target, dt: dt, rate: 50) : target
            balls[best].position = local(ballPos[best].x, ballPos[best].y, 0.006)
            balls[best].isEnabled = true
        }
        for j in 0..<balls.count where !used[j] { balls[j].isEnabled = false }

        // capsules, enemies, lasers
        var ci = 0, ei = 0, li = 0
        for i in 0..<Int(s.object_count) {
            guard let o = ark3d_object_at(state, Int32(i))?.pointee else { continue }
            switch Int(o.kind) {
            case Int(ARK3D_KIND_CAPSULE.rawValue) where ci < capsules.count:
                let c = capsules[ci]; ci += 1
                place(c, o, height: 0.009, dt: dt)
                c.model?.materials = [capsuleMaterial(Int(o.capsule))]
                // roll toward the player as it falls
                c.orientation = simd_quatf(angle: -spin * 4, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            case Int(ARK3D_KIND_ENEMY.rawValue) where ei < enemies.count:
                let e = enemies[ei]; ei += 1
                place(e, o, height: 0.016 + 0.004 * sin(spin * 5 + Float(i)), dt: dt)
                e.model?.materials = [material(rgb: o.rgb, kind: UInt8(ARK3D_KIND_BRICK.rawValue))]
                e.orientation = simd_quatf(angle: spin * 2, axis: [0, 1, 0])
            case Int(ARK3D_KIND_LASER.rawValue) where li < lasers.count:
                let l = lasers[li]; li += 1
                place(l, o, height: 0.008, dt: dt)
            default:
                break
            }
        }
        for j in ci..<capsules.count { capsules[j].isEnabled = false; smoothed[ObjectIdentifier(capsules[j])] = nil }
        for j in ei..<enemies.count { enemies[j].isEnabled = false; smoothed[ObjectIdentifier(enemies[j])] = nil }
        for j in li..<lasers.count { lasers[j].isEnabled = false; smoothed[ObjectIdentifier(lasers[j])] = nil }
    }

    private func place(_ e: ModelEntity, _ o: ark3d_object, height: Float, dt: Float) {
        let id = ObjectIdentifier(e)
        let target = SIMD2(o.x, o.y)
        let p = smoothed[id].map { ease($0, target, dt: dt) } ?? target
        smoothed[id] = p
        e.position = local(p.x, p.y, height)
        e.isEnabled = true
    }

    // MARK: - brick break effect

    /// A brick vanished from the grid: throw a few fragments of it around.
    private func shatter(_ brick: ModelEntity) {
        guard let mat = brick.model?.materials.first, debris.count < 120 else { return }
        let s = Self.metresPerPixel
        let mesh = MeshResource.generateBox(size: 2.5 * s)
        for i in 0..<6 {
            let piece = ModelEntity(mesh: mesh, materials: [mat])
            piece.position = brick.position + SIMD3(Float(i % 3 - 1) * 4 * s, 0, Float(i / 3) * 3 * s - 1.5 * s)
            field.addChild(piece)
            let v = SIMD3<Float>(Float.random(in: -0.25...0.25), Float.random(in: 0.25...0.5), Float.random(in: -0.25...0.1))
            debris.append((piece, v, 0.7))
        }
    }

    private func updateDebris(dt: Float) {
        var i = 0
        while i < debris.count {
            debris[i].life -= dt
            if debris[i].life <= 0 {
                debris[i].entity.removeFromParent()
                debris.remove(at: i)
                continue
            }
            debris[i].velocity.y -= 1.5 * dt
            let e = debris[i].entity
            e.position += debris[i].velocity * dt
            e.scale = SIMD3(repeating: max(0.05, debris[i].life / 0.7))
            e.orientation = simd_quatf(angle: dt * 8, axis: simd_normalize(SIMD3(1, 0.5, 0.2))) * e.orientation
            i += 1
        }
    }
}
