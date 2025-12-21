//
//  PreviewProvider.swift
//  MetalSplatterPreviewExtension
//
//  Created by Max Thomas on 12/20/25.
//

import QuickLook
import Metal
import MetalKit
import UniformTypeIdentifiers
import MetalSplatter
import Spatial
import Foundation
import simd
import MetalSplatterCommon

@objc(PreviewProvider)
class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    

    /*
     Use a QLPreviewProvider to provide data-based previews.
     
     To set up your extension as a data-based preview extension:

     - Modify the extension's Info.plist by setting
       <key>QLIsDataBasedPreview</key>
       <true/>
     
     - Add the supported content types to QLSupportedContentTypes array in the extension's Info.plist.

     - Remove
       <key>NSExtensionMainStoryboard</key>
       <string>MainInterface</string>
     
       and replace it by setting the NSExtensionPrincipalClass to this class, e.g.
       <key>NSExtensionPrincipalClass</key>
       <string>$(PRODUCT_MODULE_NAME).PreviewProvider</string>
     
     - Implement providePreview(for:)
     */
     
    lazy var device: MTLDevice = MTLCreateSystemDefaultDevice()!
    lazy var commandQueue: MTLCommandQueue = device.makeCommandQueue()!
    
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
    
        //You can create a QLPreviewReply in several ways, depending on the format of the data you want to return.
        //To return Data of a supported content type:
        
        NSLog("Providing preview for " +  request.fileURL.description)
#if false
        let reply = QLPreviewReply.init(dataOfContentType: .plainText, contentSize: CGSize.init(width: 800, height: 800)) { (replyToUpdate : QLPreviewReply) in
            let data = Data("Failed to read splat file".utf8)
            replyToUpdate.stringEncoding = .utf8
            return data
        }
        return reply
#endif
        
#if true
        let size = CGSize(width: 256, height: 256)
        let url = request.fileURL
        
        _ = url.startAccessingSecurityScopedResource()
        print("Trying to preview:", url)
        var modelRenderer: SplatRenderer? = nil
        do {
            let splat = try SplatRenderer(device: device,
                                      colorFormat: .rgba8Unorm_srgb,
                                      depthFormat: .depth32Float,
                                      sampleCount: 1,
                                      maxViewCount: 1,
                                      maxSimultaneousRenders: 1)
            try await splat.read(from: url)
            modelRenderer = splat
        }
        catch {
            let reply = QLPreviewReply.init(dataOfContentType: .plainText, contentSize: CGSize.init(width: 800, height: 800)) { (replyToUpdate : QLPreviewReply) in
                let data = Data("Failed to read splat file".utf8)
                replyToUpdate.stringEncoding = .utf8
                return data
            }
            return reply
        }
        url.stopAccessingSecurityScopedResource()

        let drawing: (CGContext, QLPreviewReply) throws -> Void = { (ctx: CGContext, reply: QLPreviewReply) in
            renderSplatPreview(device: self.device, commandQueue: self.commandQueue, modelRenderer: modelRenderer, ctx: ctx)
        }
        
        let reply = QLPreviewReply.init(contextSize: CGSize.init(width: 800, height: 800), isBitmap: true, drawUsing: drawing)
                
        return reply
#endif
    }

}
