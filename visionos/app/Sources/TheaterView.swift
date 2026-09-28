// license:BSD-3-Clause
//
// TheaterView - the game on a large virtual screen in an ImmersiveSpace.
//
// Each RealityKit scene update, the newest MAME frame is uploaded into a
// staging texture and present_kernel (Shaders.metal) writes it, with the
// selected effect, into a LowLevelTexture at an integer multiple of the
// source size.  The screen entity's UnlitMaterial samples that texture.
// This is the route Apple recommends for per-frame Metal content in
// RealityKit (WWDC24 "Bring your iOS or iPadOS game to visionOS").

import SwiftUI
import RealityKit
import Metal

struct TheaterView: View {
    @State private var screen = ScreenUpdater(frames: MAMEEngine.shared.frames)

    var body: some View {
        RealityView { content in
            let anchor = Entity()
            // ~4.5 m wide, eye height, 5 m in front of the user's starting position
            anchor.position = SIMD3(0, 1.4, -5)
            anchor.addChild(screen.entity)
            content.add(anchor)
            screen.subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                screen.update()
            }
        }
        // a theater screen shows just the game screen, not bezel artwork around it
        .onAppear { MAMEEngine.shared.setZoomToScreen(true) }
        .onDisappear { MAMEEngine.shared.setZoomToScreen(false) }
    }
}

/// Owns the screen entity and keeps its texture in sync with the emulator.
/// RealityKit's LowLevelTexture APIs are @MainActor-isolated, and this type
/// is only ever touched from RealityView's content closure and its scene
/// update subscription, both of which already run on the main actor.
@MainActor
final class ScreenUpdater {
    /// Screen width in metres (for landscape games); height follows the frame's aspect ratio.
    static let screenWidth: Float = 4.5
    /// Cap on the output texture's larger side.  A 4.5 m screen at 5 m spans
    /// ~48 degrees, roughly 1750 display pixels on Vision Pro, so more is wasted.
    static let maxOutputDimension = 2048

    let entity = ModelEntity()
    var subscription: EventSubscription?

    private let frames: FrameStore
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let kernel: MTLComputePipelineState

    private var lastSerial = -1
    private var info = FrameInfo()
    private var staging: [MTLTexture?] = [nil, nil, nil, nil]
    private var stagingBusy = [Bool](repeating: false, count: 4)
    private let busyLock = NSLock()
    private var current = 0
    private var output: LowLevelTexture?
    private var outputSize = (width: 0, height: 0)
    private var screenAspect: Float = 0
    private var lastEffect: ScreenEffect?

    init(frames: FrameStore) {
        self.frames = frames
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let library = device.makeDefaultLibrary()!
        kernel = try! device.makeComputePipelineState(function: library.makeFunction(name: "present_kernel")!)

        // placeholder until the first frame arrives
        entity.model = ModelComponent(mesh: .generatePlane(width: Self.screenWidth, height: Self.screenWidth * 0.75),
                                      materials: [UnlitMaterial(color: .black)])
    }

    /// Called on the main thread every RealityKit frame.
    func update() {
        var uploaded = false
        frames.read(since: lastSerial) { pixels, frame in
            let width = frame.width, height = frame.height
            let next = (current + 1) % staging.count
            busyLock.lock()
            let busy = stagingBusy[next]
            busyLock.unlock()
            guard !busy else { return }   // GPU still reading it: take this frame next time

            var tex = staging[next]
            if tex == nil || tex!.width != width || tex!.height != height {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                td.usage = .shaderRead
                td.storageMode = .shared
                tex = device.makeTexture(descriptor: td)
                staging[next] = tex
            }
            tex!.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
            current = next
            lastSerial = frame.serial
            info = frame
            uploaded = true
        }

        let effect = PresentSettings.effect
        guard uploaded || effect != lastEffect, let src = staging[current] else { return }
        lastEffect = effect

        ensureOutput(for: info)
        guard let output, let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return }

        let dst = output.replace(using: cmd)
        let sw = info.sourceWidth > 0 ? info.sourceWidth : info.width
        let sh = info.sourceHeight > 0 ? info.sourceHeight : info.height
        var params = PresentParams(srcSize: SIMD2(Float(sw), Float(sh)),
                                   dstSize: SIMD2(Float(outputSize.width), Float(outputSize.height)),
                                   scale: SIMD2(1, 1),
                                   effect: effect.rawValue)
        enc.setComputePipelineState(kernel)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (outputSize.width + 15) / 16, height: (outputSize.height + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: tg)
        enc.endEncoding()

        let slot = current
        busyLock.lock(); stagingBusy[slot] = true; busyLock.unlock()
        cmd.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.busyLock.lock(); self.stagingBusy[slot] = false; self.busyLock.unlock()
        }
        cmd.commit()
    }

    /// (Re)creates the output texture and screen mesh when the frame geometry changes.
    private func ensureOutput(for frame: FrameInfo) {
        let sw = frame.sourceWidth > 0 ? frame.sourceWidth : frame.width
        let sh = frame.sourceHeight > 0 ? frame.sourceHeight : frame.height
        guard sw > 0, sh > 0 else { return }
        // integer multiple of the native resolution, so "sharp" and the CRT
        // scanlines/mask have whole pixels to work with
        let factor = max(1, min(Self.maxOutputDimension / sw, Self.maxOutputDimension / sh))
        let want = (width: sw * factor, height: sh * factor)
        guard output == nil || want != outputSize || frame.aspect != screenAspect else { return }

        var desc = LowLevelTexture.Descriptor()
        desc.pixelFormat = .bgra8Unorm
        desc.width = want.width
        desc.height = want.height
        desc.depth = 1
        desc.mipmapLevelCount = 1
        desc.textureUsage = [.shaderRead, .shaderWrite]
        guard let llt = try? LowLevelTexture(descriptor: desc),
              let resource = try? TextureResource(from: llt) else { return }
        output = llt
        outputSize = want

        var material = UnlitMaterial()
        material.color = .init(texture: .init(resource))
        // landscape: fixed width; portrait (vertical games): same height as a 4:3 screen
        screenAspect = frame.aspect
        let width = frame.aspect >= 1 ? Self.screenWidth : Self.screenWidth * 0.75 * frame.aspect
        entity.model = ModelComponent(mesh: .generatePlane(width: width, height: width / frame.aspect),
                                      materials: [material])
    }
}
