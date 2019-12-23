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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

import DistributedActors

/// Allows obtaining actor references to XPC services.
/// Returned references may be used to send messages to the targeted services, treating XPC as a transport.
public protocol XPCControl {
    /// Returns an `Actor` representing a reference to an XPC service with the passed in `serviceName`.
    ///
    /// No validation is performed about matching message type, nor the existence of the service synchronously.
    ///
    /// In order to use this API, the service should be implemented as an `Actorable`.
    func actor<A: Actorable>(_ actorableType: A.Type, serviceName: String) throws -> Actor<A>

    /// Returns an `ActorRef` representing a reference to an XPC service with the passed in `serviceName`.
    ///
    /// No validation is performed about matching message type nor the existence of the service synchronously,
    /// however attempts to use a non-existing service will result in a `XPCSignals.Invalidated`
    func ref<Message>(_ type: Message.Type, serviceName: String) throws -> ActorRef<Message>
}

#else
/// XPC is only available on Apple platforms
#endif
