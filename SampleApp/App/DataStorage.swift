import Foundation
import CryptoKit
import simd

struct StoredPhotoPose: Codable {
    var rotation: [simd_float4]
    var translation: [simd_float4]
    var scale: simd_float3
    
    init() {
        rotation = [matrix_identity_float4x4.columns.0,matrix_identity_float4x4.columns.1, matrix_identity_float4x4.columns.2, matrix_identity_float4x4.columns.3]
        translation = [matrix_identity_float4x4.columns.0,matrix_identity_float4x4.columns.1, matrix_identity_float4x4.columns.2, matrix_identity_float4x4.columns.3]
        scale = simd_float3(x: 1.0, y: 1.0, z: 1.0)
    }
}

struct PoseDatabase: Codable {
    var poses: [String: StoredPhotoPose]
    
    init() {
        poses = [:]
    }
}

public func getStableId(for url: URL) -> String? {
#if os(iOS)
    let options: NSURL.BookmarkCreationOptions = [.withSecurityScope]
#else
    let options: NSURL.BookmarkCreationOptions = []
#endif
    do {
        let bookmark = try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return SHA256.hash(data: bookmark).compactMap { String(format: "%02x", $0) }.joined()
    }
    catch {
        return nil
    }
}

class DataStorage {
    static var poseDatabase = PoseDatabase()
    
    static func poseDbURL() throws -> URL {
        try FileManager.default.url(for: .documentDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        .appendingPathComponent("photoposes.data")
    }

    static func loadDB() {
        poseDatabase = PoseDatabase()
        if let data = try? Data(contentsOf: poseDbURL()) {
            do {
                poseDatabase = try JSONDecoder().decode(PoseDatabase.self, from: data)
                print("Loaded DB")
            }
            catch {
                print("Failed to load DB")
                print(error)
            }
        }
    }

    static func saveDB() {
        do {
            let data = try JSONEncoder().encode(poseDatabase)
            try data.write(to: poseDbURL(), options: [.atomic])
            print("Save DB")
        }
        catch {
            print(error)
        }
    }
    
    static func getDataFor(_ url: URL) -> StoredPhotoPose {
        if let id = getStableId(for: url) {
            print("Getting data for ID", id)
            return poseDatabase.poses[id] ?? StoredPhotoPose()
        }
        else {
            print("No stable id for url?", url)
            return StoredPhotoPose()
        }
    }
    
    static func storeDataFor(_ url: URL) {
        if let id = getStableId(for: url) {
            storeDataForId(id)
        }
        else {
            print("No stable id for url?", url)
        }
    }
    
    static func storeDataForId(_ id: String) {
        print("Storing data for ID", id)
        var stored = StoredPhotoPose()
#if os(visionOS)
        stored.rotation = VisionSceneRenderer.handRotationMat.as4Array()
        stored.translation = VisionSceneRenderer.handTranslationMat.as4Array()
        stored.scale = simd_float3(x: VisionSceneRenderer.handScaleMat.columns.0.x, y: VisionSceneRenderer.handScaleMat.columns.1.y, z: VisionSceneRenderer.handScaleMat.columns.2.z)
#endif
        poseDatabase.poses[id] = stored
    }
}
