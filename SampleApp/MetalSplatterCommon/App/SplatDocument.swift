import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import UniformTypeIdentifiers

public struct SplatDocument: FileDocument {
    public static var readableContentTypes: [UTType] = [
        UTType(exportedAs: "dev.maxthomas.metalsplatterplus.splat"),
        UTType(exportedAs: "dev.maxthomas.metalsplatterplus.plysplat"),
        UTType(exportedAs: "public.polygon-file-format")
    ]

    var url: URL?

    public init() {}

    public init(configuration: ReadConfiguration) throws {
        url = configuration.file.symbolicLinkDestinationURL
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
