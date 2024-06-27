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
// MARK: Cluster.Endpoint

extension Cluster {
    /// An `Endpoint` is a triplet of protocol, host and port that a node is bound to.
    ///
    /// Unlike `Cluster.Node`, it does not carry identity (`Cluster.Node.ID`) of a specific incarnation of an actor system node,
    /// and represents an address of _any_ node that could live under this address. During the handshake process between two nodes,
    /// the remote `Node` that the local side started out to connect with is "upgraded" to a `Cluster.Node`, as soon as we discover
    /// the remote side's unique node identifier (`Cluster.Node.ID`).
    ///
    /// ### System name / human readable name
    /// The `systemName` is NOT taken into account when comparing nodes. The system name is only utilized for human readability
    /// and debugging purposes and participates neither in hashcode nor equality of a `Node`, as a node specifically is meant
    /// to represent any unique node that can live on specific host & port. System names are useful for human operators,
    /// intending to use some form of naming scheme, e.g. adopted from a cloud provider, to make it easier to map nodes in
    /// actor system logs, to other external systems.
    ///
    /// - SeeAlso: For more details on unique node ids, refer to: ``Cluster/Node-struct``.
    public struct Endpoint: Hashable, Sendable {
        // TODO: collapse into one String and index into it?
        public var `protocol`: String
        public var systemName: String // TODO: some other name, to signify "this is just for humans"?
        public var host: String
        public var port: Int

        public init(protocol: String, systemName: String, host: String, port: Int) {
            precondition(port > 0, "port MUST be > 0")
            self.protocol = `protocol`
            self.systemName = systemName
            self.host = host
            self.port = port
        }

        public init(systemName: String, host: String, port: Int) {
            self.init(protocol: "sact", systemName: systemName, host: host, port: port)
        }

        public init(host: String, port: Int) {
            self.init(protocol: "sact", systemName: "", host: host, port: port)
        }
    }
}

extension Cluster.Endpoint: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "\(self.protocol)://\(self.systemName)@\(self.host):\(self.port)"
    }

    public var debugDescription: String {
        self.description
    }
}

extension Cluster.Endpoint: Comparable {
    // Silly but good enough comparison for deciding "who is lower node"
    // as we only use those for "tie-breakers" any ordering is fine to be honest here.
    public static func < (lhs: Cluster.Endpoint, rhs: Cluster.Endpoint) -> Bool {
        "\(lhs.protocol)\(lhs.host)\(lhs.port)" < "\(rhs.protocol)\(rhs.host)\(rhs.port)"
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.protocol)
        hasher.combine(self.host)
        hasher.combine(self.port)
    }

    public static func == (lhs: Cluster.Endpoint, rhs: Cluster.Endpoint) -> Bool {
        lhs.protocol == rhs.protocol && lhs.host == rhs.host && lhs.port == rhs.port
    }
}
