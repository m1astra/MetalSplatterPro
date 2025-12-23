import SwiftUI
import RealityKit
import UniformTypeIdentifiers
import QuickLook

struct ContentView: View {
    @State private var isPickingFile = false
    @State private var isPickingImage = false
    @State private var generationState: GenerationState = .idle
    @State private var generator = SplatGenerator()
    @State private var generationStart: Date?
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var generatedURLToSave: URL?
    @State private var isTransitioningToImmersive = false
    
    private let showElapsedTime = false
    
    let immersiveSpaceIsShown: Bool

#if targetEnvironment(macCatalyst)
    @Environment(\.openWindow) private var openWindow
#elseif os(macOS)
    @Environment(\.openWindow) private var openWindow: (ModelIdentifier) -> Void
#elseif os(iOS)
    @State private var navigationPath = NavigationPath()

    private func openWindow(_ value: ModelIdentifier) {
        navigationPath.append(value)
    }
#elseif os(visionOS)
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace
    @Environment(\.openSplatWindow) var openWindow: (ModelIdentifier) -> Void
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
#endif
    }
    
    private func generateBestThumbnail(fileURL: URL, size: CGSize, scale: CGFloat) async throws -> Image {
        let request = QLThumbnailGenerator.Request(fileAt: fileURL, size: size, scale: scale, representationTypes: .thumbnail)
        let representation: QLThumbnailRepresentation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return Image(uiImage: representation.uiImage)
    }
    
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
        VStack(spacing: 16) {
            Text("MetalSplatterPro")
                .font(.system(size: 22, weight: .bold))

#if os(visionOS)
            if immersiveSpaceIsShown || isTransitioningToImmersive {
                HStack(spacing: 16) {
                    Button("Exit") {
                        isTransitioningToImmersive = false
                        Task { await dismissImmersiveSpace() }
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Reset") {
                        VisionSceneRenderer.handRotationMat = matrix_identity_float4x4
                        VisionSceneRenderer.handTranslationMat = matrix_identity_float4x4
                        VisionSceneRenderer.handScaleMat = matrix_identity_float4x4
                    }
                    .buttonStyle(.bordered)
                    
                    if let url = generatedURLToSave {
                        Button("Save") {
                            exportURL = url
                            isExporting = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                HStack(spacing: 16) {
                    Button("Open File") {
                        isPickingFile = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPickingFile || generationState.isActive)
                    .fileImporter(isPresented: $isPickingFile,
                                  allowedContentTypes: [
                                    UTType(filenameExtension: "ply")!,
                                    UTType(filenameExtension: "plysplat")!,
                                    UTType(filenameExtension: "splat")!,
                                  ]) {
                        isPickingFile = false
                        switch $0 {
                        case .success(let url):
                            generatedURLToSave = nil
                            openWindow(ModelIdentifier.gaussianSplat(url))
                        case .failure:
                            break
                        }
                    }
                    
                    Button("Generate") {
                        isPickingImage = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPickingImage || generationState.isActive)
                    .fileImporter(isPresented: $isPickingImage,
                                  allowedContentTypes: [.image, .jpeg, .png, .heic]) {
                        isPickingImage = false
                        switch $0 {
                        case .success(let imageURL):
                            Task {
                                await handleImageGeneration(imageURL)
                            }
                        case .failure:
                            break
                        }
                    }
                }
            }
#else
            HStack(spacing: 16) {
                Button("Open File") {
                    isPickingFile = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPickingFile || generationState.isActive)
                .fileImporter(isPresented: $isPickingFile,
                              allowedContentTypes: [
                                UTType(filenameExtension: "ply")!,
                                UTType(filenameExtension: "plysplat")!,
                                UTType(filenameExtension: "splat")!,
                              ]) {
                    isPickingFile = false
                    switch $0 {
                    case .success(let url):
                        generatedURLToSave = nil
                        openWindow(value: ModelIdentifier.gaussianSplat(url))
                    case .failure:
                        break
                    }
                }
                
                Button("Generate") {
                    isPickingImage = true
                }
                .buttonStyle(.bordered)
                .disabled(isPickingImage || generationState.isActive)
                .fileImporter(isPresented: $isPickingImage,
                              allowedContentTypes: [.image, .jpeg, .png, .heic]) {
                    isPickingImage = false
                    switch $0 {
                    case .success(let imageURL):
                        Task {
                            await handleImageGeneration(imageURL)
                        }
                    case .failure:
                        break
                    }
                }
            }
#endif
        }
        .padding()
#if os(visionOS)
        .glassBackgroundEffect()
#endif
        .sheet(isPresented: Binding(
            get: { generationState != .idle },
            set: { if !$0 { generationState = .idle; generationStart = nil } }
        )) {
            generationSheet
        }
        .fileExporter(
            isPresented: $isExporting,
            document: PLYDocument(url: exportURL),
            contentType: UTType(filenameExtension: "ply")!,
            defaultFilename: exportURL?.lastPathComponent ?? "splat.ply"
        ) { result in
            switch result {
            case .success: break
            case .failure: break
            }
        }
    }
    
    // MARK: - Generation Sheet
    
    @ViewBuilder
    var generationSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if case .loadingModel = generationState {
                    ProgressView()
                        .scaleEffect(1.3)
                        .padding(.bottom, 12)
                    Text("Loading AI Model...")
                        .font(.title2.weight(.semibold))
                    if showElapsedTime, let start = generationStart {
                        TimelineView(.periodic(from: start, by: 1)) { _ in
                            Text(formatElapsed(Date().timeIntervalSince(start)))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if case .processing = generationState {
                    ProgressView()
                        .scaleEffect(1.3)
                        .padding(.bottom, 12)
                    Text("Generating...")
                        .font(.title2.weight(.semibold))
                    if showElapsedTime, let start = generationStart {
                        TimelineView(.periodic(from: start, by: 1)) { _ in
                            Text(formatElapsed(Date().timeIntervalSince(start)))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if case .complete(let url) = generationState {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                        .padding(.bottom, 0)
                    Text("Complete")
                        .font(.title2.weight(.semibold))
                    if showElapsedTime, let start = generationStart {
                        Text(formatElapsed(Date().timeIntervalSince(start)))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        Button("View") {
                            generatedURLToSave = url
                            isTransitioningToImmersive = true
                            generationState = .idle
                            generationStart = nil
#if os(visionOS)
                            openWindow(ModelIdentifier.gaussianSplat(url))
#else
                            openWindow(value: ModelIdentifier.gaussianSplat(url))
#endif
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Save") {
                            exportURL = url
                            isExporting = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 0)
                } else if case .error(let message) = generationState {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.red)
                        .padding(.bottom, 8)
                    Text("Failed")
                        .font(.title2.weight(.semibold))
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        generationState = .idle
                        generationStart = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 19, weight: .bold))
                    }
                    .buttonBorderShape(.circle)
                }
            }
        }
        .frame(width: 360, height: 330)
    }
    
    // MARK: - Generation Logic
    
    private func handleImageGeneration(_ imageURL: URL) async {
        generationStart = Date()
        generationState = .loadingModel
        generatedURLToSave = nil
        
        do {
            try await generator.loadModelIfNeeded()
            generationState = .processing
            
            let didAccess = imageURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess { imageURL.stopAccessingSecurityScopedResource() }
            }
            let outputURL = try await generator.generate(from: imageURL)
            generationState = .complete(outputURL)
        } catch {
            generationState = .error(error.localizedDescription)
        }
    }
    
    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return "\(m)m \(String(format: "%02d", s))s"
    }
}

// MARK: - Generation State

enum GenerationState: Equatable {
    case idle
    case loadingModel
    case processing
    case complete(URL)
    case error(String)
    
    var isActive: Bool {
        switch self {
        case .loadingModel, .processing: return true
        default: return false
        }
    }
}

struct PLYDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "ply")!] }
    static var writableContentTypes: [UTType] { [UTType(filenameExtension: "ply")!] }
    
    var data: Data
    
    init(url: URL?) {
        if let url, let fileData = try? Data(contentsOf: url) {
            self.data = fileData
        } else {
            self.data = Data()
        }
    }
    
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
