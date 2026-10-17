//
//  PresenterRenderer.swift
//  RealityKitPresenter spike
//
//  The render thread: takes tickets, queries the head pose for the ticket's target time,
//  encodes the grid fill and the test pattern for both eyes into the ticket's command
//  buffer and commits it. Stands in for the engine's XR frame loop.
//

import Foundation
import Metal
import QuartzCore
import simd

final class PresenterRenderer: @unchecked Sendable {
    /// Half-angle tangents of the eye frustum: left, right, up, down. Wider than the
    /// headset's view, with the texture's aspect (1920 x 1824).
    static let tangents = SIMD4<Float>(1.30, 1.30, 1.15, 1.30)

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let fillGridPipeline: MTLComputePipelineState
    private let patternPipeline: MTLRenderPipelineState
    private let mailbox: TicketMailbox
    private let head: HeadTracker
    private let counters: SpikeCounters
    private let gridColumns: Int
    private let gridRows: Int
    private let textureWidth: Int
    private let textureHeight: Int
    private let startTime = CACurrentMediaTime()

    private let inFlightLock = NSLock()
    private var inFlight = 0

    init(device: MTLDevice, queue: MTLCommandQueue, mailbox: TicketMailbox, head: HeadTracker, counters: SpikeCounters,
         gridColumns: Int, gridRows: Int, textureWidth: Int, textureHeight: Int) throws
    {
        self.device = device
        self.queue = queue
        self.mailbox = mailbox
        self.head = head
        self.counters = counters
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight

        guard let library = device.makeDefaultLibrary() else {
            throw RendererError.noLibrary
        }
        guard let fillGrid = library.makeFunction(name: "fillGrid"),
              let vertexFunction = library.makeFunction(name: "fullscreenVertex"),
              let fragmentFunction = library.makeFunction(name: "patternFragment")
        else { throw RendererError.missingFunction }

        fillGridPipeline = try device.makeComputePipelineState(function: fillGrid)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "test pattern"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        patternPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    enum RendererError: Error, CustomStringConvertible {
        case noLibrary
        case missingFunction

        var description: String {
            switch self {
            case .noLibrary: return "No default Metal library in the bundle"
            case .missingFunction: return "A shader function is missing from the default library"
            }
        }
    }

    /// The thread body: runs until the mailbox is closed.
    func run() {
        while let ticket = mailbox.take() {
            render(ticket)
        }
    }

    private func render(_ ticket: FrameTicket) {
        let pickup = CACurrentMediaTime()
        let (pose, source) = head.originFromDevice(at: ticket.targetTime)
        // No pose yet (simulator before tracking, a fresh session): stand 1.5 m above the origin.
        let originFromDevice = pose ?? Self.translation(SIMD3<Float>(0, 1.5, 0))

        let commandBuffer = ticket.commandBuffer
        commandBuffer.label = "ticket \(ticket.serial)"

        for eye in 0 ..< 2 {
            var uniforms = makeUniforms(eye: eye, originFromDevice: originFromDevice, ticket: ticket)

            if eye < ticket.gridBuffers.count, let compute = commandBuffer.makeComputeCommandEncoder() {
                compute.label = "fill grid eye \(eye)"
                compute.setComputePipelineState(fillGridPipeline)
                compute.setBuffer(ticket.gridBuffers[eye], offset: 0, index: 0)
                compute.setBytes(&uniforms, length: MemoryLayout<SpikeFrameUniforms>.stride, index: 1)
                compute.dispatchThreads(
                    MTLSize(width: gridColumns, height: gridRows, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
                )
                compute.endEncoding()
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = ticket.eyeTextures[eye]
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let render = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                render.label = "pattern eye \(eye)"
                render.setRenderPipelineState(patternPipeline)
                render.setFragmentBytes(&uniforms, length: MemoryLayout<SpikeFrameUniforms>.stride, index: 0)
                render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                render.endEncoding()
            }
        }

        inFlightLock.lock()
        inFlight += 1
        let inFlightNow = inFlight
        inFlightLock.unlock()

        let committedAt = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { [counters, inFlightLock] buffer in
            inFlightLock.lock()
            self.inFlight -= 1
            inFlightLock.unlock()
            let gpu = max(buffer.gpuEndTime - buffer.gpuStartTime, 0)
            counters.noteCompletion(gpuSeconds: gpu, lagSeconds: CACurrentMediaTime() - committedAt)
        }
        commandBuffer.commit()

        counters.noteCommit(
            pickupAge: pickup - ticket.postedAt,
            encodeSeconds: committedAt - pickup,
            inFlight: inFlightNow,
            anchor: source
        )
    }

    private func makeUniforms(eye: Int, originFromDevice: simd_float4x4, ticket: FrameTicket) -> SpikeFrameUniforms {
        let settings = ticket.settings
        let offset = SIMD3<Float>(eye == 0 ? -settings.interpupillaryDistance / 2 : settings.interpupillaryDistance / 2, 0, 0)
        var uniforms = SpikeFrameUniforms()
        uniforms.originFromEye = originFromDevice * Self.translation(offset)
        uniforms.tangents = Self.tangents
        uniforms.gridSize = SIMD2<Float>(Float(gridColumns), Float(gridRows))
        uniforms.textureSize = SIMD2<Float>(Float(ticket.eyeTextures[eye].width), Float(ticket.eyeTextures[eye].height))
        uniforms.time = Float(ticket.targetTime - startTime)
        uniforms.eye = UInt32(eye)
        uniforms.patternMode = UInt32(settings.pattern.rawValue)
        uniforms.headLockedDistance = settings.headLockedDistance
        uniforms.farShell = settings.farShell
        uniforms.tearThreshold = settings.tearThreshold
        uniforms.flags = (settings.passthroughSky ? 1 : 0) | (settings.showOverlays ? 2 : 0)
        return uniforms
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }
}
