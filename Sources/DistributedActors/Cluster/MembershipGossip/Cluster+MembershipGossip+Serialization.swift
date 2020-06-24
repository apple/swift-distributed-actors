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

extension Cluster.MembershipGossip: ProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoClusterMembershipGossip

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtoClusterMembershipGossip()
        proto.ownerUniqueNodeID = self.owner.nid.value
        proto.membership = try self.membership.toProto(context: context)

        // we manually ensure we encode using node identifiers, rather than full unique nodes to save space:
        var protoSeenTable = ProtoClusterMembershipSeenTable()
        protoSeenTable.rows.reserveCapacity(self.seen.underlying.count)
        for (node, seenVersion) in self.seen.underlying {
            var row = ProtoClusterMembershipSeenTableRow()
            row.uniqueNodeID = node.nid.value
            row.version = try seenVersion.toCompactReplicaNodeIDProto(context: context)
            protoSeenTable.rows.append(row)
        }
        proto.seenTable = protoSeenTable

        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.ownerUniqueNodeID != 0 else {
            throw SerializationError.missingField("ownerUniqueNodeID", type: "\(reflecting: Cluster.MembershipGossip.self)")
        }
        guard proto.hasMembership else {
            throw SerializationError.missingField("membership", type: "\(reflecting: Cluster.MembershipGossip.self)")
        }
        guard proto.hasSeenTable else {
            throw SerializationError.missingField("seenTable", type: "\(reflecting: Cluster.MembershipGossip.self)")
        }

        let membership = try Cluster.Membership(fromProto: proto.membership, context: context)

        let ownerID = UniqueNodeID(proto.ownerUniqueNodeID)
        guard let ownerNode = membership.member(byUniqueNodeID: ownerID)?.node else {
            throw SerializationError.unableToDeserialize(hint: "Missing member for ownerUniqueNodeID, members: \(membership)")
        }

        var gossip = Cluster.MembershipGossip(ownerNode: ownerNode)
        gossip.membership = membership
        gossip.seen.underlying.reserveCapacity(proto.seenTable.rows.count)
        for row in proto.seenTable.rows {
            let nodeID: UniqueNodeID = .init(row.uniqueNodeID)
            guard let member = membership.member(byUniqueNodeID: nodeID) else {
                throw SerializationError.unableToDeserialize(hint: "Missing Member for unique node id: \(nodeID), members: \(membership)")
            }

            var replicaVersions: [VersionVector.ReplicaVersion] = []
            replicaVersions.reserveCapacity(row.version.state.count)
            for protoReplicaVersion in row.version.state {
                let replicaID: ReplicaID
                switch protoReplicaVersion.replicaID.value {
                case .some(.uniqueNodeID(let id)):
                    guard let member = membership.member(byUniqueNodeID: .init(id)) else {
                        throw SerializationError.unableToDeserialize(hint: "No member for nodeID \(id) in membership: \(membership)")
                    }
                    replicaID = .uniqueNode(member.node)
                case .some(.uniqueNode(let protoUniqueNode)):
                    replicaID = try .uniqueNode(.init(fromProto: protoUniqueNode, context: context))
                case .none, .some(.actorAddress):
                    throw SerializationError.unableToDeserialize(hint: "")
                }

                let v: VersionVector.Version = protoReplicaVersion.version
                replicaVersions.append(VersionVector.ReplicaVersion(replicaID: replicaID, version: v))
            }

            gossip.seen.underlying[member.node] = VersionVector(replicaVersions)
        }

        self = gossip
    }
}
