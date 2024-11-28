#if os(visionOS)
import RealityKit
import ARKit
import SwiftUI
import os

// To use it, simply add this ViewModifier anywhere in the app.
public
struct EnableDampingFollow: ViewModifier {
    public init() { }
    
    public
    func body(content: Content) -> some View {
        content
            .task {
                DampingFollowSystem.registerSystem()
                DampingFollowComponent.registerComponent()
            }
    }
}


@MainActor
@Observable
public
class FollowManager {
    public init() { }
    
    public
    var isFollow = true
}


public
struct DampingFollowComponent: Component {
    //The FollowManager object provides a way to control the follow mode within the view being followed. When you assign a value to the FollowManager and set isFollow to false, the view will stop following and remain stationary at its current position.
    public
    var followManager:FollowManager?
    public
    var distance:Float
    public
    var direction:SIMD3<Float>
    
    public
    var sensitivityLevel:SensitivityLevel
    
    //In RealityKit, the forward direction of the field of view is the -Z axis, the right side is the +X axis, and the upward direction is the +Y axis.
    //If we want to place an object directly in front of the field of view, we set X = 0, Y = 0, Z = -1. Then, we set the placement distance to 0.5 meter.
    public init(followManager: FollowManager? = nil, distance: Float = 0.5, direction: SIMD3<Float> = [0,0,-1], sensitivityLevel: SensitivityLevel = .high) {
        self.followManager = followManager
        self.distance = distance
        self.direction = direction
        self.sensitivityLevel = sensitivityLevel
    }
    public
    enum SensitivityLevel {
        case low
        case medium
        case high
        case instant
        var followFrequency:TimeInterval {
            switch self {
            case .instant:
                0.0
            default:
                0.05
            }
        }
        
        var animationDuration:TimeInterval {
            switch self {
            case .low:
                1.5
            case .medium:
                1
            case .high:
                0.5
            case .instant:
                0
            }
        }
    }
    
    // Package internal property
    var lastMoveTime:Date? = nil
    
}

// Package internal class
@MainActor
@Observable
class DampingFollowSystemDataModel {
    var initTask:Task<Void,Never>? = nil
    var systemInited = false
    var systemError:Error? = nil
}

// Package internal system
@MainActor
struct DampingFollowSystem: System {
    private
    let dataModel = DampingFollowSystemDataModel()
    private
    let headPositionProvider = WorldTrackingProvider()
    //↓ This section initializes the head-following functionality.
    private
    let arSession = ARKitSession()
    init(scene: RealityKit.Scene) {
        initSystem()
    }
    func initSystem() {
        //Use a Task to wrap the initialization process so that the Task can be promptly canceled when the system is destroyed, preventing resource waste.
        dataModel.initTask?.cancel()
        dataModel.initTask = Task {
            do {
                dataModel.systemError = nil
                dataModel.systemInited = false
                
                try await runHeadPositionTracking()
                dataModel.systemInited = true
            } catch {
                dataModel.systemError = error
            }
        }
    }
    func runHeadPositionTracking() async throws {
#if targetEnvironment(simulator)
        //The simulator can run head-tracking sessions without requiring permissions.
#else
        //Request head-tracking permissions on physical device.
        try await Task.sleep(for: .seconds(2))
        let result = await arSession.requestAuthorization(for: [.worldSensing])
        guard result[.worldSensing] == .allowed else {
            throw RunHeadPositionTrackingError.worldSensingPermissionNotAllowed
        }
#endif
        try await arSession.run([headPositionProvider])
    }
    enum RunHeadPositionTrackingError:Error,LocalizedError {
        case worldSensingPermissionNotAllowed
        var errorDescription: String? {
            switch self {
            case .worldSensingPermissionNotAllowed:
                "Please grant environmental awareness permissions for this app to use the Damping Follow feature."
            }
        }
    }
    //↑ This section initializes the head-following functionality.
    
    //↓ Check each frame whether the position of the follow view needs to be updated. If so, update the position with an animation.
    public func update(context: SceneUpdateContext) {
        guard dataModel.systemError == nil else {
            // Do not perform updates if the initialization has already failed.
            if let error = dataModel.systemError {
                os_log(.error,"【DampingFollowSystemError】\n\(error)")
            }
            return
        }
        guard dataModel.systemInited else {
            return
        }
        guard headPositionProvider.state == .running else {
            return
        }
       
        do {
            dataModel.systemError = nil
            let influentEntity = EntityQuery(where: .has(DampingFollowComponent.self))
            
            let entities = context.entities(matching: influentEntity, updatingSystemWhen: .rendering)
            try entities.forEach { entity in
                guard var component:DampingFollowComponent = entity.components[DampingFollowComponent.self] else {
                    throw UpdateError.realityKitInternalError
                }
                if  shouldDampingFollow(entity: entity, component: component) && shouldUpdate(component: component) {
                    
                    let headTransform = try getHeadTransform()
                    //写入新的MoveTime
                    component.lastMoveTime = .now
                    entity.components[DampingFollowComponent.self] = component
                    
                    try makeAnimation(entity: entity, compoment: component, targetPosition: newPosition(component: component, headTransform: headTransform), headPosition: headTransform.translation, sensitivityLevel: component.sensitivityLevel,timeDelta:context.deltaTime)
                }
            }
        } catch {
            dataModel.systemError = error
        }
    }
    //↑ Check each frame whether the position of the follow view needs to be updated. If so, update the position with an animation.
    
    
    func getHeadTransform() throws -> Transform {
        guard let headTransform4x4:simd_float4x4 = headPositionProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform else {
            throw UpdateError.failedToQueryHeadTransform
        }
        let headTransform = Transform(matrix: headTransform4x4)
        return headTransform
    }
    
