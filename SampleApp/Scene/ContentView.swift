import SwiftUI
import RealityKit
import UniformTypeIdentifiers
import QuickLook

struct ContentView: View {
    @State private var isPickingFile = false

#if targetEnvironment(macCatalyst)
    @Environment(\.openWindow) private var openWindow
#elseif os(macOS)
    @Environment(\.openWindow) private var openWindow
#elseif os(iOS)
    @State private var navigationPath = NavigationPath()

    private func openWindow(value: ModelIdentifier) {
        navigationPath.append(value)
    }
#elseif os(visionOS)
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    @State var immersiveSpaceIsShown = false

    private func openWindow(value: ModelIdentifier) {
        Task {
            switch await openImmersiveSpace(value: value) {
            case .opened:
                immersiveSpaceIsShown = true
            case .error, .userCancelled:
                immersiveSpaceIsShown = false
                break
            @unknown default:
                break
            }
        }
    }
#endif

    private let fileURL = Bundle.main.url(forResource: "test", withExtension: "splat")
    private let thumbnailSize: CGSize = .init(width: 256, height: 256)
    @Environment(\.displayScale) private var scale
    
    @State private var url: URL? = nil
    @State private var thumbnail: Image? = nil

    var body: some View {
#if os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        mainView
#elseif os(iOS)
        NavigationStack(path: $navigationPath) {
            mainView
                .navigationDestination(for: ModelIdentifier.self) { modelIdentifier in
                    MetalKitSceneView(modelIdentifier: modelIdentifier)
                        .navigationTitle(modelIdentifier.description)
                }
        }
#endif // os(iOS)
    }
    
    // create the best possible thumbnail
    private func generateBestThumbnail(fileURL: URL, size: CGSize, scale: CGFloat) async throws -> Image {
        let request = QLThumbnailGenerator.Request(fileAt: fileURL, size: size, scale: scale, representationTypes: .thumbnail)
        let representation: QLThumbnailRepresentation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        print("Got thumbnail?")
        return Image(uiImage: representation.uiImage)
    }
    
    
    // to create a file icon or low-quality thumbnail quickly,
    // and replace it with a higher quality thumbnail once it's available.
    private func generateThumbnails(fileURL: URL, size: CGSize, scale: CGFloat) {
        let request = QLThumbnailGenerator.Request(fileAt: fileURL, size: size, scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateRepresentations(for: request, update: { representation, type, error in
            if let representation {
                self.thumbnail = Image(uiImage: representation.uiImage)
            }
        })
    }

    @ViewBuilder
    var mainView: some View {
        VStack {
            Text("MetalSplatterPlus")
            .font(.system(size: 20, weight: .bold))

            HStack {
                Button("Open File") {
                    isPickingFile = true
                }
                .padding()
                .buttonStyle(.borderedProminent)
                .disabled(isPickingFile)
    #if os(visionOS)
                .disabled(immersiveSpaceIsShown)
    #endif
                .fileImporter(isPresented: $isPickingFile,
                              allowedContentTypes: [
                                UTType(filenameExtension: "ply")!,
                                UTType(filenameExtension: "plysplat")!,
                                UTType(filenameExtension: "splat")!,
                              ]) {
                    isPickingFile = false
                    switch $0 {
                    case .success(let url):
                        /*_ = url.startAccessingSecurityScopedResource()
                        Task {
                            // This is a sample app. In a real app, this should be more tightly scoped, not using a silly timer.
                            try await Task.sleep(for: .seconds(10))
                            url.stopAccessingSecurityScopedResource()
                        }*/
                        
                        if let type = UTType(filenameExtension: "ply") {
                            print(type.identifier)
                        }
                        if let type = UTType(filenameExtension: "plysplat") {
                            print(type.identifier)
                        }
                        if let type = UTType(filenameExtension: "splat") {
                            print(type.identifier)
                        }
                        
                        openWindow(value: ModelIdentifier.gaussianSplat(url))
                    case .failure:
                        break
                    }
                }
                
#if os(visionOS)
                Button("Dismiss Immersive Space") {
                    Task {
                        await dismissImmersiveSpace()
                        immersiveSpaceIsShown = false
                    }
                }
                .disabled(!immersiveSpaceIsShown)
#endif // os(visionOS)
            }
            
            // Thumbnail and QuickLook testing
#if false
            Button(action: {
                self.url = fileURL
            }, label: {
                if let thumbnail {
                    thumbnail
                        .resizable()
                        .scaledToFit()
                        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                } else {
                    Text("Preview")
                }
            })
            .quickLookPreview($url)
            .task {
                guard let url = self.fileURL else {
                    return
                }
                self.thumbnail = try? await self.generateBestThumbnail(fileURL: url, size: self.thumbnailSize, scale: self.scale)
                
                // for creating a file icon or low-quality thumbnail quickly, and replacing it with a higher quality thumbnail once it's available, uncomment the following
                // generateThumbnails(fileURL: url, size: self.thumbnailSize, scale: self.scale)
            }
#endif

#if false
            Spacer()

            Button("Show Sample Box") {
                openWindow(value: ModelIdentifier.sampleBox)
            }
            .padding()
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

            Spacer()
#endif
        }
        .frame(minWidth: 650, maxWidth: 650)
#if os(visionOS)
        .glassBackgroundEffect()
#endif
    }
        
}
