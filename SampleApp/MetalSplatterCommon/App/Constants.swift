import Foundation
import SwiftUI

public enum Constants {
    public static let maxSimultaneousRenders = 3
    public static let rotationPerSecond = Angle(degrees: 0)
    public static let rotationAxis = SIMD3<Float>(0, 1, 0)
#if !os(visionOS)
    public static let fovy = Angle(degrees: 65)
#endif
    public static let modelCenterZ: Float = 0.0
}

