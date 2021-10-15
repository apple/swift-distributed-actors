// DO NOT EDIT.
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: Clocks/VersionVector.proto
//
// For information on using the generated types, please see the documenation:
//   https://github.com/apple/swift-protobuf/

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
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

public struct ProtoActorIdentity {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var manifest: ProtoManifest {
    get {return _storage._manifest ?? ProtoManifest()}
    set {_uniqueStorage()._manifest = newValue}
  }
  /// Returns true if `manifest` has been explicitly set.
  public var hasManifest: Bool {return _storage._manifest != nil}
  /// Clears the value of `manifest`. Subsequent reads from it will return its default value.
  public mutating func clearManifest() {_uniqueStorage()._manifest = nil}

  public var payload: Data {
    get {return _storage._payload}
    set {_uniqueStorage()._payload = newValue}
  }

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

public struct ProtoVersionReplicaID {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var value: OneOf_Value? {
    get {return _storage._value}
    set {_uniqueStorage()._value = newValue}
  }

  public var actorAddress: ProtoActorAddress {
    get {
      if case .actorAddress(let v)? = _storage._value {return v}
      return ProtoActorAddress()
    }
    set {_uniqueStorage()._value = .actorAddress(newValue)}
  }

  public var actorIdentity: ProtoActorIdentity {
    get {
      if case .actorIdentity(let v)? = _storage._value {return v}
      return ProtoActorIdentity()
    }
    set {_uniqueStorage()._value = .actorIdentity(newValue)}
  }

  public var uniqueNode: ProtoUniqueNode {
    get {
      if case .uniqueNode(let v)? = _storage._value {return v}
      return ProtoUniqueNode()
    }
    set {_uniqueStorage()._value = .uniqueNode(newValue)}
  }

  public var uniqueNodeID: UInt64 {
    get {
      if case .uniqueNodeID(let v)? = _storage._value {return v}
      return 0
    }
    set {_uniqueStorage()._value = .uniqueNodeID(newValue)}
  }

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public enum OneOf_Value: Equatable {
    case actorAddress(ProtoActorAddress)
    case actorIdentity(ProtoActorIdentity)
    case uniqueNode(ProtoUniqueNode)
    case uniqueNodeID(UInt64)

  #if !swift(>=4.1)
    public static func ==(lhs: ProtoVersionReplicaID.OneOf_Value, rhs: ProtoVersionReplicaID.OneOf_Value) -> Bool {
      switch (lhs, rhs) {
      case (.actorAddress(let l), .actorAddress(let r)): return l == r
      case (.actorIdentity(let l), .actorIdentity(let r)): return l == r
      case (.uniqueNode(let l), .uniqueNode(let r)): return l == r
      case (.uniqueNodeID(let l), .uniqueNodeID(let r)): return l == r
      default: return false
      }
    }
  #endif
  }

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

public struct ProtoReplicaVersion {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var replicaID: ProtoVersionReplicaID {
    get {return _storage._replicaID ?? ProtoVersionReplicaID()}
    set {_uniqueStorage()._replicaID = newValue}
  }
  /// Returns true if `replicaID` has been explicitly set.
  public var hasReplicaID: Bool {return _storage._replicaID != nil}
  /// Clears the value of `replicaID`. Subsequent reads from it will return its default value.
  public mutating func clearReplicaID() {_uniqueStorage()._replicaID = nil}

  public var version: UInt64 {
    get {return _storage._version}
    set {_uniqueStorage()._version = newValue}
  }

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

public struct ProtoVersionVector {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// Not a map since we cannot use `replicaId` as key
  public var state: [ProtoReplicaVersion] = []

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}
}

public struct ProtoVersionDot {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var replicaID: ProtoVersionReplicaID {
    get {return _storage._replicaID ?? ProtoVersionReplicaID()}
    set {_uniqueStorage()._replicaID = newValue}
  }
  /// Returns true if `replicaID` has been explicitly set.
  public var hasReplicaID: Bool {return _storage._replicaID != nil}
  /// Clears the value of `replicaID`. Subsequent reads from it will return its default value.
  public mutating func clearReplicaID() {_uniqueStorage()._replicaID = nil}

