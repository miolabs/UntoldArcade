//
//  TicketMailbox.swift
//  RealityKitPresenter spike
//
//  The main thread posts one ticket per RealityKit frame; the render thread takes it.
//  A ticket carries a command buffer that already had replace(using:) and
//  replace(bufferIndex:using:) called on it, so it must be committed: when the render
//  thread has not taken the previous ticket yet, the main thread posts nothing for that
//  frame and counts a dropped ticket instead of replacing the pending one.
//

import Foundation
import Metal

struct FrameTicket {
    let serial: UInt64
    let commandBuffer: MTLCommandBuffer
    /// [left, right]
    let eyeTextures: [MTLTexture]
    /// [left, right]
    let gridBuffers: [MTLBuffer]
    /// CACurrentMediaTime when posted.
    let postedAt: TimeInterval
    /// The time the frame is meant for: postedAt + lead; the device anchor is queried for it.
    let targetTime: TimeInterval
    let leadSeconds: Double
    let settings: RenderSettingsSnapshot
}

final class TicketMailbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: FrameTicket?
    private var closed = false

    var hasPending: Bool {
        condition.lock(); defer { condition.unlock() }
        return pending != nil
    }

    /// Posts when nothing is pending; returns false otherwise (the caller counts a drop).
    func post(_ ticket: FrameTicket) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard pending == nil, !closed else { return false }
        pending = ticket
        condition.signal()
        return true
    }

    /// Blocks until a ticket is posted; nil once closed.
    func take() -> FrameTicket? {
        condition.lock(); defer { condition.unlock() }
        while pending == nil && !closed {
            condition.wait()
        }
        let ticket = pending
        pending = nil
        return ticket
    }

    /// Ends the render loop; a pending ticket is committed empty so RealityKit's bookkeeping completes.
    func close() {
        condition.lock()
        closed = true
        let leftover = pending
        pending = nil
        condition.broadcast()
        condition.unlock()
        leftover?.commandBuffer.commit()
    }
}
