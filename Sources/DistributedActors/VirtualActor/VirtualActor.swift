//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Represents a reference to a "virtual" actor, which means that the actor may not (currently) exist in memory,
/// (or may have never existed _yet_), which will however be created upon the first message delivery to it.
///
/// A virtual actor MAY migrate transparently between nodes.
///
/// Delivery of messages upon node failure and/or re-balancing is best effort, and messages MAY be lost.
/// Same as with any other `ActorRef` if you need at-least-once delivery semantics, you need to build it into your message protocol.
// TODO: message deliveries and redeliveries we can build as helpers and make it even easier.
struct VirtualActorRef<Message>: ReceivesMessages {

    let identity: VirtualIdentity
    private let namespace: VirtualNamespace

    init(namespace: VirtualNamespace, identity: VirtualIdentity) {
        self.namespace = namespace
        self.identity = identity
    }

    func tell(_ message: Message, file: String, line: UInt) {
        let envelope = VirtualEnvelope(identity: self.identity, message: message, file: file, line: line)
        self.namespace.ref.tell(.forward(envelope))
    }
}

