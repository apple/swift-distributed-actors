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
import NIOSSL

// Actors engage in 'Networking' - the process of interacting with others to exchange information and develop contacts.

// MARK: Actor System Remoting Settings

public struct RemotingSettings {

    public enum Default {
        public static let systemName: String = "ActorSystem"
        public static let host: String = "localhost"
        public static let port: Int = 7337
        public static let failureDetector: FailureDetectorSettings = .manual
    }

    public static var `default`: RemotingSettings {
        let defaultBindAddress: NodeAddress = .init(systemName: Default.systemName, host: Default.host, port: Default.port)
        let failureDetector = Default.failureDetector
        return RemotingSettings(bindAddress: defaultBindAddress, failureDetector: failureDetector)
    }

    /// If `true` the ActorSystem start the remoting subsystem upon startup.
    /// The remoting address bound to will be `bindAddress`.
    public var enabled: Bool = false

    /// If set to a non-`nil` value, the system will attempt to bind to the provided address on startup.
    /// Once bound, the system is able to accept incoming connections.
    ///
    /// Changing the address preserves the systems `Remote.NodeUID`.
    public var bindAddress: NodeAddress

    // Reflects the bindAddress however carries an uniquely assigned UID.
    // The UID remains the same throughout updates of the `bindAddress` field.
    public var uniqueBindAddress: UniqueNodeAddress {
        return UniqueNodeAddress(address: self.bindAddress, uid: self.uid)
    }

    /// `NodeUID` to be used when exposing `UniqueNodeAddress` for node configured by using these settings.
    public var uid: NodeUID

    /// If set, all communication with other nodes will be secured using TLS
    public var tls: TLSConfiguration?

    public var tlsPassphraseCallback: NIOSSLPassphraseCallback<[UInt8]>?

    /// `ProtocolVersion` to be used when exposing `UniqueNodeAddress` for node configured by using these settings.
    public var protocolVersion: Swift Distributed ActorsActor.Version {
        return self._protocolVersion
    }
    // exposed for testing handshake negotiation while joining nodes of different versions
    internal var _protocolVersion: Swift Distributed ActorsActor.Version = DistributedActorsProtocolVersion

    /// If set, this event loop group will be used by the remoting infrastructure.
    // TODO do we need to separate server and client sides? Sounds like a reasonable thing to do.
    public var eventLoopGroup: EventLoopGroup? = nil

    /// Configure what failure detector to use.
    // TODO: Since it MAY have specific requirements on other settings... we may want to allow it to run a validation after creation?
    public var failureDetector: FailureDetectorSettings
    internal func makeFailureDetector(system: ActorSystem) -> FailureDetector {
        let context = FailureDetectorContext(system)

        switch self.failureDetector {
        case .manual:
            return ManualFailureDetector(context: context)
        }
    }

    /// Unless the `eventLoopGroup` property is set, this function is used to create a new event loop group
    /// for the underlying NIO pipelines.
    public func makeDefaultEventLoopGroup() -> EventLoopGroup {
        return MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) // TODO share pool with others
    }

    /// Allocator to be used for allocating byte buffers for coding/decoding messages.
    public var allocator: ByteBufferAllocator = NIO.ByteBufferAllocator()

    public init(bindAddress: NodeAddress, failureDetector: FailureDetectorSettings, tls: TLSConfiguration? = nil) {
        self.bindAddress = bindAddress
        self.uid = NodeUID.random()
        self.failureDetector = failureDetector
        self.tls = tls
    }
}

public enum FailureDetectorSettings {
    case manual
    // case instance(FailureDetector) // TODO: once we decide to allow users implementing their own
}
