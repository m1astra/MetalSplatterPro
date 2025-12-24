import Foundation
import CoreML
import UIKit
import ImageIO
import CoreImage
import simd

#if targetEnvironment(simulator)
private let useMockInference = true
#else
private let useMockInference = false
#endif

@MainActor
@Observable
class SplatGenerator {
    private var model: MLModel?
    
    var isModelLoaded: Bool { model != nil || useMockInference }
    
    func loadModelIfNeeded() async throws {
        if useMockInference {
            try await Task.sleep(for: .seconds(1))
            return
        }
        
        guard model == nil else { return }
        
        guard let modelURL = Bundle.main.url(forResource: "sharp", withExtension: "mlmodelc") else {
            throw GeneratorError.modelNotFound
        }
        
        model = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let config = MLModelConfiguration()
                    #if targetEnvironment(simulator)
                    config.computeUnits = .cpuOnly
                    #else
                    config.computeUnits = .cpuAndGPU
                    #endif

                    if #available(iOS 16.0, macOS 13.0, visionOS 1.0, *) {
                        config.allowLowPrecisionAccumulationOnGPU = false
                    }
                    
                    let loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
                    continuation.resume(returning: loadedModel)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func generate(from imageURL: URL) async throws -> URL {
        if useMockInference {
            return try await generateMock(baseName: imageURL.deletingPathExtension().lastPathComponent)
        }
        
        guard let model else { throw GeneratorError.modelNotLoaded }
        
        return try await withCheckedThrowingContinuation { continuation in
            let capturedModel = model
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let targetSize = try self.modelImageInputSize(model: capturedModel)
                    let (imageData, focalLengthPx, originalWidth, originalHeight) = try self.preprocessImage(imageURL, targetSize: targetSize)
                    let outputs = try self.runInferenceSync(model: capturedModel, imageData: imageData, focalLengthPx: focalLengthPx, originalWidth: originalWidth)
                    let worldGaussians = self.unproject(outputs, focalLengthPx: focalLengthPx, originalWidth: originalWidth, originalHeight: originalHeight)
                    let outputURL = try self.savePLY(worldGaussians, baseName: imageURL.deletingPathExtension().lastPathComponent)
                    continuation.resume(returning: outputURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func generateMock(baseName: String) async throws -> URL {
        try await Task.sleep(for: .seconds(2))
        
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var outputURL = documentsDir.appendingPathComponent("\(baseName).ply")
        
        var counter = 1
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = documentsDir.appendingPathComponent("\(baseName)_\(counter).ply")
            counter += 1
        }
        
        let numPoints = 100
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(numPoints)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property float f_dc_0\nproperty float f_dc_1\nproperty float f_dc_2\n"
        header += "property float opacity\n"
        header += "property float scale_0\nproperty float scale_1\nproperty float scale_2\n"
        header += "property float rot_0\nproperty float rot_1\nproperty float rot_2\nproperty float rot_3\n"
        header += "end_header\n"
        
        var data = Data()
        data.append(header.data(using: .utf8)!)
        
        for i in 0..<numPoints {
            let angle = Float(i) / Float(numPoints) * 2 * .pi
            let radius: Float = 0.3
            withUnsafeBytes(of: cos(angle) * radius) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: sin(angle) * radius) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(0)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(0.5)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(0.2)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(0.8)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(1.0)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(-5.0)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(-5.0)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(-5.0)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(1)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(0)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(0)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(0)) { data.append(contentsOf: $0) }
        }
        
        try data.write(to: outputURL)
        return outputURL
    }
    
    nonisolated private func modelImageInputSize(model: MLModel) throws -> CGSize {
        guard let desc = model.modelDescription.inputDescriptionsByName["image"] else {
            throw GeneratorError.modelIncompatible("Missing required input: image")
        }
        guard desc.type == .multiArray, let c = desc.multiArrayConstraint else {
            throw GeneratorError.modelIncompatible("Expected multiArray input for: image")
        }

        let dims = c.shape.map { $0.intValue }
        guard dims.count >= 2 else {
            throw GeneratorError.modelIncompatible("Invalid image input shape: \(dims)")
        }

        let h = dims[dims.count - 2]
        let w = dims[dims.count - 1]
        if h <= 0 || w <= 0 {
            throw GeneratorError.modelIncompatible("Invalid image input shape: \(dims)")
        }

        return CGSize(width: w, height: h)
    }

