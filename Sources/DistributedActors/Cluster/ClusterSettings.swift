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
import SWIM

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor System Cluster Settings

public struct ClusterSettings {
    public enum Default {
        public static let systemName: String = "ActorSystem"
        public static let bindHost: String = "127.0.0.1"
        public static let bindPort: Int = 7337
    }

    public static var `default`: ClusterSettings {
        let defaultNode = Node(systemName: Default.systemName, host: Default.bindHost, port: Default.bindPort)
        return ClusterSettings(node: defaultNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Connection establishment, protocol settings

    /// If `true` the ActorSystem start the cluster subsystem upon startup.
    /// The address bound to will be `bindAddress`.
    public var enabled: Bool = false

    /// Hostname used to accept incoming connections from other nodes
    public var bindHost: String {
        set {
            self.node.host = newValue
        }
        get {
            self.node.host
        }
    }

    /// Port used to accept incoming connections from other nodes
    public var bindPort: Int {
        set {
            self.node.port = newValue
        }
        get {
            self.node.port
        }
    }

    /// Node representing this node in the cluster.
    /// Note that most of the time `uniqueBindNode` is more appropriate, as it includes this node's unique id.
    public var node: Node

    /// `NodeID` to be used when exposing `UniqueNode` for node configured by using these settings.
    public var nid: UniqueNodeID

    // Reflects the bindAddress however carries an uniquely assigned UID.
    // The UID remains the same throughout updates of the `bindAddress` field.
    public var uniqueBindNode: UniqueNode {
        UniqueNode(node: self.node, nid: self.nid)
    }

    /// Time after which a the binding of the server port should fail
    public var bindTimeout: TimeAmount = .seconds(3)

    /// Timeout for unbinding the server port of this node (used when shutting down)
    public var unbindTimeout: TimeAmount = .seconds(3)

    /// Time after which a connection attempt will fail if no connection could be established
    public var connectTimeout: TimeAmount = .milliseconds(500)

    /// Backoff to be applied when attempting a new connection and handshake with a remote system.
    public var handshakeReconnectBackoff: BackoffStrategy = Backoff.exponential(
        initialInterval: .milliseconds(300),
        multiplier: 1.5,
        capInterval: .seconds(3),
        maxAttempts: 32
    )

    /// Defines the Time-To-Live of an association, i.e. when it shall be completely dropped from the tombstones list.
    /// An association ("unique connection identifier between two nodes") is kept as tombstone when severing a connection between nodes,
    /// in order to avoid accidental re-connections to given node. Once a node has been downed, removed, and disassociated, it MUST NOT be
    /// communicated with again. Tombstones are used to ensure this, even if the downed ("zombie") node, attempts to reconnect.
    public var associationTombstoneTTL: TimeAmount = .hours(24) * 1

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster protocol versioning

    /// `ProtocolVersion` to be used when exposing `UniqueNode` for node configured by using these settings.
    public var protocolVersion: DistributedActors.Version {
        self._protocolVersion
    }

    /// FOR TESTING ONLY: Exposed for testing handshake negotiation while joining nodes of different versions
    internal var _protocolVersion: DistributedActors.Version = DistributedActorsProtocolVersion

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster.Membership Gossip

    public var membershipGossipInterval: TimeAmount = .seconds(1)

    // since we talk to many peers one by one; even as we proceed to the next round after `membershipGossipInterval`
    // it is fine if we get a reply from the previously gossiped to peer after same or similar timeout. No rush about it.
    //
    // A missing ACK is not terminal, may happen, and we'll then gossip with that peer again (e.g. if it ha had some form of network trouble for a moment).
    public var membershipGossipAcknowledgementTimeout: TimeAmount = .seconds(1)

    public var membershipGossipIntervalRandomFactor: Double = 0.2

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Leader Election

    public var autoLeaderElection: LeadershipSelectionSettings = .lowestReachable(minNumberOfMembers: 2)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: TLS & Security settings

    /// If set, all communication with other nodes will be secured using TLS
    public var tls: TLSConfiguration?

    public var tlsPassphraseCallback: NIOSSLPassphraseCallback<[UInt8]>?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: NIO

    /// If set, this event loop group will be used by the cluster infrastructure.
    // TODO: do we need to separate server and client sides? Sounds like a reasonable thing to do.
    public var eventLoopGroup: EventLoopGroup?

    /// Unless the `eventLoopGroup` property is set, this function is used to create a new event loop group
    /// for the underlying NIO pipelines.
    public func makeDefaultEventLoopGroup() -> EventLoopGroup {
        MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) // TODO: share pool with others
    }

    public var receptionist: ClusterReceptionist.Settings = .default

    /// Allocator to be used for allocating byte buffers for coding/decoding messages.
    public var allocator: ByteBufferAllocator = NIO.ByteBufferAllocator()

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Cluster membership and failure detection

    /// Strategy how members determine if others (or myself) shall be marked as `.down`.
    /// This strategy should be set to the same (or compatible) strategy on all members of a cluster to avoid split brain situations.
    public var downingStrategy: DowningStrategySettings = .timeout(.default)

    /// When this member node notices it has been marked as `.down` in the membership, it can automatically perform an action.
    /// This setting determines which action to take. Generally speaking, the best course of action is to quickly and gracefully
    /// shut down the node and process, potentially leaving a higher level orchestrator to replace the node (e.g. k8s starting a new pod for the cluster).
    public var onDownAction: OnDownActionStrategySettings = .gracefulShutdown(delay: .seconds(3))

    /// Configures the SWIM cluster membership implementation (which serves as our failure detector).
    public var swim: SWIM.Settings

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Logging

    /// If enabled, logs membership changes (including the entire membership table from the perspective of the current node).
    public var logMembershipChanges: Logger.Level? = .debug

    /// When enabled traces _all_ incoming and outgoing cluster (e.g. handshake) protocol communication (remote messages).
    /// All logs will be prefixed using `[tracelog:cluster]`, for easier grepping.
    #if SACT_TRACE_CLUSTER
    public var traceLogLevel: Logger.Level? = .warning
    #else
    public var traceLogLevel: Logger.Level?
    #endif

    public init(node: Node, tls: TLSConfiguration? = nil) {
        self.node = node
        self.nid = UniqueNodeID.random()
        self.tls = tls
        self.swim = SWIM.Settings()
        self.swim.unreachability = .enabled
    }
}
