// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: Cluster/Membership.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

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

import Foundation
import SwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

public enum _ProtoClusterMemberReachability: SwiftProtobuf.Enum {
  public typealias RawValue = Int
  case unspecified // = 0
  case reachable // = 1
  case unreachable // = 2
  case UNRECOGNIZED(Int)

  public init() {
    self = .unspecified
  }

  public init?(rawValue: Int) {
    switch rawValue {
    case 0: self = .unspecified
    case 1: self = .reachable
    case 2: self = .unreachable
    default: self = .UNRECOGNIZED(rawValue)
    }
  }

  public var rawValue: Int {
    switch self {
    case .unspecified: return 0
    case .reachable: return 1
    case .unreachable: return 2
    case .UNRECOGNIZED(let i): return i
    }
  }

}

#if swift(>=4.2)

extension _ProtoClusterMemberReachability: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  public static var allCases: [_ProtoClusterMemberReachability] = [
    .unspecified,
    .reachable,
    .unreachable,
  ]
}

#endif  // swift(>=4.2)

public enum _ProtoClusterMemberStatus: SwiftProtobuf.Enum {
  public typealias RawValue = Int
  case unspecified // = 0
  case joining // = 1
  case up // = 2
  case down // = 3
  case leaving // = 4
  case removed // = 5
  case UNRECOGNIZED(Int)

  public init() {
    self = .unspecified
  }

  public init?(rawValue: Int) {
    switch rawValue {
    case 0: self = .unspecified
    case 1: self = .joining
    case 2: self = .up
    case 3: self = .down
    case 4: self = .leaving
    case 5: self = .removed
    default: self = .UNRECOGNIZED(rawValue)
    }
  }

  public var rawValue: Int {
    switch self {
    case .unspecified: return 0
    case .joining: return 1
    case .up: return 2
    case .down: return 3
    case .leaving: return 4
    case .removed: return 5
    case .UNRECOGNIZED(let i): return i
    }
  }

}

#if swift(>=4.2)

extension _ProtoClusterMemberStatus: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  public static var allCases: [_ProtoClusterMemberStatus] = [
    .unspecified,
    .joining,
    .up,
    .down,
    .leaving,
    .removed,
  ]
}

#endif  // swift(>=4.2)

public struct _ProtoClusterMembership {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var members: [_ProtoClusterMember] = []

  public var leaderNode: _ProtoUniqueNode {
    get {return _leaderNode ?? _ProtoUniqueNode()}
    set {_leaderNode = newValue}
  }
  /// Returns true if `leaderNode` has been explicitly set.
  public var hasLeaderNode: Bool {return self._leaderNode != nil}
  /// Clears the value of `leaderNode`. Subsequent reads from it will return its default value.
  public mutating func clearLeaderNode() {self._leaderNode = nil}

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _leaderNode: _ProtoUniqueNode? = nil
}

public struct _ProtoClusterMember {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var node: _ProtoUniqueNode {
    get {return _node ?? _ProtoUniqueNode()}
    set {_node = newValue}
  }
  /// Returns true if `node` has been explicitly set.
  public var hasNode: Bool {return self._node != nil}
  /// Clears the value of `node`. Subsequent reads from it will return its default value.
  public mutating func clearNode() {self._node = nil}

  public var status: _ProtoClusterMemberStatus = .unspecified

  public var reachability: _ProtoClusterMemberReachability = .unspecified

  public var upNumber: UInt32 = 0

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _node: _ProtoUniqueNode? = nil
}

public struct _ProtoClusterMembershipGossip {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// Membership contains full UniqueNode renderings, and the owner and seen table refer to them by UniqueNode.ID
  /// this saves us space (by avoiding to render the unique node explicitly many times for each member/seen-entry).
  public var membership: _ProtoClusterMembership {
    get {return _membership ?? _ProtoClusterMembership()}
    set {_membership = newValue}
  }
  /// Returns true if `membership` has been explicitly set.
  public var hasMembership: Bool {return self._membership != nil}
  /// Clears the value of `membership`. Subsequent reads from it will return its default value.
  public mutating func clearMembership() {self._membership = nil}

  /// The following fields will use compressed UniqueNode encoding and ONLY serialize them as their uniqueNodeID.
  /// During deserialization the fields can be resolved against the membership to obtain full UniqueNode values if necessary.
  public var ownerUniqueNodeID: UInt64 = 0

  public var seenTable: _ProtoClusterMembershipSeenTable {
    get {return _seenTable ?? _ProtoClusterMembershipSeenTable()}
    set {_seenTable = newValue}
  }
  /// Returns true if `seenTable` has been explicitly set.
  public var hasSeenTable: Bool {return self._seenTable != nil}
  /// Clears the value of `seenTable`. Subsequent reads from it will return its default value.
  public mutating func clearSeenTable() {self._seenTable = nil}

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _membership: _ProtoClusterMembership? = nil
  fileprivate var _seenTable: _ProtoClusterMembershipSeenTable? = nil
}

public struct _ProtoClusterMembershipSeenTable {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var rows: [_ProtoClusterMembershipSeenTableRow] = []

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}
}

public struct _ProtoClusterMembershipSeenTableRow {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var uniqueNodeID: UInt64 = 0