    nonisolated private func preprocessImage(_ url: URL, targetSize: CGSize) throws -> ([Float], Float, Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GeneratorError.imageLoadFailed
        }

        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? (props[kCGImagePropertyOrientation] as? Int)
            ?? 1

        guard let oriented = applyExifOrientation(cgImage, orientation: orientation) else {
            throw GeneratorError.imageProcessingFailed
        }

        let originalWidth = oriented.width
        let originalHeight = oriented.height
        let focalLengthPx = extractFocalLengthPx(props: props, pixelWidth: originalWidth, pixelHeight: originalHeight)

        let w = max(Int(targetSize.width), 1)
        let h = max(Int(targetSize.height), 1)

        guard let floatData = resampleCGImageToCHWAlignCornersBilinear(oriented, dstW: w, dstH: h) else {
            throw GeneratorError.imageProcessingFailed
        }
        
        return (floatData, focalLengthPx, originalWidth, originalHeight)
    }
    
    nonisolated private func extractFocalLengthPx(props: [CFString: Any], pixelWidth: Int, pixelHeight: Int) -> Float {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]

        func num(_ key: CFString) -> Double? {
            if let n = exif?[key] as? NSNumber { return n.doubleValue }
            if let d = exif?[key] as? Double { return d }
            if let f = exif?[key] as? Float { return Double(f) }
            return nil
        }

        let focal35 =
            num(kCGImagePropertyExifFocalLenIn35mmFilm)
            ?? num("FocalLengthIn35mmFilm" as CFString)
            ?? num("FocalLenIn35mmFilm" as CFString)

        var fMm: Double?
        if let focal35, focal35 >= 1 {
            fMm = focal35
        } else {
            fMm = num(kCGImagePropertyExifFocalLength) ?? num("FocalLength" as CFString)
            if fMm == nil { fMm = 30.0 }
            if let v = fMm, v < 10.0 { fMm = v * 8.4 }
        }

        let w = Double(pixelWidth)
        let h = Double(pixelHeight)
        let diag = (w * w + h * h).squareRoot()
        let sensorDiag = (36.0 * 36.0 + 24.0 * 24.0).squareRoot()
        return Float((fMm ?? 30.0) * diag / sensorDiag)
    }

    nonisolated private func applyExifOrientation(_ image: CGImage, orientation: Int) -> CGImage? {
        if orientation == 1 { return image }

        let ciImage = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let cs = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CIContext(options: [
            CIContextOption.workingColorSpace: cs,
            CIContextOption.outputColorSpace: cs
        ])
        let rect = ciImage.extent.integral
        return ctx.createCGImage(ciImage, from: rect, format: .RGBA8, colorSpace: cs)
    }

    nonisolated private func resampleCGImageToCHWAlignCornersBilinear(_ image: CGImage, dstW: Int, dstH: Int) -> [Float]? {
        let srcW = image.width
        let srcH = image.height
        if srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0 { return nil }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil, width: srcW, height: srcH,
            bitsPerComponent: 8, bytesPerRow: srcW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let data = context.data else { return nil }

        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))

        let src = data.assumingMemoryBound(to: UInt8.self)
        let dstPlane = dstW * dstH
        var dst = [Float](repeating: 0, count: 3 * dstPlane)

        let scaleX: Float = (dstW > 1) ? Float(srcW - 1) / Float(dstW - 1) : 0
        let scaleY: Float = (dstH > 1) ? Float(srcH - 1) / Float(dstH - 1) : 0

        for y in 0..<dstH {
            let fy = Float(y) * scaleY
            let y0 = Int(floor(fy))
            let y1 = min(y0 + 1, srcH - 1)
            let wy = fy - Float(y0)
            let wy0 = 1.0 as Float - wy

            for x in 0..<dstW {
                let fx = Float(x) * scaleX
                let x0 = Int(floor(fx))
                let x1 = min(x0 + 1, srcW - 1)
                let wx = fx - Float(x0)
                let wx0 = 1.0 as Float - wx

                let w00 = wx0 * wy0
                let w01 = wx * wy0
                let w10 = wx0 * wy
                let w11 = wx * wy

                let i00 = (y0 * srcW + x0) * 4
                let i01 = (y0 * srcW + x1) * 4
                let i10 = (y1 * srcW + x0) * 4
                let i11 = (y1 * srcW + x1) * 4

                let r =
                    w00 * Float(src[i00]) +
                    w01 * Float(src[i01]) +
                    w10 * Float(src[i10]) +
                    w11 * Float(src[i11])
                let g =
                    w00 * Float(src[i00 + 1]) +
                    w01 * Float(src[i01 + 1]) +
                    w10 * Float(src[i10 + 1]) +
                    w11 * Float(src[i11 + 1])
                let b =
                    w00 * Float(src[i00 + 2]) +
                    w01 * Float(src[i01 + 2]) +
                    w10 * Float(src[i10 + 2]) +
                    w11 * Float(src[i11 + 2])

                let o = y * dstW + x
                dst[o] = r / 255.0
                dst[dstPlane + o] = g / 255.0
                dst[2 * dstPlane + o] = b / 255.0
            }
        }

        return dst
    }
    
    nonisolated private func runInferenceSync(model: MLModel, imageData: [Float], focalLengthPx: Float, originalWidth: Int) throws -> GaussianOutputs {
        guard let imageDesc = model.modelDescription.inputDescriptionsByName["image"] else {
            throw GeneratorError.modelIncompatible("Missing required input: image")
        }
        guard imageDesc.type == .multiArray, let imageConstraint = imageDesc.multiArrayConstraint else {
            throw GeneratorError.modelIncompatible("Expected multiArray input for: image")
        }

        let imageArray = try MLMultiArray(shape: imageConstraint.shape, dataType: imageConstraint.dataType)
        if imageArray.count != imageData.count {
            throw GeneratorError.modelIncompatible("Image input size mismatch: model expects \(imageArray.count) elements, got \(imageData.count)")
        }

        switch imageConstraint.dataType {
        case .float16:
            let ptr = imageArray.dataPointer.assumingMemoryBound(to: UInt16.self)
            for i in 0..<imageData.count { ptr[i] = float32ToFloat16Bits(imageData[i]) }
        case .float32:
            let ptr = imageArray.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<imageData.count { ptr[i] = imageData[i] }
        case .double:
            let ptr = imageArray.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<imageData.count { ptr[i] = Double(imageData[i]) }
        default:
            throw GeneratorError.modelIncompatible("Unsupported image input dtype: \(imageConstraint.dataType)")
        }
        
        let disparityFactor = focalLengthPx / Float(originalWidth)
        guard let dispDesc = model.modelDescription.inputDescriptionsByName["disparity_factor"] else {
            throw GeneratorError.modelIncompatible("Missing required input: disparity_factor")
        }

        let input: MLDictionaryFeatureProvider
        if dispDesc.type == .multiArray, let dispConstraint = dispDesc.multiArrayConstraint {
            let disparityArray = try MLMultiArray(shape: dispConstraint.shape, dataType: dispConstraint.dataType)
            switch dispConstraint.dataType {
            case .float16:
                let ptr = disparityArray.dataPointer.assumingMemoryBound(to: UInt16.self)
                for i in 0..<disparityArray.count { ptr[i] = float32ToFloat16Bits(disparityFactor) }
            case .float32:
                let ptr = disparityArray.dataPointer.assumingMemoryBound(to: Float32.self)
                for i in 0..<disparityArray.count { ptr[i] = disparityFactor }
            case .double:
                let ptr = disparityArray.dataPointer.assumingMemoryBound(to: Double.self)
                for i in 0..<disparityArray.count { ptr[i] = Double(disparityFactor) }
            default:
                throw GeneratorError.modelIncompatible("Unsupported disparity_factor dtype: \(dispConstraint.dataType)")
            }

            input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(multiArray: imageArray),
                "disparity_factor": MLFeatureValue(multiArray: disparityArray)
            ])
        } else if dispDesc.type == .double {
            input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(multiArray: imageArray),
                "disparity_factor": MLFeatureValue(double: Double(disparityFactor))
            ])
        } else {
            throw GeneratorError.modelIncompatible("Unsupported disparity_factor input type: \(dispDesc.type)")
        }
        
        let options = MLPredictionOptions()
        #if targetEnvironment(simulator)
        options.usesCPUOnly = true
        #endif
        
        let output = try model.prediction(from: input, options: options)
        
        guard let meanVectors = output.featureValue(for: "mean_vectors")?.multiArrayValue,
              let singularValues = output.featureValue(for: "singular_values")?.multiArrayValue,
              let quaternions = output.featureValue(for: "quaternions")?.multiArrayValue,
              let colors = output.featureValue(for: "colors")?.multiArrayValue,
              let opacities = output.featureValue(for: "opacities")?.multiArrayValue else {
            throw GeneratorError.inferenceOutputMissing
        }

        return GaussianOutputs(
            meanVectors: multiArrayToFloatArray(meanVectors),
            singularValues: multiArrayToFloatArray(singularValues),
            quaternions: multiArrayToFloatArray(quaternions),
            colors: multiArrayToFloatArray(colors),
            opacities: multiArrayToFloatArray(opacities)
        )
    }
    
    nonisolated private func unproject(_ ndc: GaussianOutputs, focalLengthPx: Float, originalWidth: Int, originalHeight: Int) -> GaussianOutputs {
        let scaleX = Float(originalWidth) / (2.0 * focalLengthPx)
        let scaleY = Float(originalHeight) / (2.0 * focalLengthPx)
        
        let numGaussians = ndc.meanVectors.count / 3
        var worldMeans = [Float](repeating: 0, count: ndc.meanVectors.count)
        var worldSingularValues = [Float](repeating: 0, count: ndc.singularValues.count)

        let ax = scaleX
        let ay = scaleY
        let az: Float = 1.0

        for i in 0..<numGaussians {
            worldMeans[i * 3] = ndc.meanVectors[i * 3] * ax
            worldMeans[i * 3 + 1] = ndc.meanVectors[i * 3 + 1] * ay
            worldMeans[i * 3 + 2] = ndc.meanVectors[i * 3 + 2]

            let s0 = max(ndc.singularValues[i * 3], 0)
            let s1 = max(ndc.singularValues[i * 3 + 1], 0)
            let s2 = max(ndc.singularValues[i * 3 + 2], 0)
            let s0sq = s0 * s0
            let s1sq = s1 * s1
            let s2sq = s2 * s2

            let qw = ndc.quaternions[i * 4]
            let qx = ndc.quaternions[i * 4 + 1]
            let qy = ndc.quaternions[i * 4 + 2]
            let qz = ndc.quaternions[i * 4 + 3]
            let qIn = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw).normalized

            let R = simd_float3x3(qIn)

            var AR = R
            AR.columns.0 = SIMD3<Float>(R.columns.0.x * ax, R.columns.0.y * ay, R.columns.0.z * az)
            AR.columns.1 = SIMD3<Float>(R.columns.1.x * ax, R.columns.1.y * ay, R.columns.1.z * az)
            AR.columns.2 = SIMD3<Float>(R.columns.2.x * ax, R.columns.2.y * ay, R.columns.2.z * az)

            let M = simd_mul(simd_transpose(R), AR)

            for j in 0..<3 {
                let m0 = M.columns.0[j]
                let m1 = M.columns.1[j]
                let m2 = M.columns.2[j]
                let v = (m0 * m0) * s0sq + (m1 * m1) * s1sq + (m2 * m2) * s2sq
                worldSingularValues[i * 3 + j] = sqrt(max(v, 1e-20))
            }
        }

        return GaussianOutputs(
            meanVectors: worldMeans,
            singularValues: worldSingularValues,
            quaternions: ndc.quaternions,
            colors: ndc.colors,
            opacities: ndc.opacities
        )
    }
    
    nonisolated private func savePLY(_ gaussians: GaussianOutputs, baseName: String) throws -> URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var outputURL = documentsDir.appendingPathComponent("\(baseName).ply")
        
        var counter = 1
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = documentsDir.appendingPathComponent("\(baseName)_\(counter).ply")
            counter += 1
        }
        
        let numPoints = gaussians.meanVectors.count / 3
        
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(numPoints)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property float f_dc_0\nproperty float f_dc_1\nproperty float f_dc_2\n"
        header += "property float opacity\n"
        header += "property float scale_0\nproperty float scale_1\nproperty float scale_2\n"
        header += "property float rot_0\nproperty float rot_1\nproperty float rot_2\nproperty float rot_3\n"
        header += "end_header\n"

        let headerData = header.data(using: .utf8)!
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: outputURL)
        defer { try? fh.close() }

        try fh.write(contentsOf: headerData)

        let flushBytes = 4 * 1024 * 1024
        var buffer = Data()
        buffer.reserveCapacity(flushBytes)

        for i in 0..<numPoints {
            appendFloat(&buffer, gaussians.meanVectors[i * 3])
            appendFloat(&buffer, gaussians.meanVectors[i * 3 + 1])
            appendFloat(&buffer, gaussians.meanVectors[i * 3 + 2])

            let r = gaussians.colors[i * 3], g = gaussians.colors[i * 3 + 1], b = gaussians.colors[i * 3 + 2]
            appendFloat(&buffer, rgbToSH(linearToSRGB(r)))
            appendFloat(&buffer, rgbToSH(linearToSRGB(g)))
            appendFloat(&buffer, rgbToSH(linearToSRGB(b)))

            appendFloat(&buffer, inverseSigmoid(gaussians.opacities[i]))

            appendFloat(&buffer, log(max(gaussians.singularValues[i * 3], 1e-8)))
            appendFloat(&buffer, log(max(gaussians.singularValues[i * 3 + 1], 1e-8)))
            appendFloat(&buffer, log(max(gaussians.singularValues[i * 3 + 2], 1e-8)))

            appendFloat(&buffer, gaussians.quaternions[i * 4])
            appendFloat(&buffer, gaussians.quaternions[i * 4 + 1])
            appendFloat(&buffer, gaussians.quaternions[i * 4 + 2])
            appendFloat(&buffer, gaussians.quaternions[i * 4 + 3])

            if buffer.count >= flushBytes {
                try fh.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            try fh.write(contentsOf: buffer)
        }
        return outputURL
    }
    
    nonisolated private func linearToSRGB(_ linear: Float) -> Float {
        linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1.0/2.4) - 0.055
    }
    
    nonisolated private func rgbToSH(_ rgb: Float) -> Float {
        (rgb - 0.5) / Float(sqrt(1.0 / (4.0 * .pi)))
    }
    
    nonisolated private func inverseSigmoid(_ x: Float) -> Float {
        let c = min(max(x, 1e-6), 1.0 - 1e-6)
        return log(c / (1.0 - c))
    }
    
    nonisolated private func appendFloat(_ data: inout Data, _ value: Float) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}

