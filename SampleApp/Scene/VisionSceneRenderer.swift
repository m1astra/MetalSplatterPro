#if os(visionOS)

import CompositorServices
import Metal
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import Spatial
import SwiftUI
import _RealityKit_SwiftUI

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

class VisionTracking {
    static let shared = VisionTracking()
    
    var pinchesAreFromRealityKit = false
    
    // Gaze rays -> controller emulation state
    var leftSelectionRayId = -1
    var leftSelectionRayOrigin = simd_float3(0.0, 0.0, 0.0)
    var leftSelectionRayDirection = simd_float3(0.0, 0.0, 0.0)
    var leftPinchStartPosition = simd_float3(0.0, 0.0, 0.0)
    var leftPinchCurrentPosition = simd_float3(0.0, 0.0, 0.0)
    var leftPinchStartAngle = simd_quatf()
    var leftPinchCurrentAngle = simd_quatf()
    var leftIsPinching = false
    var lastLeftIsPinching = false
    
    var rightSelectionRayId = -1
    var rightSelectionRayOrigin = simd_float3(0.0, 0.0, 0.0)
    var rightSelectionRayDirection = simd_float3(0.0, 0.0, 0.0)
    var rightPinchStartPosition = simd_float3(0.0, 0.0, 0.0)
    var rightPinchCurrentPosition = simd_float3(0.0, 0.0, 0.0)
    var rightPinchStartAngle = simd_quatf()
    var rightPinchCurrentAngle = simd_quatf()
    var rightIsPinching = false
    var lastRightIsPinching = false
    
    var rightPinchStartHeadsetPose = matrix_identity_float4x4
    var leftPinchStartHeadsetPose = matrix_identity_float4x4
    var lastDeviceAnchor = matrix_identity_float4x4
    
    var anyPinchStartHeadsetPose = matrix_identity_float4x4
    var anyPinchStartPosition = simd_float3(0.0, 0.0, 0.0)
    var anyPinchCurrentPosition = simd_float3(0.0, 0.0, 0.0)
    var anyPinchStartAngle = simd_quatf()
    var anyPinchCurrentAngle = simd_quatf()
    var anySinglePinching = false
    var anyMultiPinching = false
}

