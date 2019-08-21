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

import Logging
import NIO
import NIOSSL

// ==== ----------------------------------------------------------------------------------------------------------------

// MARK: Actor System Cluster Settings

public struct ClusterSettings {
    public enum Default {
        public static let systemName: String = "ActorSystem"
        public static let bindHost: String = "localhost"
        public static let bindPort: Int = 7337
    }

    public static var `default`: ClusterSettings {
        let defaultNode = Node(systemName: Default.systemName, host: Default.bindHost, port: Default.bindPort)
        return ClusterSettings(node: defaultNode)
    }

    /// If `true` the ActorSystem start the cluster subsystem upon startup.
    /// The address bound to will be `bindAddress`.
    public var enabled: Bool = false

    /// Hostname used to accept incoming connections from other nodes
    public var bindHost: String {
        set {
            self.node.host = newValue
        }
        get {
            return self.node.host
        }
    }

    /// Port used to accept incoming connections from other nodes
    public var bindPort: Int {
        set {
            self.node.port = newValue
        }
        get {
            return self.node.port
        }
    }

    public var node: Node

    // Reflects the bindAddress however carries an uniquely assigned UID.
    // The UID remains the same throughout updates of the `bindAddress` field.
    public var uniqueBindNode: UniqueNode {
        return UniqueNode(node: self.node, nid: self.nid)
    }

    /// Backoff to be applied when attempting a new connection and handshake with a remote system.
    public var handshakeBackoffStrategy: BackoffStrategy = Backoff.constant(.milliseconds(100))

    /// `NodeID` to be used when exposing `UniqueNode` for node configured by using these settings.
    public var nid: NodeID

    /// If set, all communication with other nodes will be secured using TLS
    public var tls: TLSConfiguration?

    public var tlsPassphraseCallback: NIOSSLPassphraseCallback<[UInt8]>?

    /// `ProtocolVersion` to be used when exposing `UniqueNode` for node configured by using these settings.
    public var protocolVersion: DistributedActors.Version {
        return self._protocolVersion
    }

    // Exposed for testing handshake negotiation while joining nodes of different versions
    internal var _protocolVersion: DistributedActors.Version = DistributedActorsProtocolVersion

    /// If set, this event loop group will be used by the cluster infrastructure.
    // TODO: do we need to separate server and client sides? Sounds like a reasonable thing to do.
    public var eventLoopGroup: EventLoopGroup?

    // TODO: Can be removed once we have an implementation based on CRDTs with more robust replication
    /// Interval with which the receptionists will sync their state with the other nodes.
    public var receptionistSyncInterval: TimeAmount = .seconds(5)

    /// Unless the `eventLoopGroup` property is set, this function is used to create a new event loop group
    /// for the underlying NIO pipelines.
    public func makeDefaultEventLoopGroup() -> EventLoopGroup {
        return MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) // TODO: share pool with others
    }

    /// Allocator to be used for allocating byte buffers for coding/decoding messages.
    public var allocator: ByteBufferAllocator = NIO.ByteBufferAllocator()

    // ==== ----------------------------------------------------------------------------------------------------------------

    // MARK: Cluster membership and failure detection

    public var downingStrategy: DowningStrategySettings = .noop

    /// Configures the SWIM failure failure detector.
    public var swim: SWIM.Settings = .default

    // ==== ------------------------------------------------------------------------------------------------------------

    // MARK: Logging

    /// If enabled, logs membership changes (including the entire membership table from the perspective of the current node).
    public var logMembershipChanges: Logger.Level? = .info

    /// When enabled traces _all_ incoming and outgoing cluster (e.g. handshake) protocol communication (remote messages).
    /// All logs will be prefixed using `[tracelog:cluster]`, for easier grepping.
    #if SACT_TRACE_CLUSTER
    var traceLogLevel: Logger.Level? = .warning
    #else
    var traceLogLevel: Logger.Level?
    #endif

    public init(node: Node, tls: TLSConfiguration? = nil) {
        self.node = node
        self.nid = NodeID.random()
        self.tls = tls
    }
}

public enum DowningStrategySettings {
    case noop
    case timeout(TimeoutBasedDowningStrategySettings)
}
