//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@_exported import Distributed
import struct Foundation.UUID

/// A distributed sequence is a way to communicate the element pulling semantics of a sequence/iterator over the network.
/// The actual data source is located on the remote side of this distributed sequence (which is a distributed actor), and dictates the semantics of the sequence.
///
/// Subscription semantics may differ from stream implementation to stream implementation, e.g. some may allow subscribing multiple times,
/// while others may allow only a single-pass and single "once" consumer.
///
/// Usually implementations will also have some form of timeout, after some amount of innactivity the sequence may tear itself down in order to conserve
/// resources. Please refer to the documentation of the `distributed method` returning (or accepting) a distributed sequence to learn about its expected semantics.
///
/// - SeeAlso:
///   - ``Swift/Sequence/distributed(using:)``
///   - ``Swift/AsyncSequence/distributed(using:)``
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
public protocol DistributedSequence<Element, ActorSystem>: DistributedActor, Codable, AsyncSequence
    where Element: Sendable & Codable, ActorSystem: DistributedActorSystem<any Codable> {   }

// TODO: make Failure generic as well

extension Sequence where Element: Sendable & Codable {
    
    /// Produce a ``DistributedSequence`` of this ``Swift/Sequence`` which may be passed to `distributed` methods.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    public func distributed<ActorSystem>(using actorSystem: ActorSystem) -> some DistributedSequence<Element, ActorSystem>
    where ActorSystem: DistributedActorSystem<any Codable>, ActorSystem.ActorID: Sendable & Codable {
        DistributedSequenceImpl(self, actorSystem: actorSystem)
    }
}

// TODO: Implement also for throwing AsyncSequence
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
extension AsyncSequence where Element: Sendable & Codable, Failure == Never {
    
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    public func distributed<ActorSystem>(using actorSystem: ActorSystem) -> some DistributedSequence<Element, ActorSystem>
    where ActorSystem: DistributedActorSystem<any Codable>, ActorSystem.ActorID: Sendable & Codable {
        DistributedSequenceImpl(self, actorSystem: actorSystem)
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
public distributed actor DistributedSequenceImpl<Element, AS> : DistributedSequence
        where Element: Sendable & Codable,
              AS: DistributedActorSystem<any Codable>,
              AS.ActorID: Codable {
    public typealias ActorSystem = AS
    public typealias Failure = any Error
    
    
    let elements: any AsyncSequence<Element, Never> // non throwing sequence for now; need to support either
    
    /// Active iterators for given subscriber UUID
    // TODO: these should be reaped on a timeout, if a value is not consumed for a long time
    var consumers: [UUID: any AsyncIteratorProtocol<Element, Never>]
    
    /// Initialize this type using the helper .distributed() function on ``Sequence``
    internal init<Seq: Sequence>(
        _ elements: Seq,
        actorSystem: AS
    ) where Seq.Element == Element {
        self.init(elements.async, actorSystem: actorSystem)
    }
    
    /// Initialize this type using the helper .distributed() function on ``Sequence``
    internal init<Seq: AsyncSequence>(
        _ elements: Seq,
        actorSystem: ActorSystem
    ) where Seq.Element == Element, Seq.Failure == Never {
        self.elements = elements
        self.consumers = [:]
        self.actorSystem = actorSystem
    }
    
    distributed func getNext(_ subscriber: UUID) async throws -> Element? {
        print("getNext(\(subscriber)")
        // However you want to implement getting "next" elements from the underlying stream,
        // if we had multiple subscribers, does each get an element round-robin, everyone gets their own subscription, or do we reject multiple consumers etc.
        if var iter = consumers[subscriber] {
            let element = try? await iter.next() // FIXME: propagate the error anc cancel the sub if throws
            if element == nil {
                // end of stream, no need to keep the
                consumers[subscriber] = nil
            }
            consumers[subscriber] = iter
            
            return element
        } else {
            var iter = self.elements.makeAsyncIterator()
            consumers[subscriber] = iter
            
            let element = try? await iter.next() // FIXME: propagate the error anc cancel the sub if throws
            if element == nil {
                // end of stream, no need to keep the
                consumers[subscriber] = nil
            }
            consumers[subscriber] = iter

            return element
        }
    }
    
    distributed func cancel(_ subscriber: UUID) async throws {
        print("cancel(\(subscriber)")
        self.consumers[subscriber] = nil
    }
    
    public nonisolated func makeAsyncIterator() -> AsyncIterator {
        print("make async iterator (\(self)")
        return .init(ref: self)
    }
    
    final public class AsyncIterator: AsyncIteratorProtocol {
        let ref: DistributedSequenceImpl<Element, ActorSystem>
        let uuid: UUID
        
        init(ref: DistributedSequenceImpl<Element, ActorSystem>) {
            self.ref = ref
            self.uuid = UUID()
        }
        
        public func next() async throws -> Element? {
            print("Iterator/next")
            return try await ref.getNext(self.uuid)
        }
        
        deinit {
            Task.detached { [ref, uuid] in
                try await ref.cancel(uuid)
            }
        }
        
    }
    
    
}
