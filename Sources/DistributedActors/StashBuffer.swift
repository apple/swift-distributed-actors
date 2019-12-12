//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A `StashBuffer` allows messages that have been received, but can't be
/// processed right away to be temporarily stored and processed later on. One
/// use-case actors that have different states (i.e. changing behavior). Some
/// actors may require data to be fetched from external sources, before they
/// can start processing other messages, but because of the asynchronous nature
/// of actors, they can't be prevented from receiving messages while waiting for
/// the external source to respond. In this case messages should be stashed and
/// then unstashed once the external source has responded.
public final class StashBuffer<Message> {
    @usableFromInline
    let buffer: RingBuffer<Message>

    public init(capacity: Int) {
        self.buffer = RingBuffer(capacity: capacity)
    }

    public init(owner: ActorContext<Message>, capacity: Int) {
        // TODO: owner can be used to create metrics for the stash of specific owner
        self.buffer = RingBuffer(capacity: capacity)
    }

    /// Adds a message to the stash buffer, if the buffer is not full, otherwise
    /// throws `StashError.full`.
    ///
    /// - Parameter message: The message to be stored in the buffer
    /// - Throws: `StashError.full` when underlying stash would overflow its capacity
    @inlinable
    public func stash(message: Message) throws {
        guard self.buffer.offer(element: message) else {
            throw StashError.full
        }
    }

    /// Takes and returns first message from the stash buffer, if not empty.
    @inlinable
    public func take() -> Message? {
        self.buffer.take()
    }

    /// Unstashes all messages currently contained in the buffer and eagerly
    /// processes them with the given behavior. Behavior changes will be
    /// tracked, so if a message causes a behavior change, that behavior will be
    /// used for the following message. The current behavior after the last
    /// messages has been processed will be returned and can be used as the new
    /// behavior of the actor.
    ///
    /// Because of the eager processing of the messages, it is recommended to
    /// keep the stash small to prevent starvation of other actors while
    /// processing the stash.
    ///
    /// Messages can be stashed again during unstashing. Those messages will not
    /// be unstashed again in the same run.
    ///
    /// - Parameters:
    ///   - behavior: The behavior that will be used to process the messages
    ///   - context: The context of the surrounding actor. This is necessary
    ///              for the processing of the messages, e.g. when the behavior
    ///              requires the context to be passed in.
    /// - Throws: When any of the behavior reductions throws
    /// - Returns: The last behavior returned from processing the unstashed messages
    @inlinable
    public func unstashAll(context: ActorContext<Message>, behavior: Behavior<Message>) throws -> Behavior<Message> {
        // TODO: can we make this honor the run length like `Mailbox` does?
        var iterator = self.buffer.iterator
        let canonical = try context._downcastUnsafe.behavior.canonicalize(context, next: behavior)
        return try canonical.interpretMessages(context: context, messages: &iterator)
    }

    /// Returns count of currently stashed messages.
    /// Guaranteed to be lower or equal to `capacity` that the stash was initialized with.
    @inlinable
    public var count: Int {
        self.buffer.count
    }

    /// Returns boolean that indicates if the buffer is full.
    @inlinable
    public var isFull: Bool {
        self.buffer.isFull
    }
}

public enum StashError: Error {
    case full
    case empty
}