    func newPosition(component:DampingFollowComponent,headTransform:Transform) throws -> SIMD3<Float> {
        let ray = headTransform.rayTo(direction: component.direction)
        let entityNewPosition = ray.pointAtLength(component.distance)
        return entityNewPosition
    }
    
    @MainActor
    func makeAnimation(
        entity:Entity,
        compoment:DampingFollowComponent,
        targetPosition:SIMD3<Float>,
        headPosition:SIMD3<Float>,
        sensitivityLevel:DampingFollowComponent.SensitivityLevel,
        timeDelta:TimeInterval
    ) throws {
        
        let targetTransform:Transform = .init(at: targetPosition, lookAt: headPosition)
        let animationDuration:TimeInterval = {
            if sensitivityLevel == .instant {
                return timeDelta
            } else {
                return sensitivityLevel.animationDuration
            }
        }()
        
        let dampingFollowAction = FromToByAction(
            from:entity.transform/*Update the entity’s position starting from its current value to avoid sudden jumps.*/,
            to: targetTransform,
            mode: .scene,
            timing: .easeOut/*Using .easeIn and .easeInOut causes bugs (on visionOS 2.1.1), resulting in very slow animation speeds. If you prefer not to use .easeOut, .linear works fine as well.*/,
            isAdditive: false
        )
        
        let dampingFollowAnimation = try AnimationResource
            .makeActionAnimation(for: dampingFollowAction, duration: animationDuration, bindTarget: .transform, repeatMode: .none, fillMode: .none, delay: 0, speed: 1)

        entity.playAnimation(dampingFollowAnimation, transitionDuration: 0)
    }
    

    func shouldDampingFollow(entity:Entity,component:DampingFollowComponent) -> Bool {
        if let followManager = component.followManager {
            return followManager.isFollow
        } else {
            return true
        }
    }
    
    
    func shouldUpdate(component:DampingFollowComponent) -> Bool {
        let lastMoveDate:Date? = component.lastMoveTime
        
        guard let lastMoveDate else {
            // Perform the initial follow after the component installation.
            return true
        }
        
        if component.sensitivityLevel == .instant {
            return true
        } else {
            
            let targetInterval:TimeInterval = component.sensitivityLevel.followFrequency
            if Date.now.timeIntervalSince(lastMoveDate) > targetInterval {
                return true
            } else {
                // The follow frequency will not exceed the value set in sensitivityLevel.
                return false
            }
        }
    }
    
    enum UpdateError:Error,LocalizedError {
        case realityKitInternalError
        case failedToQueryHeadTransform
        var errorDescription: String? {
            switch self {
            case .realityKitInternalError:
                "The entity component is missing—this could be due to a race condition or an issue with the EntityQuery."
            case .failedToQueryHeadTransform:
                "Unable to retrieve the current head position—this might be because the app is suspended."
            }
        }
    }
}

// Package internal helper struct.
struct MRRay {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
    
    /// 返回射线方向上距离原点 `length` 的点
    func pointAtLength(_ length: Float) -> SIMD3<Float> {
        return origin + direction * length
    }
}

extension Transform {
    /// Custom initializer to create a Transform at a specified position while ensuring the local X-axis lies on the XZ plane.
    /// - Parameters:
    ///   - position: The entity's position in world coordinates.
    ///   - lookAt: The target direction in world coordinates.
    init(at position: SIMD3<Float>, lookAt target: SIMD3<Float>) {
        let forward = (target - position).normalized
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = simd_cross(worldUp, forward).normalized
        let up = simd_cross(forward, right)
        let rotationMatrix = simd_float3x3(columns: (right, up, forward))
        let rotationQuaternion = simd_quatf(rotationMatrix)
        self.init(scale: SIMD3<Float>(1, 1, 1), rotation: rotationQuaternion, translation: position)
    }
}
extension SIMD3 where Scalar == Float {
    var normalized: SIMD3<Float> {
        return self / length(self)
    }
}

extension Transform {
    // Create a ray starting at Transform.translation and pointing in the specified direction.
    func rayTo(direction:SIMD3<Float>) -> MRRay {
        let transform = self
        let origin = transform.translation
        let direction = transform.rotation.act(direction)
        return MRRay(origin: origin, direction: normalize(direction))
    }
}
#endif
