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

import NIO

// Actors engage in 'Networking' - the process of interacting with others to exchange information and develop contacts.

// MARK: Actor System Remoting Settings

public struct RemotingSettings {

    public enum Default {
        public static let systemName: String = "ActorSystem"
        public static let host: String = "127.0.0.1"
        public static let port: Int = 7337
    }

    public static var `default`: RemotingSettings {
        let defaultBindAddress: NodeAddress = .init(systemName: Default.systemName, host: Default.host, port: Default.port)
        return RemotingSettings(bindAddress: defaultBindAddress)
    }

    /// If `true` the ActorSystem start the remoting subsystem upon startup.
    /// The remoting address bound to will be `bindAddress`.
    public var enabled: Bool = false

    /// If set to a non-`nil` value, the system will attempt to bind to the provided address on startup.
    /// Once bound, the system is able to accept incoming connections.
    ///
    /// Changing the address preserves the systems `Remote.NodeUID`.
    public var bindAddress: NodeAddress

    /// `NodeUID` to be used when exposing `UniqueNodeAddress` for node configured by using these settings.
    public var uid: NodeUID

    /// `ProtocolVersion` to be used when exposing `UniqueNodeAddress` for node configured by using these settings.
    public var protocolVersion: Swift Distributed ActorsActor.Version {
        return self._protocolVersion
    }
    // exposed for testing handshake negotiation while joining nodes of different versions
    internal var _protocolVersion: Swift Distributed ActorsActor.Version = DistributedActorsProtocolVersion

    // Reflects the bindAddress however carries an uniquely assigned UID.
    // The UID remains the same throughout updates of the `bindAddress` field.
    public var uniqueBindAddress: UniqueNodeAddress {
        return UniqueNodeAddress(address: self.bindAddress, uid: self.uid)
    }

    /// If set, this event loop group will be used by the remoting infrastructure.
    // TODO do we need to separate server and client sides? Sounds like a reasonable thing to do.
    public var eventLoopGroup: EventLoopGroup? = nil

    /// Unless the `eventLoopGroup` property is set, this function is used to create a new event loop group
    /// for the underlying NIO pipelines.
    public func makeDefaultEventLoopGroup() -> EventLoopGroup {
        return MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) // TODO share pool with others
    }

    /// Allocator to be used for allocating byte buffers for coding/decoding messages.
    public var allocator: ByteBufferAllocator = NIO.ByteBufferAllocator()

    public init(bindAddress: NodeAddress) {
        self.bindAddress = bindAddress
        self.uid = NodeUID.random()
    }
}
