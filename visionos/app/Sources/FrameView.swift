// license:BSD-3-Clause
//
// FrameView - shows MAMEEngine's latest frame in an MTKView.
//
// Frames arrive on the MAME thread (FrameStore); each draw uploads the newest
// one into the next of four rotating textures.  At most three command buffers
// are in flight and we wait for a slot before uploading, so the texture being
// written was last used at least three draws ago and is no longer being sampled.

import SwiftUI
import MetalKit

struct FrameView: UIViewRepresentable {
    let frames: FrameStore

    func makeCoordinator() -> Renderer { Renderer(frames: frames) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let sampler: MTLSamplerState
        private let frames: FrameStore
        private var textures: [MTLTexture?] = [nil, nil, nil, nil]
        private var current = 0
        private var lastSerial = -1
        private let inflight = DispatchSemaphore(value: 3)

        init(frames: FrameStore) {
            self.frames = frames
            device = MTLCreateSystemDefaultDevice()!
            queue = device.makeCommandQueue()!

            let library = device.makeDefaultLibrary()!
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "frame_vertex")
            desc.fragmentFunction = library.makeFunction(name: "frame_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try! device.makeRenderPipelineState(descriptor: desc)

            // nearest: keep pixels crisp; upscaling filters come later
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .nearest
            sd.magFilter = .nearest
            sampler = device.makeSamplerState(descriptor: sd)!
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            inflight.wait()

            // upload a new frame, if any, into the next texture in the ring
            frames.read(since: lastSerial) { pixels, width, height, serial in
                let next = (current + 1) % textures.count
                var tex = textures[next]
                if tex == nil || tex!.width != width || tex!.height != height {
                    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                    td.usage = .shaderRead
                    td.storageMode = .shared
                    tex = device.makeTexture(descriptor: td)
                    textures[next] = tex
                }
                tex!.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                             withBytes: pixels, bytesPerRow: width * 4)
                current = next
                lastSerial = serial
            }

            guard let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
                inflight.signal()
                return
            }

            if let tex = textures[current] {
                // aspect-fit the frame into the drawable
                let dw = Float(view.drawableSize.width), dh = Float(view.drawableSize.height)
                let fw = Float(tex.width), fh = Float(tex.height)
                var scale = SIMD2<Float>(1, 1)
                if dw > 0, dh > 0 {
                    if dw / dh > fw / fh { scale.x = (fw / fh) / (dw / dh) } else { scale.y = (dw / dh) / (fw / fh) }
                }
                enc.setRenderPipelineState(pipeline)
                enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentSamplerState(sampler, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()

            cmd.addCompletedHandler { [inflight] _ in inflight.signal() }
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
