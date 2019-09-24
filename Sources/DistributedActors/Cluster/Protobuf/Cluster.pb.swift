// DO NOT EDIT.
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: Cluster/Cluster.proto
//
// For information on using the generated types, please see the documenation:
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
// Please ensure that your are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

/// FIXME: this is not a 1:1 yet but shall become
struct ProtoClusterShellMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var message: OneOf_Message? {
    get {return _storage._message}
    set {_uniqueStorage()._message = newValue}
  }

  /// Not all messages are serializable, on purpose, as they are not intended to cross over the network
  var clusterEvent: ProtoClusterEvent {
    get {
      if case .clusterEvent(let v)? = _storage._message {return v}
      return ProtoClusterEvent()
    }
    set {_uniqueStorage()._message = .clusterEvent(newValue)}
  }

  var gossip: ProtoClusterGossip {
    get {
      if case .gossip(let v)? = _storage._message {return v}
      return ProtoClusterGossip()
    }
    set {_uniqueStorage()._message = .gossip(newValue)}
  }

  var unknownFields = SwiftProtobuf.UnknownStorage()

  enum OneOf_Message: Equatable {
    /// Not all messages are serializable, on purpose, as they are not intended to cross over the network
    case clusterEvent(ProtoClusterEvent)
    case gossip(ProtoClusterGossip)

  #if !swift(>=4.1)
    static func ==(lhs: ProtoClusterShellMessage.OneOf_Message, rhs: ProtoClusterShellMessage.OneOf_Message) -> Bool {
      switch (lhs, rhs) {
      case (.clusterEvent(let l), .clusterEvent(let r)): return l == r
      case (.gossip(let l), .gossip(let r)): return l == r
      default: return false
      }
    }
  #endif
  }

  init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

struct ProtoClusterGossip {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// origin of the gossip
  var from: ProtoUniqueNode {
    get {return _storage._from ?? ProtoUniqueNode()}
    set {_uniqueStorage()._from = newValue}
  }
  /// Returns true if `from` has been explicitly set.
  var hasFrom: Bool {return _storage._from != nil}
  /// Clears the value of `from`. Subsequent reads from it will return its default value.
  mutating func clearFrom() {_uniqueStorage()._from = nil}

  /// TODO: Something else, "membership diff"
  var clusterEvents: [ProtoClusterEvent] {
    get {return _storage._clusterEvents}
    set {_uniqueStorage()._clusterEvents = newValue}
  }

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension ProtoClusterShellMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "ClusterShellMessage"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "clusterEvent"),
    2: .same(proto: "gossip"),
  ]

  fileprivate class _StorageClass {
    var _message: ProtoClusterShellMessage.OneOf_Message?

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _message = source._message
    }
  }

  fileprivate mutating func _uniqueStorage() -> _StorageClass {
    if !isKnownUniquelyReferenced(&_storage) {
      _storage = _StorageClass(copying: _storage)
    }
    return _storage
  }

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    _ = _uniqueStorage()
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      while let fieldNumber = try decoder.nextFieldNumber() {
        switch fieldNumber {
        case 1:
          var v: ProtoClusterEvent?
          if let current = _storage._message {
            try decoder.handleConflictingOneOf()
            if case .clusterEvent(let m) = current {v = m}
          }
          try decoder.decodeSingularMessageField(value: &v)
          if let v = v {_storage._message = .clusterEvent(v)}
        case 2:
          var v: ProtoClusterGossip?
          if let current = _storage._message {
            try decoder.handleConflictingOneOf()
            if case .gossip(let m) = current {v = m}
          }
          try decoder.decodeSingularMessageField(value: &v)
          if let v = v {_storage._message = .gossip(v)}
        default: break
        }
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      switch _storage._message {
      case .clusterEvent(let v)?:
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      case .gossip(let v)?:
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      case nil: break
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoClusterShellMessage, rhs: ProtoClusterShellMessage) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._message != rhs_storage._message {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoClusterGossip: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "ClusterGossip"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "from"),
    2: .same(proto: "clusterEvents"),
  ]

  fileprivate class _StorageClass {
    var _from: ProtoUniqueNode? = nil
    var _clusterEvents: [ProtoClusterEvent] = []

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _from = source._from
      _clusterEvents = source._clusterEvents
    }
  }

  fileprivate mutating func _uniqueStorage() -> _StorageClass {
    if !isKnownUniquelyReferenced(&_storage) {
      _storage = _StorageClass(copying: _storage)
    }
    return _storage
  }

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    _ = _uniqueStorage()
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      while let fieldNumber = try decoder.nextFieldNumber() {
        switch fieldNumber {
        case 1: try decoder.decodeSingularMessageField(value: &_storage._from)
        case 2: try decoder.decodeRepeatedMessageField(value: &_storage._clusterEvents)
        default: break
        }
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._from {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if !_storage._clusterEvents.isEmpty {
        try visitor.visitRepeatedMessageField(value: _storage._clusterEvents, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoClusterGossip, rhs: ProtoClusterGossip) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._from != rhs_storage._from {return false}
        if _storage._clusterEvents != rhs_storage._clusterEvents {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
