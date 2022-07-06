//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership Testing DSL

extension Cluster.MembershipGossip {
    /// First line is Membership DSL, followed by lines of the SeenTable DSL
    static func parse(_ dsl: String, owner: UniqueNode, nodes: [UniqueNode]) -> Cluster.MembershipGossip {
        let dslLines = dsl.split(separator: "\n")
        var gossip = Cluster.MembershipGossip(ownerNode: owner)
        gossip.membership = Cluster.Membership.parse(String(dslLines.first!), nodes: nodes)
        gossip.seen = Cluster.MembershipGossip.SeenTable.parse(dslLines.dropFirst().joined(separator: "\n"), nodes: nodes)
        return gossip
    }
}

extension Cluster.MembershipGossip.SeenTable {
    /// Express seen tables using a DSL
    /// Syntax: each line: `<owner>: <node>@<version>*`
    static func parse(_ dslString: String, nodes: [UniqueNode], file: StaticString = #file, line: UInt = #line) -> Cluster.MembershipGossip.SeenTable {
        let lines = dslString.split(separator: "\n")
        func nodeById(id: String.SubSequence) -> UniqueNode {
            if let found = nodes.first(where: { $0.node.systemName.contains(id) }) {
                return found
            } else {
                fatalError("Could not find node containing [\(id)] in \(nodes), for seen table: \(dslString)", file: file, line: line)
            }
        }

        var table = Cluster.MembershipGossip.SeenTable()

        for line in lines {
            let elements = line.split(separator: " ")
            let id = elements.first!.dropLast(1)
            let on = nodeById(id: id)

            var vv = VersionVector.empty
            for dslVersion in elements.dropFirst() {
                let parts = dslVersion.split { c in "@:".contains(c) }

                let atId = parts.first!
                let atNode = nodeById(id: atId)

                let versionString = parts.dropFirst().first!
                let atVersion = UInt64(versionString)!

                vv.state[.uniqueNode(atNode)] = atVersion
            }

            table.underlying[on] = vv
        }

        return table
    }
}

extension VersionVector {
    static func parse(_ dslString: String, nodes: [UniqueNode], file: StaticString = #file, line: UInt = #line) -> VersionVector {
        func nodeById(id: String.SubSequence) -> UniqueNode {
            if let found = nodes.first(where: { $0.node.systemName.contains(id) }) {
                return found
            } else {
                fatalError("Could not find node containing [\(id)] in \(nodes), for seen table: \(dslString)", file: file, line: line)
            }
        }

        let replicaVersions: [VersionVector.ReplicaVersion] = dslString.split(separator: " ").map { segment in
            let v = segment.split { c in ":@".contains(c) }
            return (.uniqueNode(nodeById(id: v.first!)), VersionVector.Version(v.dropFirst().first!)!)
        }
        return VersionVector(replicaVersions)
    }
}

extension Cluster.Membership {
    /// Express membership as: `F.up S.down T.joining`.
    ///
    /// Syntax reference:
    ///
    /// ```
    /// <node identifier>[.:]<node status> || [leader:<node identifier>]
    /// ```
    static func parse(_ dslString: String, nodes: [UniqueNode], file: StaticString = #file, line: UInt = #line) -> Cluster.Membership {
        func nodeById(id: String.SubSequence) -> UniqueNode {
            if let found = nodes.first(where: { $0.node.systemName.contains(id) }) {
                return found
            } else {
                fatalError("Could not find node containing [\(id)] in \(nodes), for seen table: \(dslString)", file: file, line: line)
            }
        }

        var membership = Cluster.Membership.empty

        for nodeDsl in dslString.split(separator: " ") {
            let elements = nodeDsl.split { c in ".:".contains(c) }
            let nodeId = elements.first!
            if nodeId == "[leader" {
                // this is hacky, but good enough for our testing tools
                let actualNodeId = elements.dropFirst().first!
                let leaderNode = nodeById(id: actualNodeId.dropLast(1))
                let leaderMember = membership.uniqueMember(leaderNode)!
                membership.leader = leaderMember
            } else {
                let node = nodeById(id: nodeId)

                let statusString = String(elements.dropFirst().first!)
                let status = Cluster.MemberStatus.parse(statusString)!

                membership._members[node] = Cluster.Member(node: node, status: status)
            }
        }

        return membership
    }
}

extension Cluster.MemberStatus {
    /// Not efficient but useful for constructing mini DSLs to write membership
    static func parse(_ s: String) -> Cluster.MemberStatus? {
        let id = String(s.trimmingCharacters(in: .symbols))
        for c in Self.allCases where id == "\(c)" {
            return c
        }

        return nil
    }
}
