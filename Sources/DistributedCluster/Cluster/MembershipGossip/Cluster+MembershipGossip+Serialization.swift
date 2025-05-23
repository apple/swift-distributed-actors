//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

extension Cluster.MembershipGossip: _ProtobufRepresentable {
    typealias ProtobufRepresentation = _ProtoClusterMembershipGossip

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = _ProtoClusterMembershipGossip()
        proto.ownerClusterNodeID = self.owner.nid.value
        proto.membership = try self.membership.toProto(context: context)

        // we manually ensure we encode using node identifiers, rather than full unique nodes to save space:
        var protoSeenTable = _ProtoClusterMembershipSeenTable()
        protoSeenTable.rows.reserveCapacity(self.seen.underlying.count)
        for (node, seenVersion) in self.seen.underlying {
            var row = _ProtoClusterMembershipSeenTableRow()
            row.nodeID = node.nid.value
            row.version = try seenVersion.toCompactReplicaNodeIDProto(context: context)
            protoSeenTable.rows.append(row)
        }
        proto.seenTable = protoSeenTable

        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.ownerClusterNodeID != 0 else {
            throw SerializationError(.missingField("ownerNodeID", type: "\(reflecting: Cluster.MembershipGossip.self)"))
        }
        guard proto.hasMembership else {
            throw SerializationError(.missingField("membership", type: "\(reflecting: Cluster.MembershipGossip.self)"))
        }
        guard proto.hasSeenTable else {
            throw SerializationError(.missingField("seenTable", type: "\(reflecting: Cluster.MembershipGossip.self)"))
        }

        let membership = try Cluster.Membership(fromProto: proto.membership, context: context)

        let ownerID = Cluster.Node.ID(proto.ownerClusterNodeID)
        guard let ownerNode = membership.member(byUniqueNodeID: ownerID)?.node else {
            throw SerializationError(.unableToDeserialize(hint: "Missing member for ownerNodeID, members: \(membership)"))
        }

        var gossip = Cluster.MembershipGossip(ownerNode: ownerNode)
        gossip.membership = membership
        gossip.seen.underlying.reserveCapacity(proto.seenTable.rows.count)
        for row in proto.seenTable.rows {
            let nodeID: Cluster.Node.ID = .init(row.nodeID)
            guard let member = membership.member(byUniqueNodeID: nodeID) else {
                throw SerializationError(.unableToDeserialize(hint: "Missing Member for unique node id: \(nodeID), members: \(membership)"))
            }

            var replicaVersions: [VersionVector.ReplicaVersion] = []
            replicaVersions.reserveCapacity(row.version.state.count)
            for protoReplicaVersion in row.version.state {
                let v: VersionVector.Version = protoReplicaVersion.version

                let replicaID: ReplicaID
                switch protoReplicaVersion.replicaID.value {
                case .some(.nodeID(let id)):
                    guard let member = membership.member(byUniqueNodeID: .init(id)) else {
                        continue
                    }
                    replicaID = .node(member.node)
                case .some(.node(let protoUniqueNode)):
                    replicaID = try .node(.init(fromProto: protoUniqueNode, context: context))
                case .some(.actorID(let address)):
                    context.log.warning("Unexpected .actorID key in replicaVersion of Cluster.MembershipGossip, which is expected to only use unique node ids as replica versions; was: \(address)")
                    continue
                case .none:
                    continue
                }

                replicaVersions.append(VersionVector.ReplicaVersion(replicaID: replicaID, version: v))
            }

            gossip.seen.underlying[member.node] = VersionVector(replicaVersions)
        }

        self = gossip
    }
}