  public var version: UInt64 {
    get {return _storage._version}
    set {_uniqueStorage()._version = newValue}
  }

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

/// A dot and its arbitrary, serialized element
public struct ProtoVersionDottedElementEnvelope {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var dot: ProtoVersionDot {
    get {return _storage._dot ?? ProtoVersionDot()}
    set {_uniqueStorage()._dot = newValue}
  }
  /// Returns true if `dot` has been explicitly set.
  public var hasDot: Bool {return _storage._dot != nil}
  /// Clears the value of `dot`. Subsequent reads from it will return its default value.
  public mutating func clearDot() {_uniqueStorage()._dot = nil}

  /// ~~ element ~~
  public var manifest: ProtoManifest {
    get {return _storage._manifest ?? ProtoManifest()}
    set {_uniqueStorage()._manifest = newValue}
  }
  /// Returns true if `manifest` has been explicitly set.
  public var hasManifest: Bool {return _storage._manifest != nil}
  /// Clears the value of `manifest`. Subsequent reads from it will return its default value.
  public mutating func clearManifest() {_uniqueStorage()._manifest = nil}

  public var payload: Data {
    get {return _storage._payload}
    set {_uniqueStorage()._payload = newValue}
  }

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension ProtoActorIdentity: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "ActorIdentity"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "manifest"),
    2: .same(proto: "payload"),
  ]

  fileprivate class _StorageClass {
    var _manifest: ProtoManifest? = nil
    var _payload: Data = SwiftProtobuf.Internal.emptyData

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _manifest = source._manifest
      _payload = source._payload
    }
  }

  fileprivate mutating func _uniqueStorage() -> _StorageClass {
    if !isKnownUniquelyReferenced(&_storage) {
      _storage = _StorageClass(copying: _storage)
    }
    return _storage
  }

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    _ = _uniqueStorage()
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      while let fieldNumber = try decoder.nextFieldNumber() {
        switch fieldNumber {
        case 1: try decoder.decodeSingularMessageField(value: &_storage._manifest)
        case 2: try decoder.decodeSingularBytesField(value: &_storage._payload)
        default: break
        }
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._manifest {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if !_storage._payload.isEmpty {
        try visitor.visitSingularBytesField(value: _storage._payload, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoActorIdentity, rhs: ProtoActorIdentity) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._manifest != rhs_storage._manifest {return false}
        if _storage._payload != rhs_storage._payload {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoVersionReplicaID: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "VersionReplicaID"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "actorAddress"),
    2: .same(proto: "actorIdentity"),
    3: .same(proto: "uniqueNode"),
    4: .same(proto: "uniqueNodeID"),
  ]

  fileprivate class _StorageClass {
    var _value: ProtoVersionReplicaID.OneOf_Value?

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _value = source._value
    }
  }

  fileprivate mutating func _uniqueStorage() -> _StorageClass {
    if !isKnownUniquelyReferenced(&_storage) {
      _storage = _StorageClass(copying: _storage)
    }
    return _storage
  }

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    _ = _uniqueStorage()
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      while let fieldNumber = try decoder.nextFieldNumber() {
        switch fieldNumber {
        case 1:
          var v: ProtoActorAddress?
          if let current = _storage._value {
            try decoder.handleConflictingOneOf()
            if case .actorAddress(let m) = current {v = m}
          }
          try decoder.decodeSingularMessageField(value: &v)
          if let v = v {_storage._value = .actorAddress(v)}
        case 2:
          var v: ProtoActorIdentity?
          if let current = _storage._value {
            try decoder.handleConflictingOneOf()
            if case .actorIdentity(let m) = current {v = m}
          }
          try decoder.decodeSingularMessageField(value: &v)
          if let v = v {_storage._value = .actorIdentity(v)}
        case 3:
          var v: ProtoUniqueNode?
          if let current = _storage._value {
            try decoder.handleConflictingOneOf()
            if case .uniqueNode(let m) = current {v = m}
          }
          try decoder.decodeSingularMessageField(value: &v)
          if let v = v {_storage._value = .uniqueNode(v)}
        case 4:
          if _storage._value != nil {try decoder.handleConflictingOneOf()}
          var v: UInt64?
          try decoder.decodeSingularUInt64Field(value: &v)
          if let v = v {_storage._value = .uniqueNodeID(v)}
        default: break
        }
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      switch _storage._value {
      case .actorAddress(let v)?:
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      case .actorIdentity(let v)?:
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      case .uniqueNode(let v)?:
        try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
      case .uniqueNodeID(let v)?:
        try visitor.visitSingularUInt64Field(value: v, fieldNumber: 4)
      case nil: break
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoVersionReplicaID, rhs: ProtoVersionReplicaID) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._value != rhs_storage._value {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoReplicaVersion: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "ReplicaVersion"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "replicaID"),
    2: .same(proto: "version"),
  ]

  fileprivate class _StorageClass {
    var _replicaID: ProtoVersionReplicaID? = nil
    var _version: UInt64 = 0

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _replicaID = source._replicaID
      _version = source._version
    }
  }

