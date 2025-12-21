#if os(visionOS)
import CompositorServices
#endif
import SwiftUI

struct TransferItem: Transferable, Equatable, Sendable {
    
    public var url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .item) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            /*@Dependency(\.fileClient) var fileClient
            let temporaryFolder = fileClient.temporaryReplacementDirectory(received.file)
            let temporaryURL = temporaryFolder.appendingPathComponent(received.file.lastPathComponent)
            let url = try fileClient.copyItemToUniqueURL(at: received.file, to: temporaryURL)
            return Self(url)*/
            
            return Self(url: received.file)
        }
    }
}

@main
struct MetalSplatterPlusApp: App {

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
                break
            @unknown default:
                break
            }
        }
    }
#endif

    var body: some Scene {
        WindowGroup("MetalSplatterPlus", id: "main") {
            ContentView()
            .onOpenURL { url in
                print("OPEN URL:", url)
                openWindow(value: ModelIdentifier.gaussianSplat(url))
            }
            .dropDestination(for: URL.self) { urls, location in
                print("DROP:", urls)
                for url in urls {
                    openWindow(value: ModelIdentifier.gaussianSplat(url))
                    return true
                }
                return true
            }
            .dropDestination(for: TransferItem.self) { items, _ in
                print("DROP:", items)
                let urls = items.map(\.url)
                for url in urls {
                    openWindow(value: ModelIdentifier.gaussianSplat(url))
                    return true
                }
                return true
            }
        }
        .handlesExternalEvents(
            matching: ["*"]
        )
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        
        /*DocumentGroup(
            newDocument: SplatDocument()
        ) { file in
            ContentView()
                .task {
                    if let url = file.document.url {
                        openWindow(value: ModelIdentifier.gaussianSplat(url))
                    }
                }
            
        }*/

#if os(macOS) || targetEnvironment(macCatalyst)
        WindowGroup(for: ModelIdentifier.self) { modelIdentifier in
            MetalKitSceneView(modelIdentifier: modelIdentifier.wrappedValue)
                .navigationTitle(modelIdentifier.wrappedValue?.description ?? "No Model")
        }
#endif // os(macOS)

#if os(visionOS)
        ImmersiveSpace(for: ModelIdentifier.self) { modelIdentifier in
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = VisionSceneRenderer(layerRenderer)
                Task {
                    do {
                        try await renderer.load(modelIdentifier.wrappedValue)
                    } catch {
                        print("Error loading model: \(error.localizedDescription)")
                    }
                    renderer.startRenderLoop()
                }
            }
        }
        .immersionStyle(selection: .constant(immersionStyle), in: immersionStyle)
#endif // os(visionOS)
    }

#if os(visionOS)
    var immersionStyle: ImmersionStyle {
        if #available(visionOS 2, *) {
            .mixed
        } else {
            .full
        }
    }
#endif // os(visionOS)
}

