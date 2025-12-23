#if os(visionOS)
import CompositorServices
import UIKit
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

// Define the type alias for the function signature
typealias OpenSplatWindowActionType = (ModelIdentifier) -> Void

struct OpenSplatWindowActionKey: EnvironmentKey {
    static var defaultValue: OpenSplatWindowActionType = { _ in
        print("Default window open")
    }
}

extension EnvironmentValues {
    var openSplatWindow: OpenSplatWindowActionType {
        get { self[OpenSplatWindowActionKey.self] }
        set { self[OpenSplatWindowActionKey.self] = newValue }
    }
}

@main
struct MetalSplatterPlusApp: App {

    static var immersiveSpaceIsReallyShown = false
    @State var immersiveSpaceIsShown = false
    @State var immersiveSpaceIsAppeared = false

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
    @Environment(\.scenePhase) private var scenePhase

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

    var body: some Scene {
        WindowGroup("MetalSplatterPro", id: "main") {
            ContentView(immersiveSpaceIsShown: immersiveSpaceIsShown)
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
#if os(visionOS)
        .environment(\.openSplatWindow, openWindow)
#endif
#if os(macOS) || os(visionOS)
        .windowStyle(.plain)
#endif
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
                    renderer.startRenderLoop() {
                        immersiveSpaceIsAppeared = false
                        immersiveSpaceIsShown = false
                        
                        DataStorage.saveDB()
                    }
                }
            }
            .onAppear() {
                print("Immersive space appeared")
                immersiveSpaceIsAppeared = true
                immersiveSpaceIsShown = true
            }
            .onDisappear() {
                print("Immersive space disappeared")
                immersiveSpaceIsAppeared = false
                immersiveSpaceIsShown = false
            }
            .onChange(of: scenePhase) {
                switch scenePhase {
                case .background:
                    print("Layer is backgrounded")
                    break
                case .inactive:
                    print("Layer is inactive")
                    break
                case .active:
                    print("Layer is active")
                    break
                @unknown default:
                    break
                }
            }
        }
        .immersionStyle(selection: .constant(immersionStyle), in: immersionStyle)
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background:
                print("Scene is backgrounded")
                
                DataStorage.saveDB()
                break
            case .inactive:
                print("Scene is inactive")
                immersiveSpaceIsShown = false
                DataStorage.saveDB()
                break
            case .active:
                print("Scene is active")
                if immersiveSpaceIsAppeared {
                    immersiveSpaceIsShown = true
                }
                break
            @unknown default:
                break
            }
        }
        .onChange(of: MetalSplatterPlusApp.immersiveSpaceIsReallyShown) {
            print("immersiveSpaceIsReallyShown changed", MetalSplatterPlusApp.immersiveSpaceIsReallyShown)
            immersiveSpaceIsShown = MetalSplatterPlusApp.immersiveSpaceIsReallyShown
        }
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

