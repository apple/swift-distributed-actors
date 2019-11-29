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

/// Allows obtaining actor references to XPC services.
/// Returned references may be used to send messages to the targeted services, treating XPC as a transport.
public struct XPCService {

    private let system: ActorSystem

    public init(_ system: ActorSystem) {
        self.system = system
    }

    /// Returns an `Actor` representing a reference to an XPC service with the passed in `serviceName`.
    ///
    /// No validation is performed about matching message type, nor the existence of the service synchronously.
    public func ref<Message>(_ type: Message.Type = Message.self, serviceName: String) throws -> ActorRef<Message> {
        // fake node; ensure that this does not get us in trouble; e.g. cluster trying to connect to this fake node etc
        let fakeNode = UniqueNode(protocol: "xpc", systemName: "", host: "localhost", port: 1, nid: .init(1))
        let targetAddress: ActorAddress = try ActorAddress(
            node: fakeNode,
            path: ActorPath([ActorPathSegment("xpc"), ActorPathSegment(serviceName)]),
            incarnation: .perpetual
        )

        // TODO: passing such ref over the network would fail; where should we prevent this?
        let xpcDelegate = try XPCServiceCellDelegate<Message>(
            system: self.system,
            address: targetAddress
        )

        return ActorRef<Message>(.delegate(xpcDelegate))
    }

    /// Returns an `Actor` representing a reference to an XPC service with the passed in `serviceName`.
    ///
    /// No validation is performed about matching message type, nor the existence of the service synchronously.
    ///
    /// In order to use this API, the service should be implemented as an `Actorable`.
    public func actor<A: Actorable>(_ actorableType: A.Type, serviceName: String) throws -> Actor<A> {
        let reference = try self.ref(A.Message.self, serviceName: serviceName)
        return Actor(ref: reference)
    }
}
