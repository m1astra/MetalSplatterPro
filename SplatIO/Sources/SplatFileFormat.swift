import Foundation

public enum SplatFileFormat {
    case ply
    case dotSplat

    public init?(for url: URL) {
        switch url.pathExtension.lowercased() {
        case "ply": self = .ply
        case "plysplat": self = .ply
        case "plyp": self = .ply
        case "splat": self = .dotSplat
        default: return nil
        }
    }
}