private func multiArrayToFloatArray(_ array: MLMultiArray) -> [Float] {
    let count = array.count
    var result = [Float](repeating: 0, count: count)
    for i in 0..<count {
        result[i] = Float(array[i].doubleValue)
    }
    return result
}

private func float32ToFloat16Bits(_ f: Float) -> UInt16 {
    let bits = f.bitPattern
    let sign = (bits >> 16) & 0x8000
    let exp = Int((bits >> 23) & 0xFF) - 127 + 15
    let mant = bits & 0x7FFFFF
    
    if exp <= 0 { return UInt16(sign) }
    if exp >= 31 { return UInt16(sign | 0x7C00) }
    return UInt16(sign | UInt32(exp << 10) | (mant >> 13))
}

struct GaussianOutputs: Sendable {
    let meanVectors: [Float]
    let singularValues: [Float]
    let quaternions: [Float]
    let colors: [Float]
    let opacities: [Float]
}

enum GeneratorError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case imageLoadFailed
    case imageProcessingFailed
    case inferenceOutputMissing
    case modelIncompatible(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Model not found in bundle"
        case .modelNotLoaded: return "Model not loaded"
        case .imageLoadFailed: return "Failed to load image"
        case .imageProcessingFailed: return "Failed to process image"
        case .inferenceOutputMissing: return "Inference output missing"
        case .modelIncompatible(let msg): return "Model incompatible: \(msg)"
        }
    }
}
