#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SwiftUI
import Spatial

class MetalKitSceneRenderer: NSObject, MTKViewDelegate {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "MetalKitSceneRenderer")

    let metalKitView: MTKView
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: SplatRenderer?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero

    var drawableSize: CGSize = .zero

    init?(_ metalKitView: MTKView) {
        self.device = metalKitView.device!
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.metalKitView = metalKitView
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelRenderer = nil
        switch model {
        case .gaussianSplat(let url):
            _ = url.startAccessingSecurityScopedResource()
            print("Trying to open:", url)
            let splat = try await SplatRenderer(device: device,
                                                colorFormat: metalKitView.colorPixelFormat,
                                                depthFormat: metalKitView.depthStencilPixelFormat,
                                                sampleCount: metalKitView.sampleCount,
                                                maxViewCount: 1,
                                                maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            try await splat.read(from: url)
            modelRenderer = splat
            
#if false
            print("Trying to preview:", url)
            var modelRenderer: SplatRenderer? = nil
            do {
                let splat = try SplatRenderer(device: device,
                                          colorFormat: .bgra8Unorm_srgb,
                                          depthFormat: .depth32Float,
                                          sampleCount: 1,
                                          maxViewCount: 1,
                                          maxSimultaneousRenders: 1)
                try await splat.read(from: url)
                modelRenderer = splat
            }
            catch {
                
            }

            let size = CGSize(width: 256, height: 256)

            let drawing: (CGContext) -> Bool = { (ctx: CGContext) in
                // --- 1. Create offscreen color & depth textures ---
                let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm_srgb,
                    width: Int(size.width),
                    height: Int(size.height),
                    mipmapped: false
                )
                colorDesc.usage = [.renderTarget, .shaderRead]
                guard let colorTexture = self.device.makeTexture(descriptor: colorDesc) else {
                    print("Failed colorTexture")
                    return false
                }

                let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .depth32Float,
                    width: Int(size.width),
                    height: Int(size.height),
                    mipmapped: false
                )
                depthDesc.usage = [.renderTarget, .shaderRead]
                depthDesc.storageMode = .private
                guard let depthTexture = self.device.makeTexture(descriptor: depthDesc) else {
                    print("Failed depthTexture")
                    return false
                }

                // --- 2. Prepare viewport / render pass descriptor ---
                var viewport = MTLViewport(originX: 0, originY: 0,
                                           width: Double(size.width),
                                           height: Double(size.height),
                                           znear: 0, zfar: 1)
                
                let translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
                // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
                // happens to be a useful default for the most common datasets at the moment.
                let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

                let simdDeviceAnchor = matrix_identity_float4x4
                
                let rotationMatrix = matrix4x4_rotation(radians: .pi,
                                                        axis: Constants.rotationAxis)
                let projectionMatrix = ProjectiveTransform3D(leftTangent: Double(1.0),
                                                         rightTangent: Double(1.0),
                                                         topTangent: Double(1.0),
                                                         bottomTangent: Double(1.0),
                                                         nearZ: 0.1,
                                                         farZ: 100.0,
                                                         reverseZ: true)
                let screenSize = SIMD2(x: Int(viewport.width),
                                           y: Int(viewport.height))

                let modelViewport = SplatRenderer.ViewportDescriptor(viewport: viewport,
                                                   projectionMatrix: .init(projectionMatrix),
                                                   viewMatrix: translationMatrix * rotationMatrix * commonUpCalibration,
                                                   screenSize: screenSize)

                for i in 0..<6 {
                    guard let commandBuffer = self.commandQueue.makeCommandBuffer() else {
                        print("Failed commandBuffer")
                        return false
                    }
                    
                    // --- 3. Call your existing modelRenderer ---
                    do {
                        try? modelRenderer?.render(
                            viewports: [modelViewport],
                            colorTexture: colorTexture,
                            colorStoreAction: .store,
                            depthTexture: depthTexture,
                            rasterizationRateMap: nil,
                            renderTargetArrayLength: 1,
                            to: commandBuffer
                        )
                    }
                    catch {
                        print("Failed in modelRenderer")
                    }

                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                }

                // --- 4. Read back the color texture into CGContext ---
                let bytesPerPixel = 4
                let bytesPerRow = bytesPerPixel * Int(size.width)
                let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: Int(size.width), height: Int(size.height), depth: 1))
                let pixelData = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * Int(size.height), alignment: 1)
                defer { pixelData.deallocate() }

                colorTexture.getBytes(pixelData,
                                      bytesPerRow: bytesPerRow,
                                      from: region,
                                      mipmapLevel: 0)

                let colorSpace = CGColorSpaceCreateDeviceRGB()
                guard let bitmapCtx = CGContext(data: pixelData,
                                                width: Int(size.width),
                                                height: Int(size.height),
                                                bitsPerComponent: 8,
                                                bytesPerRow: bytesPerRow,
                                                space: colorSpace,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else {
                    print("Failed in bitmapCtx")
                    return false
                }

                // Draw the Metal bitmap into the Quick Look CGContext
                ctx.draw(bitmapCtx.makeImage()!, in: CGRect(origin: .zero, size: size))
                print("Success!")
                return true
            }
            
            if #available(macCatalyst 26.0, *) {
                let ctx = CGContext(width: 256, height: 256, auxiliaryInfo: .init())!
                drawing(ctx)
            } else {
                // Fallback on earlier versions
            }
            
#endif
            
            url.stopAccessingSecurityScopedResource()
        case .none:
            break
        default:
            break
        }
    }

    private var viewport: SplatRenderer.ViewportDescriptor {
        let projectionMatrix = matrix_perspective_right_hand(fovyRadians: Float(Constants.fovy.radians),
                                                             aspectRatio: Float(drawableSize.width / drawableSize.height),
                                                             nearZ: 0.1,
                                                             farZ: 100.0)

        let rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians) + .pi,
                                                axis: Constants.rotationAxis)
        let translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        let viewport = MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1)

        return SplatRenderer.ViewportDescriptor(viewport: viewport,
                                               projectionMatrix: projectionMatrix,
                                               viewMatrix: translationMatrix * rotationMatrix * commonUpCalibration,
                                               screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height)))
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)
    }

    func draw(in view: MTKView) {
        //return
        guard let modelRenderer else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }

        updateRotation()

        do {
            try modelRenderer.render(viewports: [viewport],
                                     colorTexture: view.multisampleColorTexture ?? drawable.texture,
                                     colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                                     depthTexture: view.depthStencilTexture,
                                     rasterizationRateMap: nil,
                                     renderTargetArrayLength: 0,
                                     to: commandBuffer)
        } catch {
            Self.log.error("Unable to render scene: \(error.localizedDescription)")
        }

        commandBuffer.present(drawable)

        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }
}

#endif // os(iOS) || os(macOS)
