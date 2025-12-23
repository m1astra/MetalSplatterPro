import Foundation
import CoreML
import UIKit
import ImageIO
import CoreImage

// Set to true to use fast mock inference on simulator (for UI testing)
#if targetEnvironment(simulator)
private let useMockInference = true
#else
private let useMockInference = false
#endif

@MainActor
@Observable
class SplatGenerator {
    private var model: MLModel?
    private let inputSize = 1536
    
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
                    let (imageData, focalLengthPx, originalWidth, originalHeight) = try self.preprocessImage(imageURL)
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
    
    // Mock generation for fast UI testing on simulator
    private func generateMock(baseName: String) async throws -> URL {
        try await Task.sleep(for: .seconds(2))
        
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var outputURL = documentsDir.appendingPathComponent("\(baseName).ply")
        
        var counter = 1
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = documentsDir.appendingPathComponent("\(baseName)_\(counter).ply")
            counter += 1
        }
        
        // Create a minimal valid PLY with a few test points
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
    
    nonisolated private func preprocessImage(_ url: URL) throws -> ([Float], Float, Int, Int) {
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

        guard let resized = resizeCGImage(oriented, to: CGSize(width: inputSize, height: inputSize)),
              let floatData = imageToFloatArray(resized) else {
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
        let ctx = CIContext(options: nil)
        let rect = ciImage.extent.integral
        return ctx.createCGImage(ciImage, from: rect)
    }
    
    nonisolated private func resizeCGImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    
    nonisolated private func imageToFloatArray(_ cgImage: CGImage) -> [Float]? {
        let width = cgImage.width
        let height = cgImage.height
        
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixelData = data.assumingMemoryBound(to: UInt8.self)
        var floatData = [Float](repeating: 0, count: 3 * width * height)
        
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let chIndex = y * width + x
                floatData[0 * width * height + chIndex] = Float(pixelData[pixelIndex]) / 255.0
                floatData[1 * width * height + chIndex] = Float(pixelData[pixelIndex + 1]) / 255.0
                floatData[2 * width * height + chIndex] = Float(pixelData[pixelIndex + 2]) / 255.0
            }
        }
        
        return floatData
    }
    
    nonisolated private func runInferenceSync(model: MLModel, imageData: [Float], focalLengthPx: Float, originalWidth: Int) throws -> GaussianOutputs {
        let imageArray = try MLMultiArray(shape: [1, 3, 1536, 1536], dataType: .float16)
        let imagePtr = imageArray.dataPointer.assumingMemoryBound(to: UInt16.self)
        for i in 0..<imageData.count {
            imagePtr[i] = float32ToFloat16(imageData[i])
        }
        
        let disparityFactor = focalLengthPx / Float(originalWidth)
        let disparityArray = try MLMultiArray(shape: [1], dataType: .float16)
        let dispPtr = disparityArray.dataPointer.assumingMemoryBound(to: UInt16.self)
        dispPtr[0] = float32ToFloat16(disparityFactor)
        
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: imageArray),
            "disparity_factor": MLFeatureValue(multiArray: disparityArray)
        ])
        
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
        
        for i in 0..<numGaussians {
            worldMeans[i * 3] = ndc.meanVectors[i * 3] * scaleX
            worldMeans[i * 3 + 1] = ndc.meanVectors[i * 3 + 1] * scaleY
            worldMeans[i * 3 + 2] = ndc.meanVectors[i * 3 + 2]
            worldSingularValues[i * 3] = ndc.singularValues[i * 3] * scaleX
            worldSingularValues[i * 3 + 1] = ndc.singularValues[i * 3 + 1] * scaleY
            worldSingularValues[i * 3 + 2] = ndc.singularValues[i * 3 + 2]
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
        
        var data = Data()
        data.append(header.data(using: .utf8)!)
        
        for i in 0..<numPoints {
            appendFloat(&data, gaussians.meanVectors[i * 3])
            appendFloat(&data, gaussians.meanVectors[i * 3 + 1])
            appendFloat(&data, gaussians.meanVectors[i * 3 + 2])
            
            let r = gaussians.colors[i * 3], g = gaussians.colors[i * 3 + 1], b = gaussians.colors[i * 3 + 2]
            appendFloat(&data, rgbToSH(linearToSRGB(r)))
            appendFloat(&data, rgbToSH(linearToSRGB(g)))
            appendFloat(&data, rgbToSH(linearToSRGB(b)))
            
            appendFloat(&data, inverseSigmoid(gaussians.opacities[i]))
            
            appendFloat(&data, log(max(gaussians.singularValues[i * 3], 1e-8)))
            appendFloat(&data, log(max(gaussians.singularValues[i * 3 + 1], 1e-8)))
            appendFloat(&data, log(max(gaussians.singularValues[i * 3 + 2], 1e-8)))
            
            appendFloat(&data, gaussians.quaternions[i * 4])
            appendFloat(&data, gaussians.quaternions[i * 4 + 1])
            appendFloat(&data, gaussians.quaternions[i * 4 + 2])
            appendFloat(&data, gaussians.quaternions[i * 4 + 3])
        }
        
        try data.write(to: outputURL)
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

private func float32ToFloat16(_ f: Float) -> UInt16 {
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
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Model not found in bundle"
        case .modelNotLoaded: return "Model not loaded"
        case .imageLoadFailed: return "Failed to load image"
        case .imageProcessingFailed: return "Failed to process image"
        case .inferenceOutputMissing: return "Inference output missing"
        }
    }
}
