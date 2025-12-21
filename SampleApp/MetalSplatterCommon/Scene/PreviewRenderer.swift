import QuickLookThumbnailing
import Metal
import MetalKit
import UniformTypeIdentifiers
import MetalSplatter
import Spatial
import Foundation
import simd
//import MetalSplatterCommon

public func renderSplatPreview(device: MTLDevice, commandQueue: MTLCommandQueue, modelRenderer: SplatRenderer?, ctx: CGContext) -> Bool {
    autoreleasepool {
    let size = CGSize(width: ctx.width, height: ctx.height)

    // --- 1. Create offscreen color & depth textures ---
    let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm_srgb,
        width: Int(size.width),
        height: Int(size.height),
        mipmapped: false
    )
    colorDesc.usage = [.renderTarget, .shaderRead]
    colorDesc.storageMode = .shared
    guard let colorTexture = device.makeTexture(descriptor: colorDesc) else {
        return false
    }

    /*let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .depth32Float,
        width: Int(size.width),
        height: Int(size.height),
        mipmapped: false
    )
    depthDesc.usage = [.renderTarget, .shaderRead]
    depthDesc.storageMode = .private
    guard let depthTexture = device.makeTexture(descriptor: depthDesc) else {
        return false
    }*/

    // --- 2. Prepare viewport / render pass descriptor ---
    let viewport = MTLViewport(originX: 0, originY: 0,
                               width: Double(size.width),
                               height: Double(size.height),
                               znear: 0, zfar: 1)
    
    let translationMatrix = matrix4x4_translation(0.0, 0.0, -1.0)
    // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
    // happens to be a useful default for the most common datasets at the moment.
    let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

    let simdDeviceAnchor = matrix_identity_float4x4
    
    let rotationMatrix = matrix4x4_rotation(radians: .pi,
                                            axis: Constants.rotationAxis)

    let projectionMatrix = matrix_perspective_right_hand(fovyRadians: Float(0.5), // 65deg
                                                 aspectRatio: Float(1.0),
                                                 nearZ: 0.1,
                                                 farZ: 100.0)
                                                 
    let screenSize = SIMD2(x: Int(viewport.width),
                               y: Int(viewport.height))

    let modelViewport = SplatRenderer.ViewportDescriptor(viewport: viewport,
                                       projectionMatrix: .init(projectionMatrix),
                                       viewMatrix: translationMatrix * rotationMatrix * commonUpCalibration,
                                       screenSize: screenSize)

    
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        return false
    }

    // --- 3. Call your existing modelRenderer ---
    do {
        modelRenderer?.highQualityDepth = false
        modelRenderer?.forceSynchronousSorting = true
        try? modelRenderer?.render(
            viewports: [modelViewport],
            colorTexture: colorTexture,
            colorStoreAction: .store,
            depthTexture: nil,
            rasterizationRateMap: nil,
            renderTargetArrayLength: 1,
            to: commandBuffer
        )
    }
    catch {
        
    }

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    
    

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
    colorTexture.setPurgeableState(.volatile)
    //depthTexture.setPurgeableState(.volatile)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let bitmapCtx = CGContext(data: pixelData,
                                    width: Int(size.width),
                                    height: Int(size.height),
                                    bitsPerComponent: 8,
                                    bytesPerRow: bytesPerRow,
                                    space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }

    // Draw the Metal bitmap into the Quick Look CGContext
    ctx.draw(bitmapCtx.makeImage()!, in: CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
    return true
    }
}