  public var version: _ProtoVersionVector {
    get {return _version ?? _ProtoVersionVector()}
    set {_version = newValue}
  }
  /// Returns true if `version` has been explicitly set.
  public var hasVersion: Bool {return self._version != nil}
  /// Clears the value of `version`. Subsequent reads from it will return its default value.
  public mutating func clearVersion() {self._version = nil}

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _version: _ProtoVersionVector? = nil
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension _ProtoClusterMemberReachability: SwiftProtobuf._ProtoNameProviding {
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    0: .same(proto: "CLUSTER_MEMBER_REACHABILITY_UNSPECIFIED"),
    1: .same(proto: "CLUSTER_MEMBER_REACHABILITY_REACHABLE"),
    2: .same(proto: "CLUSTER_MEMBER_REACHABILITY_UNREACHABLE"),
  ]
}

extension _ProtoClusterMemberStatus: SwiftProtobuf._ProtoNameProviding {
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    0: .same(proto: "CLUSTER_MEMBER_STATUS_UNSPECIFIED"),
    1: .same(proto: "CLUSTER_MEMBER_STATUS_JOINING"),
    2: .same(proto: "CLUSTER_MEMBER_STATUS_UP"),
    3: .same(proto: "CLUSTER_MEMBER_STATUS_DOWN"),
    4: .same(proto: "CLUSTER_MEMBER_STATUS_LEAVING"),
    5: .same(proto: "CLUSTER_MEMBER_STATUS_REMOVED"),
  ]
}

extension _ProtoClusterMembership: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "ClusterMembership"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "members"),
    2: .same(proto: "leaderNode"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeRepeatedMessageField(value: &self.members) }()
      case 2: try { try decoder.decodeSingularMessageField(value: &self._leaderNode) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.members.isEmpty {
      try visitor.visitRepeatedMessageField(value: self.members, fieldNumber: 1)
    }
    if let v = self._leaderNode {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: _ProtoClusterMembership, rhs: _ProtoClusterMembership) -> Bool {
    if lhs.members != rhs.members {return false}
    if lhs._leaderNode != rhs._leaderNode {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension _ProtoClusterMember: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "ClusterMember"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "node"),
    2: .same(proto: "status"),
    3: .same(proto: "reachability"),
    4: .same(proto: "upNumber"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularMessageField(value: &self._node) }()
      case 2: try { try decoder.decodeSingularEnumField(value: &self.status) }()
      case 3: try { try decoder.decodeSingularEnumField(value: &self.reachability) }()
      case 4: try { try decoder.decodeSingularUInt32Field(value: &self.upNumber) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if let v = self._node {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
    }
    if self.status != .unspecified {
      try visitor.visitSingularEnumField(value: self.status, fieldNumber: 2)
    }
    if self.reachability != .unspecified {
      try visitor.visitSingularEnumField(value: self.reachability, fieldNumber: 3)
    }
    if self.upNumber != 0 {
      try visitor.visitSingularUInt32Field(value: self.upNumber, fieldNumber: 4)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: _ProtoClusterMember, rhs: _ProtoClusterMember) -> Bool {
    if lhs._node != rhs._node {return false}
    if lhs.status != rhs.status {return false}
    if lhs.reachability != rhs.reachability {return false}
    if lhs.upNumber != rhs.upNumber {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension _ProtoClusterMembershipGossip: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "ClusterMembershipGossip"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "membership"),
    2: .same(proto: "ownerUniqueNodeID"),
    3: .same(proto: "seenTable"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularMessageField(value: &self._membership) }()
      case 2: try { try decoder.decodeSingularUInt64Field(value: &self.ownerUniqueNodeID) }()
      case 3: try { try decoder.decodeSingularMessageField(value: &self._seenTable) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if let v = self._membership {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
    }
    if self.ownerUniqueNodeID != 0 {
      try visitor.visitSingularUInt64Field(value: self.ownerUniqueNodeID, fieldNumber: 2)
    }
    if let v = self._seenTable {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: _ProtoClusterMembershipGossip, rhs: _ProtoClusterMembershipGossip) -> Bool {
    if lhs._membership != rhs._membership {return false}
    if lhs.ownerUniqueNodeID != rhs.ownerUniqueNodeID {return false}
    if lhs._seenTable != rhs._seenTable {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension _ProtoClusterMembershipSeenTable: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "ClusterMembershipSeenTable"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "rows"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeRepeatedMessageField(value: &self.rows) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.rows.isEmpty {
      try visitor.visitRepeatedMessageField(value: self.rows, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: _ProtoClusterMembershipSeenTable, rhs: _ProtoClusterMembershipSeenTable) -> Bool {
    if lhs.rows != rhs.rows {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension _ProtoClusterMembershipSeenTableRow: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "ClusterMembershipSeenTableRow"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "uniqueNodeID"),
    2: .same(proto: "version"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularUInt64Field(value: &self.uniqueNodeID) }()
      case 2: try { try decoder.decodeSingularMessageField(value: &self._version) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.uniqueNodeID != 0 {
      try visitor.visitSingularUInt64Field(value: self.uniqueNodeID, fieldNumber: 1)
    }
    if let v = self._version {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: _ProtoClusterMembershipSeenTableRow, rhs: _ProtoClusterMembershipSeenTableRow) -> Bool {
    if lhs.uniqueNodeID != rhs.uniqueNodeID {return false}
    if lhs._version != rhs._version {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