  fileprivate mutating func _uniqueStorage() -> _StorageClass {
    if !isKnownUniquelyReferenced(&_storage) {
      _storage = _StorageClass(copying: _storage)
    }
    return _storage
  }

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    _ = _uniqueStorage()
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      while let fieldNumber = try decoder.nextFieldNumber() {
        switch fieldNumber {
        case 1: try decoder.decodeSingularMessageField(value: &_storage._replicaID)
        case 2: try decoder.decodeSingularUInt64Field(value: &_storage._version)
        default: break
        }
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._replicaID {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if _storage._version != 0 {
        try visitor.visitSingularUInt64Field(value: _storage._version, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoReplicaVersion, rhs: ProtoReplicaVersion) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._replicaID != rhs_storage._replicaID {return false}
        if _storage._version != rhs_storage._version {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoVersionVector: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "VersionVector"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "state"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeRepeatedMessageField(value: &self.state)
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.state.isEmpty {
      try visitor.visitRepeatedMessageField(value: self.state, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoVersionVector, rhs: ProtoVersionVector) -> Bool {
    if lhs.state != rhs.state {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoVersionDot: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "VersionDot"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "replicaID"),
    2: .same(proto: "version"),
  ]

  fileprivate class _StorageClass {
    var _replicaID: ProtoVersionReplicaID? = nil
    var _version: UInt64 = 0

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _replicaID = source._replicaID
      _version = source._version
    }
  }

  fileprivate mutating func _uniqueStorage() -> _StorageClass {
    if !isKnownUniquelyReferenced(&_storage) {
      _storage = _StorageClass(copying: _storage)
    }
    return _storage
  }

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    _ = _uniqueStorage()
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      while let fieldNumber = try decoder.nextFieldNumber() {
        switch fieldNumber {
        case 1: try decoder.decodeSingularMessageField(value: &_storage._replicaID)
        case 2: try decoder.decodeSingularUInt64Field(value: &_storage._version)
        default: break
        }
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._replicaID {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if _storage._version != 0 {
        try visitor.visitSingularUInt64Field(value: _storage._version, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoVersionDot, rhs: ProtoVersionDot) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._replicaID != rhs_storage._replicaID {return false}
        if _storage._version != rhs_storage._version {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoVersionDottedElementEnvelope: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "VersionDottedElementEnvelope"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "dot"),
    2: .same(proto: "manifest"),
    3: .same(proto: "payload"),
  ]

  fileprivate class _StorageClass {
    var _dot: ProtoVersionDot? = nil
    var _manifest: ProtoManifest? = nil
    var _payload: Data = SwiftProtobuf.Internal.emptyData

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _dot = source._dot
      _manifest = source._manifest
      _payload = source._payload
    }
  }

  fileprivate mutating func _uniqueStorage() -> _StorageClass {
    if !isKnownUniquelyReferenced(&_storage) {
      _storage = _StorageClass(copying: _storage)
    }
    return _storage
  }

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    _ = _uniqueStorage()
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      while let fieldNumber = try decoder.nextFieldNumber() {
        switch fieldNumber {
        case 1: try decoder.decodeSingularMessageField(value: &_storage._dot)
        case 2: try decoder.decodeSingularMessageField(value: &_storage._manifest)
        case 3: try decoder.decodeSingularBytesField(value: &_storage._payload)
        default: break
        }
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._dot {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if let v = _storage._manifest {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      }
      if !_storage._payload.isEmpty {
        try visitor.visitSingularBytesField(value: _storage._payload, fieldNumber: 3)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoVersionDottedElementEnvelope, rhs: ProtoVersionDottedElementEnvelope) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._dot != rhs_storage._dot {return false}
        if _storage._manifest != rhs_storage._manifest {return false}
        if _storage._payload != rhs_storage._payload {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