class VisionSceneRenderer {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "VisionSceneRenderer")

    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: SplatRenderer?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero
    var firstHeadHeight: Float = 0.0
    
    var lastRenderTime: Double = 0.0
    var currentRenderQuality = 1.0
    var startHandRotationMat = matrix_identity_float4x4
    var startHandTranslationMat = matrix_identity_float4x4
    var startHandScaleMat = matrix_identity_float4x4
    static var handRotationMat = matrix_identity_float4x4
    static var handTranslationMat = matrix_identity_float4x4
    static var handScaleMat = matrix_identity_float4x4
    var lastAnySinglePinching = false
    var lastAnyMultiPinching = false
    var modeSwitchHysteresis = 0.0

    var loadedUrl: URL? = nil
    var loadedUrlId: String? = nil
    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider

    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!
        self.lastRenderTime = CACurrentMediaTime()

        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelRenderer = nil
        switch model {
        case .gaussianSplat(let url):
            _ = url.startAccessingSecurityScopedResource()
            print("Trying to open:", url)
            let splat = try SplatRenderer(device: device,
                                          colorFormat: layerRenderer.configuration.colorFormat,
                                          depthFormat: layerRenderer.configuration.depthFormat,
                                          sampleCount: 1,
                                          maxViewCount: layerRenderer.properties.viewCount,
                                          maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            try await splat.read(from: url)
            modelRenderer = splat
            
            DataStorage.loadDB()
            let data = DataStorage.getDataFor(url)
            VisionSceneRenderer.handRotationMat = simd_float4x4(data.rotation)
            VisionSceneRenderer.handTranslationMat = simd_float4x4(data.translation)
            VisionSceneRenderer.handScaleMat = matrix_identity_float4x4
            VisionSceneRenderer.handScaleMat.columns.0.x = data.scale.x
            VisionSceneRenderer.handScaleMat.columns.1.y = data.scale.y
            VisionSceneRenderer.handScaleMat.columns.2.z = data.scale.z
            loadedUrl = url
            loadedUrlId = getStableId(for: url)
            /*print(VisionSceneRenderer.handRotationMat)
            print(VisionSceneRenderer.handTranslationMat)
            print(VisionSceneRenderer.handScaleMat)*/
            
            url.stopAccessingSecurityScopedResource()
        case .none:
            break
        default:
            break
        }
        
    }

    func startRenderLoop(_ onTeardown: @escaping () -> Void) {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }

            let renderThread = Thread {
                self.renderLoop(onTeardown)
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }

    private func viewports(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) -> [SplatRenderer.ViewportDescriptor] {
        let translationMatrix = matrix4x4_translation(0.0, firstHeadHeight, Constants.modelCenterZ) * VisionSceneRenderer.handTranslationMat * VisionSceneRenderer.handScaleMat
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        VisionTracking.shared.lastDeviceAnchor = simdDeviceAnchor
        
        let rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians) + .pi,
                                                axis: Constants.rotationAxis) * VisionSceneRenderer.handRotationMat

        return drawable.views.enumerated().map { (i, view) in
            let userViewpointMatrix = (simdDeviceAnchor * view.transform).inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: i)
            let screenSize = SIMD2(x: Int(view.textureMap.viewport.width),
                                   y: Int(view.textureMap.viewport.height))
            return SplatRenderer.ViewportDescriptor(viewport: view.textureMap.viewport,
                                                   projectionMatrix: projectionMatrix,
                                                   viewMatrix: userViewpointMatrix * translationMatrix * rotationMatrix * commonUpCalibration,
                                                   screenSize: screenSize)
        }
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)
        
        modeSwitchHysteresis -= now.timeIntervalSince(lastRotationUpdateTimestamp)
        if modeSwitchHysteresis < 0.0 {
            modeSwitchHysteresis = 0.0
        }
        
        if modeSwitchHysteresis <= 0.0 && ((lastAnyMultiPinching && !VisionTracking.shared.anyMultiPinching) || (lastAnySinglePinching && !VisionTracking.shared.anySinglePinching)) {
            modeSwitchHysteresis = 0.2
        }

        if modeSwitchHysteresis > 0.0 {
            // nothing
        }
        else if VisionTracking.shared.anySinglePinching {
            if !lastAnySinglePinching {
                self.startHandRotationMat = VisionSceneRenderer.handRotationMat
                self.startHandTranslationMat = VisionSceneRenderer.handTranslationMat
                self.startHandScaleMat = VisionSceneRenderer.handScaleMat
                
                VisionTracking.shared.anyPinchStartPosition = VisionTracking.shared.anyPinchCurrentPosition
                VisionTracking.shared.anyPinchStartAngle = VisionTracking.shared.anyPinchCurrentAngle
                VisionTracking.shared.anyPinchStartHeadsetPose = VisionTracking.shared.lastDeviceAnchor
            }
        
            let pinchDelta = (VisionTracking.shared.anyPinchCurrentAngle * VisionTracking.shared.anyPinchStartAngle.inverse).flipYaw()
        
            VisionSceneRenderer.handRotationMat = simd_float4x4(pinchDelta) * self.startHandRotationMat
            
            let headsetForward = normalize(-VisionTracking.shared.lastDeviceAnchor.columns.2.asFloat3())
            let flatForward = simd_float3(x: headsetForward.x, y: 0, z: headsetForward.z)
            
            let handTranslate = (VisionTracking.shared.anyPinchCurrentPosition - VisionTracking.shared.anyPinchStartPosition)
            let forwardAmount = dot(handTranslate, flatForward)
            let forwardComponent = headsetForward * forwardAmount
            let lateralComponent = handTranslate - forwardComponent
            
            let amplification: Float = 5.0

            let amplifiedForward = forwardComponent * amplification
            let scaledDist = simd_distance(startHandTranslationMat.columns.3.asFloat3(), VisionSceneRenderer.handTranslationMat.columns.3.asFloat3()) * (forwardAmount < 0.0 ? -1.0 : 1.0)
            let scaledDistSqInv = scaledDist > 0 ? (1.0 / (scaledDist * scaledDist)) : 1.0
            let exponentialAmplifiedForward = forwardComponent * scaledDist
            let scaledHandTranslation =
                lateralComponent +
                amplifiedForward
            
            let curScale = max(0.1, 1.0 + scaledDist)
            VisionSceneRenderer.handTranslationMat = scaledHandTranslation.asFloat4x4() * self.startHandTranslationMat
            VisionSceneRenderer.handScaleMat = simd_float4x4(curScale) * self.startHandScaleMat
            
        
            
            //self.startHandRotationMat = VisionSceneRenderer.handRotationMat
            //VisionTracking.shared.anyPinchStartAngle = VisionTracking.shared.anyPinchCurrentAngle
        }
        else if VisionTracking.shared.anyMultiPinching {
            if !lastAnyMultiPinching {
                self.startHandRotationMat = VisionSceneRenderer.handRotationMat
                self.startHandTranslationMat = VisionSceneRenderer.handTranslationMat
                self.startHandScaleMat = VisionSceneRenderer.handScaleMat
                
                VisionTracking.shared.rightPinchStartPosition = VisionTracking.shared.rightPinchCurrentPosition
                VisionTracking.shared.rightPinchStartAngle = VisionTracking.shared.rightPinchCurrentAngle
                VisionTracking.shared.rightPinchStartHeadsetPose = VisionTracking.shared.lastDeviceAnchor
                VisionTracking.shared.leftPinchStartPosition = VisionTracking.shared.leftPinchCurrentPosition
                VisionTracking.shared.leftPinchStartAngle = VisionTracking.shared.leftPinchCurrentAngle
                VisionTracking.shared.leftPinchStartHeadsetPose = VisionTracking.shared.lastDeviceAnchor
            }
            
            // Handle rotation (including roll)
            /*
            let prevVec = normalize(VisionTracking.shared.rightPinchStartPosition - VisionTracking.shared.leftPinchStartPosition)
            let currVec = normalize(VisionTracking.shared.rightPinchCurrentPosition - VisionTracking.shared.leftPinchCurrentPosition)

            let axis = cross(prevVec, currVec)
            let axisLen = length(axis)

            if axisLen > 1e-5 {
                let vecDot = dot(prevVec, currVec)
                let angle = acos(vecDot.clamp(-1.0, 1.0))
                let deltaRot = simd_quatf(angle: -angle, axis: axis / axisLen).inverse.flipYaw()
                
                VisionSceneRenderer.handRotationMat = simd_float4x4(deltaRot) * self.startHandRotationMat
            }
            */
            
            // Handle rotation (not including roll)
            func yawAngle(from v: SIMD3<Float>) -> Float {
                atan2(v.x, v.z)
            }

            
            let prevVec = normalize(VisionTracking.shared.rightPinchStartPosition - VisionTracking.shared.leftPinchStartPosition)
            let currVec = normalize(VisionTracking.shared.rightPinchCurrentPosition - VisionTracking.shared.leftPinchCurrentPosition)

            let prevYaw = yawAngle(from: prevVec)
            let currYaw = yawAngle(from: currVec)

            let deltaYaw = currYaw - prevYaw
            let deltaRot = simd_quatf(angle: deltaYaw, axis: [0, 1, 0])

            VisionSceneRenderer.handRotationMat = simd_float4x4(deltaRot) * self.startHandRotationMat
            
            let averageHandPositionStart = (VisionTracking.shared.leftPinchStartPosition + VisionTracking.shared.rightPinchStartPosition) * 0.5
            let averageHandPositionCurrent = (VisionTracking.shared.leftPinchCurrentPosition + VisionTracking.shared.rightPinchCurrentPosition) * 0.5
            let leftDelta = VisionTracking.shared.leftPinchStartPosition - VisionTracking.shared.leftPinchCurrentPosition
            let rightDelta = VisionTracking.shared.rightPinchStartPosition - VisionTracking.shared.rightPinchCurrentPosition
            let handTranslate = (averageHandPositionCurrent - averageHandPositionStart)
            
            // Handle scaling thresholds
            var currentHandDist = simd_distance(VisionTracking.shared.leftPinchCurrentPosition, VisionTracking.shared.rightPinchCurrentPosition)
            let startHandDist = simd_distance(VisionTracking.shared.leftPinchStartPosition, VisionTracking.shared.rightPinchStartPosition)
            if abs(currentHandDist - startHandDist) >= 0.03 {
                if currentHandDist > startHandDist {
                    currentHandDist -= 0.03
                }
                else {
                    currentHandDist += 0.03
                }
            }
            else {
                currentHandDist = startHandDist
            }
            let scale = currentHandDist / startHandDist
            
            let headsetRotatedByModel = VisionTracking.shared.lastDeviceAnchor * VisionSceneRenderer.handRotationMat
            let headsetForward = -headsetRotatedByModel.columns.2.asFloat3()
            let flatForward = simd_float3(x: headsetForward.x, y: 0, z: headsetForward.z)
            let curModelScale = VisionSceneRenderer.handScaleMat.columns.0.x
            
            VisionSceneRenderer.handTranslationMat = ((averageHandPositionCurrent - averageHandPositionStart) * 4.0 * curModelScale).asFloat4x4() * self.startHandTranslationMat
            VisionSceneRenderer.handScaleMat = simd_float4x4(scale) * self.startHandScaleMat
        }
        
        // Prevent the model from imploding
        if VisionSceneRenderer.handScaleMat.columns.0.x == 0.0 {
            VisionSceneRenderer.handScaleMat = matrix_identity_float4x4
        }
        if VisionSceneRenderer.handScaleMat.columns.0.x <= 0.1 {
            VisionSceneRenderer.handScaleMat = matrix_identity_float4x4 * 0.1
        }
        VisionSceneRenderer.handScaleMat.columns.3 = simd_float4(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
        
        //print(VisionSceneRenderer.handScaleMat.columns.0.x)
        
        if VisionTracking.shared.anySinglePinching {
            self.startHandRotationMat = VisionSceneRenderer.handRotationMat
            self.startHandTranslationMat = VisionSceneRenderer.handTranslationMat
            self.startHandScaleMat = VisionSceneRenderer.handScaleMat
            
            VisionTracking.shared.anyPinchStartPosition = VisionTracking.shared.anyPinchCurrentPosition
            VisionTracking.shared.anyPinchStartAngle = VisionTracking.shared.anyPinchCurrentAngle
            VisionTracking.shared.anyPinchStartHeadsetPose = VisionTracking.shared.lastDeviceAnchor
            VisionTracking.shared.rightPinchStartPosition = VisionTracking.shared.rightPinchCurrentPosition
            VisionTracking.shared.rightPinchStartAngle = VisionTracking.shared.rightPinchCurrentAngle
            VisionTracking.shared.rightPinchStartHeadsetPose = VisionTracking.shared.lastDeviceAnchor
            VisionTracking.shared.leftPinchStartPosition = VisionTracking.shared.leftPinchCurrentPosition
            VisionTracking.shared.leftPinchStartAngle = VisionTracking.shared.leftPinchCurrentAngle
            VisionTracking.shared.leftPinchStartHeadsetPose = VisionTracking.shared.lastDeviceAnchor
        }
        
        lastAnySinglePinching = VisionTracking.shared.anySinglePinching
        lastAnyMultiPinching = VisionTracking.shared.anyMultiPinching
    }
    
    var lastPrintQuality = 0.0

    func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        updateRotation()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        
        let renderDelta = CACurrentMediaTime() - self.lastRenderTime
        if renderDelta > 0.012 {
            self.currentRenderQuality -= renderDelta
            if self.currentRenderQuality < 0.1 {
                self.currentRenderQuality = 0.1
            }
            layerRenderer.renderQuality = LayerRenderer.RenderQuality(Float(self.currentRenderQuality))
            
        }
        else {
            self.currentRenderQuality += renderDelta
            if self.currentRenderQuality > 1.0 {
                self.currentRenderQuality = 1.0
            }
        }
        
        if CACurrentMediaTime() - self.lastPrintQuality > 5.0 {
            print("Current render quality is:", self.currentRenderQuality)
            self.lastPrintQuality = CACurrentMediaTime()
            
            if self.currentRenderQuality < 0.5 {
                if let splat = modelRenderer {
                    splat.highQualityDepth = true
                }
            }
            else {
                if let splat = modelRenderer {
                    splat.highQualityDepth = true
                }
            }
        }
        
        self.lastRenderTime = CACurrentMediaTime()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

        let drawables = frame.queryDrawables()
        if drawables.count <= 0 { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        frame.startSubmission()
        
        for drawable in drawables {
            let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
            let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
            
            if firstHeadHeight == 0.0 {
                firstHeadHeight = deviceAnchor?.originFromAnchorTransform.columns.3.y ?? 0.0
            }

            drawable.deviceAnchor = deviceAnchor

            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
                semaphore.signal()
            }

            let viewports = self.viewports(drawable: drawable, deviceAnchor: deviceAnchor)

            do {
                try modelRenderer?.render(viewports: viewports,
                                          colorTexture: drawable.colorTextures[0],
                                          colorStoreAction: .store,
                                          depthTexture: drawable.depthTextures[0],
                                          rasterizationRateMap: drawable.rasterizationRateMaps.first,
                                          renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? drawable.views.count : 1,
                                          to: commandBuffer)
            } catch {
                Self.log.error("Unable to render scene: \(error.localizedDescription)")
            }

            drawable.encodePresent(commandBuffer: commandBuffer)
        }

        commandBuffer.commit()

        frame.endSubmission()
    }
    
    static func handleSpatialEventFusion() {
        VisionTracking.shared.anyMultiPinching = (VisionTracking.shared.rightIsPinching && VisionTracking.shared.leftIsPinching)
        if (VisionTracking.shared.rightIsPinching || VisionTracking.shared.leftIsPinching) && !(VisionTracking.shared.anyMultiPinching) {
            if VisionTracking.shared.rightIsPinching {
                VisionTracking.shared.anyPinchStartPosition = VisionTracking.shared.rightPinchStartPosition
                VisionTracking.shared.anyPinchCurrentPosition = VisionTracking.shared.rightPinchCurrentPosition
                VisionTracking.shared.anyPinchStartAngle = VisionTracking.shared.rightPinchStartAngle
                VisionTracking.shared.anyPinchCurrentAngle = VisionTracking.shared.rightPinchCurrentAngle
                VisionTracking.shared.anyPinchStartHeadsetPose = VisionTracking.shared.rightPinchStartHeadsetPose
            }
            else {
                VisionTracking.shared.anyPinchStartAngle = VisionTracking.shared.leftPinchStartAngle
                VisionTracking.shared.anyPinchCurrentAngle = VisionTracking.shared.leftPinchCurrentAngle
                VisionTracking.shared.anyPinchStartPosition = VisionTracking.shared.leftPinchStartPosition
                VisionTracking.shared.anyPinchCurrentPosition = VisionTracking.shared.leftPinchCurrentPosition
                VisionTracking.shared.anyPinchStartHeadsetPose = VisionTracking.shared.leftPinchStartHeadsetPose
            }
            VisionTracking.shared.anySinglePinching = true
        }
        else {
            VisionTracking.shared.anyPinchStartPosition = simd_float3()
            VisionTracking.shared.anyPinchCurrentPosition = simd_float3()
            VisionTracking.shared.anyPinchStartAngle = simd_quatf()
            VisionTracking.shared.anyPinchCurrentAngle = simd_quatf()
            VisionTracking.shared.anySinglePinching = false
        }
    }
    
    static func handleSpatialEvent(_ value: EntityTargetValue<SpatialEventCollection>?, _ event: SpatialEventCollection.Event) {
        defer { handleSpatialEventFusion() }
    
        if value != nil {
            VisionTracking.shared.pinchesAreFromRealityKit = true
        }
        else {
            VisionTracking.shared.pinchesAreFromRealityKit = false
        }

        var isInProgressPinch = false
        var isRight = false
        if event.id.hashValue == VisionTracking.shared.leftSelectionRayId {
            isInProgressPinch = true
        }
        else if event.id.hashValue == VisionTracking.shared.rightSelectionRayId {
            isInProgressPinch = true
            isRight = true
        }
        
        /*if #available(visionOS 2.0, *) {
            print(event.chirality, event.phase, event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId)
        }*/
        
        if event.kind == .indirectPinch && event.phase == .active {
            if !isInProgressPinch {
            
                // If we have chiralities, assign based on them
                if #available(visionOS 2.0, *) {
                    if event.chirality == .none {
                        if VisionTracking.shared.leftSelectionRayId != -1 {
                            isRight = true
                        }
                    }
                    else {
                        isRight = event.chirality == .right
                    }
                }
                else {
                    if VisionTracking.shared.leftSelectionRayId != -1 {
                        isRight = true
                    }
                }
                
                if isRight && VisionTracking.shared.rightSelectionRayId != -1 {
                    print("THIRD HAND??? early fallback")
                    
                    VisionTracking.shared.leftSelectionRayId = -1
                    VisionTracking.shared.rightSelectionRayId = -1
                    isRight = false
                    
                    print(event, event.id.hashValue, isRight, isInProgressPinch, VisionTracking.shared.leftSelectionRayId, VisionTracking.shared.rightSelectionRayId)
                    return
                }
                
                if isRight {
                    VisionTracking.shared.rightSelectionRayId = event.id.hashValue
                }
                else if VisionTracking.shared.leftSelectionRayId == -1 {
                    VisionTracking.shared.leftSelectionRayId = event.id.hashValue
                }
                else {
                    print("THIRD HAND???")
                    print(event, event.id.hashValue, isRight, isInProgressPinch, VisionTracking.shared.leftSelectionRayId, VisionTracking.shared.rightSelectionRayId)
                    return
                }
            }
            
            if isRight {
                VisionTracking.shared.rightIsPinching = true
            }
            else {
                VisionTracking.shared.leftIsPinching = true
            }
        }
        else if event.kind == .indirectPinch {
            if event.id.hashValue == VisionTracking.shared.leftSelectionRayId {
                VisionTracking.shared.leftIsPinching = false
                VisionTracking.shared.leftSelectionRayId = -1
            }
            else if event.id.hashValue == VisionTracking.shared.rightSelectionRayId {
                VisionTracking.shared.rightIsPinching = false
                VisionTracking.shared.rightSelectionRayId = -1
            }
            return
        }
        
        //print(event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId, event.inputDevicePose)
    
        // For eyes: inputDevicePose is the pinch connect location, and the selection ray is
        // the eye center plus the gaze
        // For AssistiveTouch mouse: inputDevicePose is locked to the last plane the device was on, and
        // the selection ray is some random pose?
        // For keyboard accessibility touch: inputDevicePose is some random place, selectionRay is 0,0,0
        
        // selectionRay origin + direction
        if let ray = event.selectionRay {
            let origin = value?.convert(ray.origin, from: .local, to: .scene) ?? simd_float3(ray.origin)
            let direction = simd_normalize((value?.convert(ray.origin + ray.direction, from: .local, to: .scene) ?? origin + simd_float3(ray.direction)) - origin)
            let pos = origin + direction
            
            if isRight {
                VisionTracking.shared.rightSelectionRayOrigin = origin
                VisionTracking.shared.rightSelectionRayDirection = direction
            }
            else {
                VisionTracking.shared.leftSelectionRayOrigin = origin
                VisionTracking.shared.leftSelectionRayDirection = direction
            }
        }
        
        // inputDevicePose
        if let inputPose = event.inputDevicePose {
            let pos = value?.convert(inputPose.pose3D.position, from: .local, to: .scene) ?? simd_float3(inputPose.pose3D.position)
            let rot = value?.convert(inputPose.pose3D.rotation, from: .local, to: .scene) ?? simd_quatf(inputPose.pose3D.rotation)
            //WorldTracker.shared.testPosition = pos
            
            // Started a pinch and have a start position
            if !isInProgressPinch {
                if isRight {
                    VisionTracking.shared.rightPinchStartPosition = pos
                    VisionTracking.shared.rightPinchCurrentPosition = pos
                    VisionTracking.shared.rightPinchStartAngle = rot
                    VisionTracking.shared.rightPinchCurrentAngle = rot
                    VisionTracking.shared.rightPinchStartHeadsetPose = VisionTracking.shared.lastDeviceAnchor
                }
                else {
                    VisionTracking.shared.leftPinchStartPosition = pos
                    VisionTracking.shared.leftPinchCurrentPosition = pos
                    VisionTracking.shared.leftPinchStartAngle = rot
                    VisionTracking.shared.leftPinchCurrentAngle = rot
                    VisionTracking.shared.leftPinchStartHeadsetPose = VisionTracking.shared.lastDeviceAnchor
                }
                
            }
            else {
                if isRight {
                    VisionTracking.shared.rightPinchCurrentPosition = pos
                    VisionTracking.shared.rightPinchCurrentAngle = rot
                }
                else {
                    VisionTracking.shared.leftPinchCurrentPosition = pos
                    VisionTracking.shared.leftPinchCurrentAngle = rot
                }
            }
        }
        else {
            // Just in case
            if !isInProgressPinch {
                if isRight {
                    VisionTracking.shared.rightPinchStartPosition = simd_float3()
                    VisionTracking.shared.rightPinchCurrentPosition = simd_float3()
                    VisionTracking.shared.rightPinchStartAngle = simd_quatf()
                    VisionTracking.shared.rightPinchCurrentAngle = simd_quatf()
                    VisionTracking.shared.rightPinchStartHeadsetPose = simd_float4x4()
                }
                else {
                    VisionTracking.shared.leftPinchStartPosition = simd_float3()
                    VisionTracking.shared.leftPinchCurrentPosition = simd_float3()
                    VisionTracking.shared.leftPinchStartAngle = simd_quatf()
                    VisionTracking.shared.leftPinchCurrentAngle = simd_quatf()
                    VisionTracking.shared.leftPinchStartHeadsetPose = simd_float4x4()
                }
                
            }
        }
    }

    func renderLoop(_ onTeardown: @escaping () -> Void) {
        layerRenderer.waitUntilRunning()
        
        layerRenderer.onSpatialEvent = { eventCollection in
            for event in eventCollection {
                VisionSceneRenderer.handleSpatialEvent(nil, event)
            }
        }
    
        //let immersiveStatus = ImmersiveStatus()
        while true {
            if layerRenderer.state == .invalidated {
                Self.log.warning("Layer is invalidated")
                //immersiveStatus.isShown = false
                if let id = loadedUrlId {
                    DataStorage.storeDataForId(id)
                    
                    /*print(VisionSceneRenderer.handRotationMat)
                    print(VisionSceneRenderer.handTranslationMat)
                    print(VisionSceneRenderer.handScaleMat)*/
                }
                onTeardown()
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                
                if let id = loadedUrlId {
                    DataStorage.storeDataForId(id)
                    
                    /*print(VisionSceneRenderer.handRotationMat)
                    print(VisionSceneRenderer.handTranslationMat)
                    print(VisionSceneRenderer.handScaleMat)*/
                }
                onTeardown()
                //immersiveStatus.isShown = false
                continue
            } else {
                //immersiveStatus.isShown = true
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}

#endif // os(visionOS)

