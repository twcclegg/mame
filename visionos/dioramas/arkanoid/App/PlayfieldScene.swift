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
import os
import RealityKit
import UIKit

private let log = Logger(subsystem: "org.mamedev.diorama.arkanoid", category: "scene")

@MainActor
final class PlayfieldScene {
    nonisolated static let metresPerPixel: Float = 0.0025   // 224 px -> 0.56 m wide
    static let brickHeight: Float = 0.012
    static let wallHeight: Float = 0.03

    let root = Entity()
    /// RealityKit update subscription, owned by the view that shows this scene.
    var subscription: EventSubscription?
    /// Invisible slab over the field that takes the pinch-drag gesture.
    let touchSurface = Entity()
    private let field = Entity()                    // everything in view-pixel placement
    private let floor = ModelEntity()
    private var floorKey: [UInt32] = []             // background tiles the floor texture shows
    private var screen: ScreenUpdater?

    private let store: GameStateStore
    private let state = UnsafeMutablePointer<ark3d_state>.allocate(capacity: 1)
    private var serial = -1
    private var hasState = false
    private var layout = ark3d_layout()

    private var bricks: [[ModelEntity]] = []
    private var brickShown: [[UInt8]] = []          // kind shown per cell, for break effects
    private var brickColor: [[UInt32]] = []
    private var brickHome: [[SIMD3<Float>]] = []    // resting position per cell
    /// Seconds since a brick started dropping in (negative: waiting its turn);
    /// nil when it's at rest.
    private var brickDrop: [[Float?]] = []
    private static let dropTime: Float = 0.35
    private let vaus = VausModel()
    private var vausX: Float = 112
    private var vausWidth: Float = 32
    private var vausPhase = Int32(ARK3D_VAUS_NONE.rawValue)
    private var vausAppear: Float = 1               // 0-1 while materialising
    private var balls: [BallModel] = []
    private var ballPos: [SIMD2<Float>] = []
    private var capsules: [CapsuleModel] = []
    private var lastBallCount = 0                   // for the Disruption split
    /// Where enemies were destroyed lately, so each gets one burst.
    private var recentBursts: [(position: SIMD2<Float>, age: Float)] = []
    private var lifeIcons: [VausModel] = []         // spare lives, bottom left, as the game shows them
    private let banner = BannerModel()              // "ROUND n" / "READY"
    private var enemies: [EnemyModel] = []
    private var lasers: [ModelEntity] = []
    private var smoothed: [ObjectIdentifier: SIMD2<Float>] = [:]
    private var debris: [(entity: ModelEntity, velocity: SIMD3<Float>, life: Float)] = []
    /// Expanding, fading glows (breaks and explosions), driven per frame.
    private var flashes: [(entity: ModelEntity, age: Float, duration: Float, size: Float)] = []
    private var flashMesh: MeshResource?
    private var materials: [UInt32: RealityKit.Material] = [:]
    private var spin: Float = 0
    /// The previous decoded frame had a round on screen.  Bricks only shatter
    /// between two such frames: the game wipes and redraws the playfield after
    /// a lost life and between rounds, and that isn't bricks breaking.
    private var lastInPlay = false
    private var outOfPlay: Float = 0

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
        floor.model = ModelComponent(mesh: .generateBox(width: (right - left) * s, height: 0.004, depth: depth),
                                     materials: [floorMat])
        floor.position = local((left + right) / 2, (top + bottom) / 2, -0.002)
        field.addChild(floor)

