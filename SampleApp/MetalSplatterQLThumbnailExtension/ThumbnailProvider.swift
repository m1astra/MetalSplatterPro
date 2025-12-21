import QuickLookThumbnailing
import Metal
import MetalKit
import UniformTypeIdentifiers
import MetalSplatter
import Spatial
import Foundation
import simd
import MetalSplatterCommon

@objc(ThumbnailProvider)
class ThumbnailProvider: QLThumbnailProvider {

    // Metal device & queue can be created once per provider instance
    lazy var device: MTLDevice = MTLCreateSystemDefaultDevice()!
    lazy var commandQueue: MTLCommandQueue = device.makeCommandQueue()!
    
    let thumbnailQueue = DispatchQueue(label: "qlthumb.queue")

    private var oneAtATimeLock = NSObject()

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        
        NSLog("Providing thumbnail for " +  request.fileURL.description)
        
#if false
        let size = CGSize(width: request.maximumSize.width, height: request.maximumSize.height)
        let reply = QLThumbnailReply(contextSize: size) { ctx in
            // Draw your thumbnail using `data` (synchronously)
            // e.g., Metal render, CG draw, etc.
            ctx.setFillColor(CGColor.init(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0))
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
            return true
        }
        handler(reply, nil)
        return
#endif
        
#if true
        thumbnailQueue.sync {
        Task.immediate {
            //objc_sync_enter(oneAtATimeLock)
            
            var numPoints = 0
            var renderedPoints = 0
            
            var size = request.maximumSize
            let url = request.fileURL
            
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            
            print("Generating thumbnail for:", url)
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

            guard let ctx = CGContext(
                data: nil,
                width: 256,
                height: 256,
                bitsPerComponent: 8,
                bytesPerRow: 0, // 0 means Core Graphics calculates the bytes per row
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return
            }
            
            guard let ctxtmp = CGContext(
                data: nil,
                width: 256,
                height: 256,
                bitsPerComponent: 8,
                bytesPerRow: 0, // 0 means Core Graphics calculates the bytes per row
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return
            }

            ctx.setFillColor(CGColor.init(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0))
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
            
            var modelRenderer: SplatRenderer? = nil
            do {
                let splat = try SplatRenderer(device: device,
                                              colorFormat: .rgba8Unorm_srgb,
                                              depthFormat: .invalid,
                                              sampleCount: 1,
                                              maxViewCount: 1,
                                              maxSimultaneousRenders: 3)
                modelRenderer = splat
            }
            catch {
                print("Failed to init SplatRenderer?")
                let reply = QLThumbnailReply(contextSize: size) { ctx in
                    return false
                }

                handler(reply, nil)
                return
            }
            
            // HACK: We have to render in parts for thumbnailing due to memory limits
            while true {
                print("Next loop", renderedPoints, numPoints)
                
                
                do {
                    modelRenderer?.reset()

#if !(os(macOS) || targetEnvironment(macCatalyst))
                    modelRenderer?.forceMaximumNumPoints = 150000
#else
                    modelRenderer?.forceMaximumNumPoints = 500000
#endif
                    modelRenderer?.forceSkipNumPoints = renderedPoints
                    try await modelRenderer?.read(from: url)
                    if numPoints <= 0 {
                        numPoints = modelRenderer?.numPoints ?? 0
                    }
                    renderedPoints += modelRenderer?.renderingPoints ?? 0
                }
                catch {
                    print("Failed to read splats?")
                    let reply = QLThumbnailReply(contextSize: size) { ctx in
                        return false
                    }

                    handler(reply, nil)
                    return
                }
                print("Rendering to idx", renderedPoints, "of", numPoints)
                
                ctxtmp.setFillColor(CGColor.init(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0))
                ctxtmp.fill(CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
                
                let res = renderSplatPreview(device: self.device, commandQueue: self.commandQueue, modelRenderer: modelRenderer, ctx: ctxtmp)
                if !res {
                    print("Failed somewhere in renderSplatPreview")
                    let reply = QLThumbnailReply(contextSize: size) { ctx in
                        return false
                    }

                    handler(reply, nil)
                    return
                }
                ctx.draw(ctxtmp.makeImage()!, in: CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
                
                if renderedPoints >= numPoints {
                    break
                }
            }

            let drawing: (CGContext) -> Bool = { (tctx: CGContext) in
                tctx.setFillColor(CGColor.init(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0))
                tctx.fill(CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
                
                tctx.draw(ctx.makeImage()!, in: CGRect(origin: .zero, size: CGSize(width: tctx.width, height: tctx.height)))
                
                print("Releasing lock")
                //objc_sync_exit(self.oneAtATimeLock)
                return true
            }
            
            let reply = QLThumbnailReply(contextSize: size, drawing: drawing)

            handler(reply, nil)
            
#if false
            //let size = CGSize(width: request.maximumSize.width, height: request.maximumSize.height)
            let reply = QLThumbnailReply(contextSize: size) { ctx in
                // Draw your thumbnail using `data` (synchronously)
                // e.g., Metal render, CG draw, etc.
                ctx.setFillColor(CGColor.init(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0))
                ctx.fill(CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
                return true
            }
            handler(reply, nil)
            return
#endif
        }
        }
#endif
    }
}
