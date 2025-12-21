import Foundation

public class AutodetectSceneReader: SplatSceneReader {
    public enum Error: Swift.Error {
        case cannotDetermineFormat
        case cannotOpenSource(URL)
    }

    private let reader: SplatSceneReader

    public init(_ url: URL) throws {
    
        // TODO: Maybe remove the enum junk and just read headers
        guard let inputStream = InputStream(url: url) else {
            throw Error.cannotOpenSource(url)
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { buffer.deallocate() }
        
        inputStream.open()
        let readResult = inputStream.read(buffer, maxLength: 4)
        inputStream.close()
        
        switch readResult {
            case 4:
                if buffer[0] == 0x70 && buffer[1] == 0x6C && buffer[2] == 0x79 {
                    reader = try SplatPLYSceneReader(url)
                    return
                }
                break
            default:
                break
        }
    
        switch SplatFileFormat(for: url) {
        case .ply: reader = try SplatPLYSceneReader(url)
        case .dotSplat: reader = try DotSplatSceneReader(url)
        case .none: throw Error.cannotDetermineFormat
        }
    }

    public func read(to delegate: any SplatSceneReaderDelegate) {
        reader.read(to: delegate)
    }
}
