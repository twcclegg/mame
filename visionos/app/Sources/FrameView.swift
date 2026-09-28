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
        private let frames: FrameStore
        private var textures: [MTLTexture?] = [nil, nil, nil, nil]
        private var current = 0
        private var lastSerial = -1
        private var info = FrameInfo()
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
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            inflight.wait()

            // upload a new frame, if any, into the next texture in the ring
            frames.read(since: lastSerial) { pixels, frame in
                let width = frame.width, height = frame.height
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
                lastSerial = frame.serial
                info = frame
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
                // (by the intended display aspect: pixels may be non-square)
                let dw = Float(view.drawableSize.width), dh = Float(view.drawableSize.height)
                let aspect = info.aspect
                var scale = SIMD2<Float>(1, 1)
                if dw > 0, dh > 0 {
                    if dw / dh > aspect { scale.x = aspect / (dw / dh) } else { scale.y = (dw / dh) / aspect }
                }
                let src = SIMD2(Float(info.sourceWidth > 0 ? info.sourceWidth : tex.width),
                                Float(info.sourceHeight > 0 ? info.sourceHeight : tex.height))
                var params = PresentParams(srcSize: src,
                                           dstSize: SIMD2(dw * scale.x, dh * scale.y),
                                           scale: scale,
                                           effect: PresentSettings.effect.rawValue)
                enc.setRenderPipelineState(pipeline)
                enc.setVertexBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
                enc.setFragmentBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()

            cmd.addCompletedHandler { [inflight] _ in inflight.signal() }
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