        // the diorama's base: a bevelled gunmetal plinth under the whole board,
        // walls included, so it reads as an object on the table, not a sheet
        var baseMat = PhysicallyBasedMaterial()
        baseMat.baseColor = .init(tint: UIColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1))
        baseMat.metallic = .init(floatLiteral: 0.85)
        baseMat.roughness = .init(floatLiteral: 0.35)
        let baseHeight: Float = 0.028, rim: Float = 3 * s
        let baseTop = top - Float(layout.field_left)
        let base = ModelEntity(mesh: .generateBox(width: Float(ARK3D_VIEW_W) * s + 2 * rim, height: baseHeight,
                                                  depth: (bottom - baseTop) * s + 2 * rim, cornerRadius: 0.006),
                               materials: [baseMat])
        base.position = local(Float(ARK3D_VIEW_W) / 2, (baseTop + bottom) / 2, -0.004 - baseHeight / 2)
        field.addChild(base)

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
        // the top wall, in segments around the two enemy hatches
        let wallY = top - Float(layout.field_left) / 2
        let gates: [(Float, Float)] = [(Float(ARK3D_GATE_LEFT_COL) * 8, Float(ARK3D_GATE_LEFT_COL + 4) * 8),
                                       (Float(ARK3D_GATE_RIGHT_COL) * 8, Float(ARK3D_GATE_RIGHT_COL + 4) * 8)]
        let segments: [(Float, Float)] = [(0, gates[0].0), (gates[0].1, gates[1].0), (gates[1].1, Float(ARK3D_VIEW_W))]
        for (x0, x1) in segments {
            let seg = ModelEntity(mesh: .generateBox(width: (x1 - x0) * s, height: h, depth: wallW, cornerRadius: wallW / 3),
                                  materials: [wallMat])
            seg.position = local((x0 + x1) / 2, wallY, h / 2)
            field.addChild(seg)
        }
        buildGates(gates, wallY: wallY, wallMat: wallMat)
        buildWarp()

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

    /// Each hatch: a dark opening with a glow deep inside, and two doors that
    /// slide into the wall on either side as the game opens it.
    private func buildGates(_ gates: [(Float, Float)], wallY: Float, wallMat: PhysicallyBasedMaterial) {
        let s = Self.metresPerPixel, h = Self.wallHeight, depth = Float(layout.field_left) * s
        var doorMat = wallMat
        doorMat.baseColor = .init(tint: UIColor(white: 0.55, alpha: 1))
        doorMat.roughness = .init(floatLiteral: 0.25)
        var seamMat = UnlitMaterial(color: UIColor(red: 1, green: 0.15, blue: 0.1, alpha: 1))
        seamMat.blending = .transparent(opacity: .init(floatLiteral: 0.9))
        let holeMat = UnlitMaterial(color: UIColor(white: 0.03, alpha: 1))
        var glowMat = UnlitMaterial(color: UIColor(red: 1, green: 0.45, blue: 0.1, alpha: 1))
        glowMat.blending = .transparent(opacity: .init(floatLiteral: 0.9))
        for (x0, x1) in gates {
            let w = x1 - x0
            // a shallow dark pit, glowing on its floor
            let hole = ModelEntity(mesh: .generateBox(width: w * s, height: h * 0.25, depth: depth), materials: [holeMat])
            hole.position = local((x0 + x1) / 2, wallY, h * 0.125)
            field.addChild(hole)
            let glow = ModelEntity(mesh: .generateBox(width: (w - 3) * s, height: 0.001, depth: depth * 0.7), materials: [glowMat])
            glow.position = local((x0 + x1) / 2, wallY, h * 0.25 + 0.0006)
            glow.isEnabled = false
            field.addChild(glow)
            var doors: [Entity] = []
            for side in 0..<2 {
                // pivot at the door's outer edge, so scaling x slides it into the wall
                let pivot = Entity()
                pivot.position = local(side == 0 ? x0 : x1, wallY, h / 2)
                let door = ModelEntity(mesh: .generateBox(width: w / 2 * s, height: h * 1.02, depth: depth * 1.02, cornerRadius: 0.001),
                                       materials: [doorMat])
                door.position.x = (side == 0 ? 1 : -1) * w / 4 * s
                pivot.addChild(door)
                // a red seam along the edge where the doors meet
                let seam = ModelEntity(mesh: .generateBox(width: 0.6 * s, height: h * 1.03, depth: depth * 1.03), materials: [seamMat])
                seam.position.x = (side == 0 ? 1 : -1) * (w / 2 - 0.3) * s
                pivot.addChild(seam)
                field.addChild(pivot)
                doors.append(pivot)
            }
            gateDoors.append(doors)
            gateGlows.append(glow)
            gateShown.append(0)
        }
    }
    /// The warp gate (B capsule) in the right wall's bottom section.
    private let warp = Entity()
    private let warpGlow = ModelEntity()
    private var warpShown: Float = 0
    private var gateDoors: [[Entity]] = []
    private var gateGlows: [ModelEntity] = []
    private var gateShown: [Float] = []

    /// A doorway of light in the right wall, over its bottom five tile rows.
    private func buildWarp() {
        let s = Self.metresPerPixel, h = Self.wallHeight
        let x = Float(layout.field_right) + 4, y: Float = 236, length: Float = 36
        var frameMat = PhysicallyBasedMaterial()
        frameMat.baseColor = .init(tint: UIColor(white: 0.25, alpha: 1))
        frameMat.metallic = .init(floatLiteral: 1)
        frameMat.roughness = .init(floatLiteral: 0.3)
        frameMat.emissiveColor = .init(color: UIColor(red: 0.2, green: 0.9, blue: 1, alpha: 1))
        frameMat.emissiveIntensity = 1
        for dy in [-length / 2 - 1.5, length / 2 + 1.5] {
            let post = ModelEntity(mesh: .generateBox(width: 10 * s, height: h * 1.15, depth: 3 * s, cornerRadius: 0.001),
                                   materials: [frameMat])
            post.position = local(x, y + dy, h * 0.575)
            warp.addChild(post)
        }
        var glowMat = UnlitMaterial(color: UIColor(red: 0.55, green: 0.95, blue: 1, alpha: 1))
        glowMat.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        warpGlow.model = ModelComponent(mesh: .generateBox(width: 9.5 * s, height: h * 1.05, depth: length * s), materials: [glowMat])
        warpGlow.position = local(x, y, h * 0.525)
        warpGlow.components.set(PointLightComponent(color: UIColor(red: 0.4, green: 0.9, blue: 1, alpha: 1),
                                                    intensity: 600, attenuationRadius: 0.25))
        warp.addChild(warpGlow)
        warp.isEnabled = false
        field.addChild(warp)
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
                e.components.set(GroundingShadowComponent(castsShadow: true))
                let x = Float(layout.grid_left) + (Float(c) + 0.5) * Float(layout.brick_w)
                let y = Float(layout.grid_top) + (Float(r) + 0.5) * Float(layout.brick_h)
                e.position = local(x, y, Self.brickHeight / 2)
                e.isEnabled = false
                field.addChild(e)
                row.append(e)
            }
            bricks.append(row)
            brickHome.append(row.map(\.position))
            brickDrop.append([Float?](repeating: nil, count: cols))
            brickShown.append([UInt8](repeating: 0, count: cols))
            brickColor.append([UInt32](repeating: 0, count: cols))
        }

        vaus.isEnabled = false
        field.addChild(vaus)

        for i in 0..<5 {
            let icon = VausModel()
            icon.setWidth(16)
            icon.scale = SIMD3(repeating: 0.75)
            icon.position = local(Float(8 + 16 * i + 8), Float(ARK3D_VIEW_H) - 4, 0)
            icon.isEnabled = false
            field.addChild(icon)
            lifeIcons.append(icon)
        }

        banner.position = local(112, 170, 0)
        field.addChild(banner)

        for _ in 0..<Int(ARK3D_MAX_BALLS) {
            let b = BallModel()
            b.isEnabled = false
            field.addChild(b)
            b.attachTrail(to: field)
            balls.append(b)
            ballPos.append(.zero)
        }

        for _ in 0..<4 {
            let c = CapsuleModel()
            c.isEnabled = false
            field.addChild(c)
            capsules.append(c)
        }

        for _ in 0..<6 {
            let e = EnemyModel()
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
            // polished: bright, glossy, lifted a little so it reads as silver
            // whatever the room it reflects
            m.baseColor = .init(tint: UIColor(white: 0.97, alpha: 1))
            m.metallic = .init(floatLiteral: 1)
            m.roughness = .init(floatLiteral: 0.06)
            m.clearcoat = .init(floatLiteral: 1)
            m.emissiveColor = .init(color: UIColor(white: 0.55, alpha: 1))
            m.emissiveIntensity = 0.25
        case Self.silverFlash:
            m.baseColor = .init(tint: .white)
            m.metallic = .init(floatLiteral: 1)
            m.roughness = .init(floatLiteral: 0.05)
            m.emissiveColor = .init(color: .white)
            m.emissiveIntensity = 1.5
        case Int(ARK3D_KIND_BRICK_GOLD.rawValue):
            m.baseColor = .init(tint: UIColor(red: 1, green: 0.8, blue: 0.35, alpha: 1))
            m.metallic = .init(floatLiteral: 1)
            m.roughness = .init(floatLiteral: 0.1)
            m.clearcoat = .init(floatLiteral: 1)
            m.emissiveColor = .init(color: UIColor(red: 0.6, green: 0.4, blue: 0.05, alpha: 1))
            m.emissiveIntensity = 0.25
        default:
            m.baseColor = .init(tint: color)
            m.metallic = .init(floatLiteral: 0)
            m.roughness = .init(floatLiteral: 0.35)
            m.clearcoat = .init(floatLiteral: 0.8)
        }
        materials[key] = m
        return m
    }

    /// Material kind for a silver brick the game is animating (hit, or the
    /// shimmer at the start of a round): its tiles run through 170-179.
    private static let silverFlash = 255

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
            updateFloor()
        } else if !store.isAvailable {
            hasState = false
        }
        // off the playfield (title, high-score table) for a while: clear the
        // last round away quietly
        outOfPlay = hasState && state.pointee.in_play != 0 ? 0 : outOfPlay + dt
        if outOfPlay > 2.5 { clearBricks() }
        field.isEnabled = true
        dropBricks(dt: dt)
        animate(dt: dt)
        updateDebris(dt: dt)
        updateFlashes(dt: dt)
    }

    private func applyBricks() {
        let s = state
        // not in play (a wipe, or another screen): hold what's shown
        guard s.pointee.in_play != 0 else {
            lastInPlay = false
            return
        }
        let breaking = lastInPlay
        lastInPlay = true
        for r in 0..<bricks.count {
            for c in 0..<bricks[r].count {
                guard let b = ark3d_brick_at(s, Int32(r), Int32(c))?.pointee else { continue }
                let e = bricks[r][c]
                if b.kind == 0 {
                    if brickShown[r][c] != 0 && breaking {
                        let k = brickColor[r][c]
                        shatter(e, color: UIColor(red: CGFloat(k >> 16 & 0xff) / 255, green: CGFloat(k >> 8 & 0xff) / 255,
                                                  blue: CGFloat(k & 0xff) / 255, alpha: 1))
                    }
                    brickShown[r][c] = 0
                    e.isEnabled = false
                    continue
                }
                let flashing = b.kind == UInt8(ARK3D_KIND_BRICK_SILVER.rawValue) && b.code != 0x16e
                let kind = flashing ? UInt8(Self.silverFlash) : b.kind
                let key = UInt32(b.rgb.0) << 16 | UInt32(b.rgb.1) << 8 | UInt32(b.rgb.2) | UInt32(kind) << 24
                if brickShown[r][c] != b.kind || brickColor[r][c] != key {
                    if flashing && brickShown[r][c] == b.kind && breaking {
                        flash(at: e.position + [0, Self.brickHeight / 2, 0], color: .white, size: 12, duration: 0.2)
                    }
                    // a new layout (round start, or redrawn after a wipe) drops
                    // in row by row, far rows first
                    if brickShown[r][c] == 0 && !breaking {
                        brickDrop[r][c] = -(Float(r) * 0.03 + Float(c) * 0.008)
                    }
                    e.model?.materials = [material(rgb: b.rgb, kind: kind)]
                    brickColor[r][c] = key
                    brickShown[r][c] = b.kind
                }
                e.isEnabled = true
            }
        }
    }

    // MARK: - the game's own pixels

    /// The floor shows the round's background pattern, rebuilt when it changes.
    private func updateFloor() {
        guard state.pointee.in_play != 0, let art = store.art else { return }
        // key: the band the decoder learns the background from
        var key: [UInt32] = []
        let top = Int(layout.reference_top) / 8, bottom = Int(layout.reference_bottom) / 8
        for r in top..<bottom {
            for c in Int(layout.field_left) / 8..<Int(layout.field_right) / 8 {
                key.append(UInt32(ark3d_tile_code_at(state, Int32(r), Int32(c))) << 8 | UInt32(ark3d_tile_color_at(state, Int32(r), Int32(c))))
            }
        }
        guard key != floorKey, let image = art.backgroundImage(state, layout: layout, scale: 4) else { return }
        floorKey = key
        Task { @MainActor [weak self] in
            guard let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return }
            var m = PhysicallyBasedMaterial()
            // dimmed, so the bricks and objects stand out from it
            m.baseColor = .init(tint: UIColor(white: 0.55, alpha: 1), texture: .init(texture))
            m.roughness = .init(floatLiteral: 0.7)
            m.metallic = .init(floatLiteral: 0)
            self?.backgroundMaterial = m
            self?.applyFloor()
        }
    }

    /// The game's own background on the floor, or a plain one of ours (the
    /// choice in the control window; also what an IP-free version would use).
    var showGameBackground = true {
        didSet { if showGameBackground != oldValue { applyFloor() } }
    }
    private var backgroundMaterial: RealityKit.Material?
    private lazy var plainFloor: RealityKit.Material = {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1))
        // satin, not gloss: a glossy floor mirrors the room's bright spots
        m.metallic = .init(floatLiteral: 0.2)
        m.roughness = .init(floatLiteral: 0.6)
        // a faint grid of brick-sized cells, so it reads as a board
        if let grid = Self.gridImage(layout: layout),
           let texture = try? TextureResource(image: grid, options: .init(semantic: .color)) {
            m.baseColor = .init(tint: .white, texture: .init(texture))
        }
        return m
    }()

    private static func gridImage(layout: ark3d_layout) -> CGImage? {
        let scale = 4
        let w = Int(layout.field_right - layout.field_left) * scale
        let h = Int(layout.field_bottom - layout.field_top) * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0.13, green: 0.15, blue: 0.22, alpha: 1)
        let bw = Int(layout.brick_w) * scale, bh = Int(layout.brick_h) * scale
        for x in stride(from: 0, through: w, by: bw) { ctx.fill(CGRect(x: x, y: 0, width: 2, height: h)) }
        for y in stride(from: 0, through: h, by: bh) { ctx.fill(CGRect(x: 0, y: y, width: w, height: 2)) }
        return ctx.makeImage()
    }

    private func applyFloor() {
        floor.model?.materials = [showGameBackground ? (backgroundMaterial ?? plainFloor) : plainFloor]
    }

    private func dropBricks(dt: Float) {
        for r in 0..<brickDrop.count {
            for c in 0..<brickDrop[r].count {
                guard var t = brickDrop[r][c] else { continue }
                t += dt
                let e = bricks[r][c]
                if t >= Self.dropTime {
                    brickDrop[r][c] = nil
                    e.position = brickHome[r][c]
                    e.scale = .one
                    continue
                }
                brickDrop[r][c] = t
                // fall from above with a little squash on landing
                let k = max(0, t) / Self.dropTime
                e.position = brickHome[r][c] + [0, (1 - k) * (1 - k) * 0.08, 0]
                e.scale = t < 0 ? SIMD3(repeating: 0.001) : [1, 0.85 + 0.15 * k, 1]
            }
        }
    }

    private func clearBricks() {
        for r in 0..<bricks.count {
            for c in 0..<bricks[r].count where brickShown[r][c] != 0 {
                bricks[r][c].isEnabled = false
                brickShown[r][c] = 0
                brickDrop[r][c] = nil
            }
        }
        lastInPlay = false
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
            clearBricks()
            return
        }

        // enemy hatches: doors follow the game's 5 steps, smoothed
        let open = [s.gate_open.0, s.gate_open.1]
        for g in 0..<gateDoors.count {
            gateShown[g] += (open[g] - gateShown[g]) * min(1, dt * 18)
            let closed = max(0.001, 1 - gateShown[g])
            for pivot in gateDoors[g] { pivot.scale = [closed, 1, 1] }
            gateGlows[g].isEnabled = gateShown[g] > 0.05
        }

        banner.update(round: Int(s.banner_round), ready: s.banner_ready != 0, dt: dt)

        // warp gate: opens with the game's steps, then shimmers
        warpShown += (s.warp_open - warpShown) * min(1, dt * 14)
        warp.isEnabled = warpShown > 0.02
        if warp.isEnabled {
            let flicker = 0.85 + 0.15 * sin(spin * 23) * sin(spin * 7)
            warpGlow.scale = [1, 1, max(0.02, warpShown)]
            if var m = warpGlow.model?.materials.first as? UnlitMaterial {
                m.blending = .transparent(opacity: .init(floatLiteral: 0.85 * flicker * warpShown))
                warpGlow.model?.materials = [m]
            }
        }

        let spare = Int(s.spare_lives)
        if spare >= 0 {
            for (i, icon) in lifeIcons.enumerated() { icon.isEnabled = i < spare }
        } else if outOfPlay > 2.5 {
            lifeIcons.forEach { $0.isEnabled = false }
        }

        // Vaus: materialises by growing, explodes into sparks
        let phase = s.vaus_phase
        if phase != vausPhase {
            log.debug("vaus phase \(self.vausPhase) -> \(phase)")
            if phase == Int32(ARK3D_VAUS_EXPLODING.rawValue) {
                explodeVaus(at: local(vausX, s.vaus_y, 4 * Self.metresPerPixel))
            } else if phase == Int32(ARK3D_VAUS_APPEARING.rawValue) {
                vausAppear = 0
            }
            vausPhase = phase
        }
        vaus.isEnabled = s.vaus_visible != 0 && phase != Int32(ARK3D_VAUS_EXPLODING.rawValue)
        if vaus.isEnabled {
            let p = ease(SIMD2(vausX, s.vaus_y), SIMD2(s.vaus_x, s.vaus_y), dt: dt, rate: 40)
            vausX = p.x
            if phase == Int32(ARK3D_VAUS_NORMAL.rawValue) {
                vausWidth += (max(s.vaus_w, 8) - vausWidth) * min(1, dt * 12)
            }
            vausAppear = min(1, vausAppear + dt * 2)
            vaus.setWidth(vausWidth)
            vaus.setLaser(s.vaus_laser != 0)
            vaus.scale = [max(0.05, vausAppear), 1, 1]
            vaus.position = local(vausX, s.vaus_y, 0)
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
            balls[best].place(local(ballPos[best].x, ballPos[best].y, BallModel.radius * Self.metresPerPixel), visible: true)
        }
        for j in 0..<balls.count where !used[j] { balls[j].place(.zero, visible: false) }

        // Disruption (D capsule): one ball becomes three, with a shockwave
        let ballCount = Int(s.ball_count)
        if ballCount >= 2 && lastBallCount == 1, let o = ark3d_ball_at(state, 0)?.pointee {
            let at = local(o.x, o.y, BallModel.radius * Self.metresPerPixel)
            flash(at: at, color: UIColor(red: 0.3, green: 0.9, blue: 1, alpha: 1), size: 60, duration: 0.45)
            flash(at: at, color: .white, size: 22, duration: 0.2)
            Effects.sparks(in: field, at: at, color: .cyan, count: 60, scale: 1.6)
        }
        lastBallCount = ballCount

        // capsules, enemies, lasers, enemy explosions
        for i in recentBursts.indices { recentBursts[i].age += dt }
        recentBursts.removeAll { $0.age > 0.8 }
        var ci = 0, ei = 0, li = 0
        for i in 0..<Int(s.object_count) {
            guard let o = ark3d_object_at(state, Int32(i))?.pointee else { continue }
            switch Int(o.kind) {
            case Int(ARK3D_KIND_CAPSULE.rawValue) where ci < capsules.count:
                let c = capsules[ci]; ci += 1
                place(c, o, height: CapsuleModel.radius * Self.metresPerPixel, dt: dt)
                c.show(type: Int(o.capsule))
                c.roll(t: spin + Float(ci))
            case Int(ARK3D_KIND_ENEMY.rawValue) where ei < enemies.count:
                let e = enemies[ei]; ei += 1
                e.show(type: Int(ark3d_enemy_type(o.code)))
                place(e, o, height: 0, dt: dt)
                e.animate(t: spin, seed: Float(ei) * 1.7)
            case Int(ARK3D_KIND_EXPLOSION.rawValue):
                // an enemy destroyed: one burst per explosion
                let p = SIMD2(o.x, o.y)
                if !recentBursts.contains(where: { simd_length($0.position - p) < 16 }) {
                    recentBursts.append((p, 0))
                    let color = UIColor(red: CGFloat(o.rgb.0) / 255, green: CGFloat(o.rgb.1) / 255, blue: CGFloat(o.rgb.2) / 255, alpha: 1)
                    let at = local(o.x, o.y, 8 * Self.metresPerPixel)
                    flash(at: at, color: .white, size: 26, duration: 0.3)
                    Effects.sparks(in: field, at: at, color: color, count: 40, scale: 1.4)
                    var m = PhysicallyBasedMaterial()
                    m.baseColor = .init(tint: color)
                    m.emissiveColor = .init(color: color)
                    m.emissiveIntensity = 0.8
                    throwDebris(from: at, material: m, count: 8, speed: 0.45)
                }
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

    private func place(_ e: Entity, _ o: ark3d_object, height: Float, dt: Float) {
        let id = ObjectIdentifier(e)
        let target = SIMD2(o.x, o.y)
        let p = smoothed[id].map { ease($0, target, dt: dt) } ?? target
        smoothed[id] = p
        e.position = local(p.x, p.y, height)
        e.isEnabled = true
    }

    // MARK: - brick break effect

    /// A brick vanished from the grid: throw a few fragments of it around.
    private func shatter(_ brick: ModelEntity, color: UIColor) {
        Effects.sparks(in: field, at: brick.position + [0, Self.brickHeight / 2, 0], color: color)
        flash(at: brick.position + [0, Self.brickHeight / 2, 0], color: color, size: 20, duration: 0.25)
        guard let mat = brick.model?.materials.first else { return }
        throwDebris(from: brick.position, material: mat, count: 6, speed: 0.35)
    }

    /// The Vaus blows up: a big flash, and its pieces flying.
    private func explodeVaus(at p: SIMD3<Float>) {
        Effects.sparks(in: field, at: p, color: .orange, count: 150, scale: 2.5)
        flash(at: p, color: UIColor(red: 1, green: 0.6, blue: 0.2, alpha: 1), size: 70, duration: 0.6)
        flash(at: p, color: .white, size: 30, duration: 0.25)
        var red = PhysicallyBasedMaterial()
        red.baseColor = .init(tint: UIColor(red: 0.8, green: 0.08, blue: 0.06, alpha: 1))
        red.emissiveColor = .init(color: UIColor(red: 1, green: 0.3, blue: 0, alpha: 1))
        red.emissiveIntensity = 1
        var silver = PhysicallyBasedMaterial()
        silver.baseColor = .init(tint: UIColor(white: 0.85, alpha: 1))
        silver.metallic = .init(floatLiteral: 1)
        silver.roughness = .init(floatLiteral: 0.2)
        throwDebris(from: p, material: red, count: 10, speed: 0.6)
        throwDebris(from: p, material: silver, count: 10, speed: 0.6)
    }

    private func throwDebris(from p: SIMD3<Float>, material: RealityKit.Material, count: Int, speed: Float) {
        guard debris.count < 160 else { return }
        let s = Self.metresPerPixel
        let mesh = MeshResource.generateBox(size: 2.5 * s)
        for _ in 0..<count {
            let piece = ModelEntity(mesh: mesh, materials: [material])
            piece.position = p + SIMD3(Float.random(in: -4...4) * s, 0, Float.random(in: -2...2) * s)
            field.addChild(piece)
            let v = SIMD3<Float>(Float.random(in: -1...1), Float.random(in: 0.7...1.4), Float.random(in: -1...0.3)) * speed
            debris.append((piece, v, 0.7))
        }
    }

    /// A glowing sphere that grows to `size` view pixels across and fades out.
    private func flash(at p: SIMD3<Float>, color: UIColor, size: Float, duration: Float) {
        guard flashes.count < 24 else { return }
        if flashMesh == nil { flashMesh = .generateSphere(radius: 0.5) }
        var m = UnlitMaterial(color: color)
        m.blending = .transparent(opacity: .init(floatLiteral: 0.5))
        let e = ModelEntity(mesh: flashMesh!, materials: [m])
        e.position = p
        e.scale = .zero
        field.addChild(e)
        flashes.append((e, 0, duration, size * Self.metresPerPixel))
    }

    private func updateFlashes(dt: Float) {
        var i = 0
        while i < flashes.count {
            flashes[i].age += dt
            let k = flashes[i].age / flashes[i].duration
            if k >= 1 {
                flashes[i].entity.removeFromParent()
                flashes.remove(at: i)
                continue
            }
            let e = flashes[i].entity
            e.scale = SIMD3(repeating: flashes[i].size * (0.3 + 0.7 * sqrt(k)))
            if var m = e.model?.materials.first as? UnlitMaterial {
                m.blending = .transparent(opacity: .init(floatLiteral: 0.5 * (1 - k) * (1 - k) * (1 - k)))
                e.model?.materials = [m]
            }
            i += 1
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
