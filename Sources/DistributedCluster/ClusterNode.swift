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

import Distributed
import Foundation

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.Node

extension Cluster {
    /// A _unique_ node which includes also the node's unique `UID` which is used to disambiguate
    /// multiple incarnations of a system on the same host/port part -- similar to how an `ActorIncarnation`
    /// is used on the per-actor level.
    ///
    /// ### Implementation details
    /// The unique address of a remote node can only be obtained by performing the handshake with it.
    /// Once the remote node accepts our handshake, it offers the other node its unique address.
    /// Only once this address has been obtained can a node communicate with actors located on the remote node.
    public struct Node: Hashable, Sendable {
        public typealias ID = NodeID

        public var endpoint: Cluster.Endpoint
        public let nid: NodeID

        public init(endpoint: Cluster.Endpoint, nid: NodeID) {
            precondition(endpoint.port > 0, "port MUST be > 0")
            self.endpoint = endpoint
            self.nid = nid
        }

        public init(protocol: String, systemName: String, host: String, port: Int, nid: NodeID) {
            self.init(endpoint: Cluster.Endpoint(protocol: `protocol`, systemName: systemName, host: host, port: port), nid: nid)
        }

        public init(systemName: String, host: String, port: Int, nid: NodeID) {
            self.init(protocol: "sact", systemName: systemName, host: host, port: port, nid: nid)
        }

        public var systemName: String {
            set {
                self.endpoint.systemName = newValue
            }
            get {
                self.endpoint.systemName
            }
        }

        public var host: String {
            set {
                self.endpoint.host = newValue
            }
            get {
                self.endpoint.host
            }
        }

        public var port: Int {
            set {
                self.endpoint.port = newValue
            }
            get {
                self.endpoint.port
            }
        }
    }
}

extension Cluster.Node: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "\(self.endpoint)"
    }

    public var debugDescription: String {
        let a = self.endpoint
        return "\(a.protocol)://\(a.systemName):\(self.nid)@\(a.host):\(a.port)"
    }
}

extension Cluster.Node: Comparable {
    public static func == (lhs: Cluster.Node, rhs: Cluster.Node) -> Bool {
        // we first compare the NodeIDs since they're quicker to compare and for diff systems always would differ, even if on same physical address
        lhs.nid == rhs.nid && lhs.endpoint == rhs.endpoint
    }

    // Silly but good enough comparison for deciding "who is lower node"
    // as we only use those for "tie-breakers" any ordering is fine to be honest here.
    public static func < (lhs: Cluster.Node, rhs: Cluster.Node) -> Bool {
        if lhs.endpoint == rhs.endpoint {
            return lhs.nid < rhs.nid
        } else {
            return lhs.endpoint < rhs.endpoint
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: NodeID

extension Cluster.Node {
    public struct NodeID: Hashable, Sendable {
        let value: UInt64

        public init(_ value: UInt64) {
            self.value = value
        }
    }
}

extension Cluster.Node.ID: Comparable {
    public static func < (lhs: Cluster.Node.ID, rhs: Cluster.Node.ID) -> Bool {
        lhs.value < rhs.value
    }
}

extension Cluster.Node.ID: CustomStringConvertible {
    public var description: String {
        "\(self.value)"
    }
}

extension Cluster.Node.ID {
    public static func random() -> Cluster.Node.ID {
        Cluster.Node.ID(UInt64.random(in: 1 ... .max))
    }
}
