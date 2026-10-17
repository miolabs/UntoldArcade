//
//  EyeTextures.swift
//  RealityKitPresenter spike
//
//  The routes of question 1 for handing the eye textures to RealityKit. Each gives the
//  material one TextureResource per eye and, once per frame on the main thread, the Metal
//  texture the render thread draws into for this ticket's command buffer.
//
//  Three routes: `LowLevelTexture.replace(using:)` (visionOS 2), and on visionOS 27 two
//  `LowLevelDeviceResource` forms toggled per frame: an IOSurface the app allocates (runs on
//  the device and in the simulator) and a Metal shared texture's handle, the plan's D2
//  fallback as written (device only: the simulator SDK marks `makeSharedTexture` and
//  `makeSharedTextureHandle` unavailable, the device SDK has them).
//

import CoreVideo
import IOSurface
import Metal
import RealityKit

enum EyeTextureError: Error, CustomStringConvertible {
    case deviceResourcesUnavailable
    case sharedTexturesSimulator
    case sharedTextureCreationFailed
    case surfaceCreationFailed
    case textureCreationFailed
    case noDevice

    var description: String {
        switch self {
        case .deviceResourcesUnavailable: return "LowLevelDeviceResource needs visionOS 27"
        case .sharedTexturesSimulator: return "Metal shared textures do not exist in the simulator"
        case .sharedTextureCreationFailed: return "makeSharedTexture / makeSharedTextureHandle gave nothing"
        case .surfaceCreationFailed: return "IOSurfaceCreate gave no surface"
        case .textureCreationFailed: return "MTLDevice.makeTexture(descriptor:iosurface:plane:) gave no texture"
        case .noDevice: return "No Metal device"
        }
    }
}

@MainActor
protocol EyeTextureRoute: AnyObject {
    var route: TextureRoute { get }
    var width: Int { get }
    var height: Int { get }
    var resources: [TextureResource] { get }
    /// Returns the textures to render into for this frame; RealityKit shows them when the
    /// command buffer completes.
    func beginFrame(commandBuffer: MTLCommandBuffer) -> [MTLTexture]
}

/// visionOS 2: LowLevelTexture.replace(using:) once per frame.
@MainActor
final class ReplaceTextureRoute: EyeTextureRoute {
    let route: TextureRoute = .replace
    let width: Int
    let height: Int
    let textures: [LowLevelTexture]
    let resources: [TextureResource]

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        var descriptor = LowLevelTexture.Descriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .bgra8Unorm_srgb
        descriptor.width = width
        descriptor.height = height
        descriptor.textureUsage = [.renderTarget, .shaderRead]
        let textures = try (0 ..< 2).map { _ in try LowLevelTexture(descriptor: descriptor) }
        self.textures = textures
        resources = try textures.map { try TextureResource(from: $0) }
    }

    func beginFrame(commandBuffer: MTLCommandBuffer) -> [MTLTexture] {
        textures.map { $0.replace(using: commandBuffer) }
    }
}

/// The per-frame toggle shared by the two device-resource routes: `slotCount` textures per
/// eye, each also known to RealityKit as a LowLevelDeviceResource; every frame the
/// LowLevelTexture is pointed at the next slot with replace(deviceResource:using:), so
/// RealityKit notices the new content without a copy (the pattern of Apple's
/// "Displaying low-latency connected video" sample).
@available(visionOS 27, *)
@MainActor
class DeviceResourceRouteBase {
    struct Slot {
        let texture: MTLTexture
        let resource: LowLevelDeviceResource
    }

    let width: Int
    let height: Int
    let slotCount: Int
    /// [eye][slot]
    let slots: [[Slot]]
    let lowLevelTextures: [LowLevelTexture]
    let resources: [TextureResource]
    private var nextSlot = 1

    init(width: Int, height: Int, slotCount: Int, makeSlot: (_ eye: Int, _ slot: Int, _ descriptor: MTLTextureDescriptor) throws -> Slot) throws {
        self.width = width
        self.height = height
        self.slotCount = slotCount
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        var slots: [[Slot]] = []
        for eye in 0 ..< 2 {
            var eyeSlots: [Slot] = []
            for slot in 0 ..< slotCount {
                let made = try makeSlot(eye, slot, descriptor)
                made.texture.label = "eye \(eye) slot \(slot)"
                eyeSlots.append(made)
            }
            slots.append(eyeSlots)
        }
        self.slots = slots
        let lowLevelTextures = try slots.map { try LowLevelTexture(deviceResource: $0[0].resource, using: nil) }
        self.lowLevelTextures = lowLevelTextures
        resources = try lowLevelTextures.map { try TextureResource(from: $0) }
    }

    func beginFrame(commandBuffer: MTLCommandBuffer) -> [MTLTexture] {
        let slot = nextSlot
        nextSlot = (nextSlot + 1) % slotCount
        for eye in 0 ..< 2 {
            lowLevelTextures[eye].replace(deviceResource: slots[eye][slot].resource, using: commandBuffer)
        }
        return slots.map { $0[slot].texture }
    }
}

/// visionOS 27: IOSurfaces the app allocates, seen twice: as a Metal texture we render into
/// and as the LowLevelDeviceResource RealityKit samples. Runs on the device and in the simulator.
@available(visionOS 27, *)
@MainActor
final class DeviceResourceTextureRoute: DeviceResourceRouteBase, EyeTextureRoute {
    let route: TextureRoute = .deviceResource

    init(device: MTLDevice, width: Int, height: Int, slotCount: Int = 2) throws {
        try super.init(width: width, height: height, slotCount: slotCount) { _, _, descriptor in
            descriptor.storageMode = .shared
            let properties: [CFString: Any] = [
                kIOSurfaceWidth: width,
                kIOSurfaceHeight: height,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
            ]
            guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
                throw EyeTextureError.surfaceCreationFailed
            }
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
                throw EyeTextureError.textureCreationFailed
            }
            let resource = try LowLevelDeviceResource(textureDescriptor: descriptor, iosurface: surface, plane: 0)
            return Slot(texture: texture, resource: resource)
        }
    }
}

#if !targetEnvironment(simulator)
/// visionOS 27, device only: Metal shared textures wrapped through their handles, the plan's
/// D2 fallback as written.
@available(visionOS 27, *)
@MainActor
final class SharedHandleTextureRoute: DeviceResourceRouteBase, EyeTextureRoute {
    let route: TextureRoute = .sharedHandle

    init(device: MTLDevice, width: Int, height: Int, slotCount: Int = 2) throws {
        try super.init(width: width, height: height, slotCount: slotCount) { _, _, descriptor in
            descriptor.storageMode = .private
            guard let texture = device.makeSharedTexture(descriptor: descriptor),
                  let handle = texture.makeSharedTextureHandle()
            else { throw EyeTextureError.sharedTextureCreationFailed }
            let resource = try LowLevelDeviceResource(sharedTextureHandle: handle)
            return Slot(texture: texture, resource: resource)
        }
    }
}
#endif
