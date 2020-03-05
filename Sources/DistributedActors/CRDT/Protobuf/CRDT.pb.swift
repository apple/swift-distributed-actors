// DO NOT EDIT.
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: CRDT/CRDT.proto
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

public struct ProtoCRDTIdentity {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var id: String = String()

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}
}

public struct ProtoCRDTVersionContext {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var versionVector: ProtoVersionVector {
    get {return _storage._versionVector ?? ProtoVersionVector()}
    set {_uniqueStorage()._versionVector = newValue}
  }
  /// Returns true if `versionVector` has been explicitly set.
  public var hasVersionVector: Bool {return _storage._versionVector != nil}
  /// Clears the value of `versionVector`. Subsequent reads from it will return its default value.
  public mutating func clearVersionVector() {_uniqueStorage()._versionVector = nil}

  public var gaps: [ProtoVersionDot] {
    get {return _storage._gaps}
    set {_uniqueStorage()._gaps = newValue}
  }

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

public struct ProtoCRDTVersionedContainer {
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

  public var versionContext: ProtoCRDTVersionContext {
    get {return _storage._versionContext ?? ProtoCRDTVersionContext()}
    set {_uniqueStorage()._versionContext = newValue}
  }
  /// Returns true if `versionContext` has been explicitly set.
  public var hasVersionContext: Bool {return _storage._versionContext != nil}
  /// Clears the value of `versionContext`. Subsequent reads from it will return its default value.
  public mutating func clearVersionContext() {_uniqueStorage()._versionContext = nil}

  public var elementByBirthDot: [ProtoVersionDottedElementEnvelope] {
    get {return _storage._elementByBirthDot}
    set {_uniqueStorage()._elementByBirthDot = newValue}
  }

  public var delta: ProtoCRDTVersionedContainerDelta {
    get {return _storage._delta ?? ProtoCRDTVersionedContainerDelta()}
    set {_uniqueStorage()._delta = newValue}
  }
  /// Returns true if `delta` has been explicitly set.
  public var hasDelta: Bool {return _storage._delta != nil}
  /// Clears the value of `delta`. Subsequent reads from it will return its default value.
  public mutating func clearDelta() {_uniqueStorage()._delta = nil}

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

public struct ProtoCRDTVersionedContainerDelta {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var versionContext: ProtoCRDTVersionContext {
    get {return _storage._versionContext ?? ProtoCRDTVersionContext()}
    set {_uniqueStorage()._versionContext = newValue}
  }
  /// Returns true if `versionContext` has been explicitly set.
  public var hasVersionContext: Bool {return _storage._versionContext != nil}
  /// Clears the value of `versionContext`. Subsequent reads from it will return its default value.
  public mutating func clearVersionContext() {_uniqueStorage()._versionContext = nil}

  public var elementByBirthDot: [ProtoVersionDottedElementEnvelope] {
    get {return _storage._elementByBirthDot}
    set {_uniqueStorage()._elementByBirthDot = newValue}
  }

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

public struct ProtoCRDTGCounter {
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

  /// Not a map since we cannot use `replicaID` as key
  public var state: [ProtoCRDTGCounter.ReplicaState] {
    get {return _storage._state}
    set {_uniqueStorage()._state = newValue}
  }

  public var delta: ProtoCRDTGCounter.Delta {
    get {return _storage._delta ?? ProtoCRDTGCounter.Delta()}
    set {_uniqueStorage()._delta = newValue}
  }
  /// Returns true if `delta` has been explicitly set.
  public var hasDelta: Bool {return _storage._delta != nil}
  /// Clears the value of `delta`. Subsequent reads from it will return its default value.
  public mutating func clearDelta() {_uniqueStorage()._delta = nil}

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public struct ReplicaState {
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

    public var count: UInt64 {
      get {return _storage._count}
      set {_uniqueStorage()._count = newValue}
    }

    public var unknownFields = SwiftProtobuf.UnknownStorage()

    public init() {}

    fileprivate var _storage = _StorageClass.defaultInstance
  }

  public struct Delta {
    // SwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
    // methods supported on all messages.

    public var state: [ProtoCRDTGCounter.ReplicaState] = []

    public var unknownFields = SwiftProtobuf.UnknownStorage()

    public init() {}
  }

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

public struct ProtoCRDTORSet {
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

  /// Includes delta
  public var state: ProtoCRDTVersionedContainer {
    get {return _storage._state ?? ProtoCRDTVersionedContainer()}
    set {_uniqueStorage()._state = newValue}
  }
  /// Returns true if `state` has been explicitly set.
  public var hasState: Bool {return _storage._state != nil}
  /// Clears the value of `state`. Subsequent reads from it will return its default value.
  public mutating func clearState() {_uniqueStorage()._state = nil}

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension ProtoCRDTIdentity: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "CRDTIdentity"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "id"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularStringField(value: &self.id)
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.id.isEmpty {
      try visitor.visitSingularStringField(value: self.id, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoCRDTIdentity, rhs: ProtoCRDTIdentity) -> Bool {
    if lhs.id != rhs.id {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoCRDTVersionContext: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "CRDTVersionContext"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "versionVector"),
    2: .same(proto: "gaps"),
  ]

  fileprivate class _StorageClass {
    var _versionVector: ProtoVersionVector? = nil
    var _gaps: [ProtoVersionDot] = []

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _versionVector = source._versionVector
      _gaps = source._gaps
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
        case 1: try decoder.decodeSingularMessageField(value: &_storage._versionVector)
        case 2: try decoder.decodeRepeatedMessageField(value: &_storage._gaps)
        default: break
        }
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._versionVector {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if !_storage._gaps.isEmpty {
        try visitor.visitRepeatedMessageField(value: _storage._gaps, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoCRDTVersionContext, rhs: ProtoCRDTVersionContext) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._versionVector != rhs_storage._versionVector {return false}
        if _storage._gaps != rhs_storage._gaps {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoCRDTVersionedContainer: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "CRDTVersionedContainer"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "replicaID"),
    2: .same(proto: "versionContext"),
    3: .same(proto: "elementByBirthDot"),
    4: .same(proto: "delta"),
  ]

  fileprivate class _StorageClass {
    var _replicaID: ProtoVersionReplicaID? = nil
    var _versionContext: ProtoCRDTVersionContext? = nil
    var _elementByBirthDot: [ProtoVersionDottedElementEnvelope] = []
    var _delta: ProtoCRDTVersionedContainerDelta? = nil

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _replicaID = source._replicaID
      _versionContext = source._versionContext
      _elementByBirthDot = source._elementByBirthDot
      _delta = source._delta
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
        case 2: try decoder.decodeSingularMessageField(value: &_storage._versionContext)
        case 3: try decoder.decodeRepeatedMessageField(value: &_storage._elementByBirthDot)
        case 4: try decoder.decodeSingularMessageField(value: &_storage._delta)
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
      if let v = _storage._versionContext {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      }
      if !_storage._elementByBirthDot.isEmpty {
        try visitor.visitRepeatedMessageField(value: _storage._elementByBirthDot, fieldNumber: 3)
      }
      if let v = _storage._delta {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 4)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoCRDTVersionedContainer, rhs: ProtoCRDTVersionedContainer) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._replicaID != rhs_storage._replicaID {return false}
        if _storage._versionContext != rhs_storage._versionContext {return false}
        if _storage._elementByBirthDot != rhs_storage._elementByBirthDot {return false}
        if _storage._delta != rhs_storage._delta {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoCRDTVersionedContainerDelta: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "CRDTVersionedContainerDelta"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "versionContext"),
    2: .same(proto: "elementByBirthDot"),
  ]

  fileprivate class _StorageClass {
    var _versionContext: ProtoCRDTVersionContext? = nil
    var _elementByBirthDot: [ProtoVersionDottedElementEnvelope] = []

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _versionContext = source._versionContext
      _elementByBirthDot = source._elementByBirthDot
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
        case 1: try decoder.decodeSingularMessageField(value: &_storage._versionContext)
        case 2: try decoder.decodeRepeatedMessageField(value: &_storage._elementByBirthDot)
        default: break
        }
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._versionContext {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if !_storage._elementByBirthDot.isEmpty {
        try visitor.visitRepeatedMessageField(value: _storage._elementByBirthDot, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoCRDTVersionedContainerDelta, rhs: ProtoCRDTVersionedContainerDelta) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._versionContext != rhs_storage._versionContext {return false}
        if _storage._elementByBirthDot != rhs_storage._elementByBirthDot {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoCRDTGCounter: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "CRDTGCounter"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "replicaID"),
    2: .same(proto: "state"),
    3: .same(proto: "delta"),
  ]

  fileprivate class _StorageClass {
    var _replicaID: ProtoVersionReplicaID? = nil
    var _state: [ProtoCRDTGCounter.ReplicaState] = []
    var _delta: ProtoCRDTGCounter.Delta? = nil

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _replicaID = source._replicaID
      _state = source._state
      _delta = source._delta
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
        case 2: try decoder.decodeRepeatedMessageField(value: &_storage._state)
        case 3: try decoder.decodeSingularMessageField(value: &_storage._delta)
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
      if !_storage._state.isEmpty {
        try visitor.visitRepeatedMessageField(value: _storage._state, fieldNumber: 2)
      }
      if let v = _storage._delta {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoCRDTGCounter, rhs: ProtoCRDTGCounter) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._replicaID != rhs_storage._replicaID {return false}
        if _storage._state != rhs_storage._state {return false}
        if _storage._delta != rhs_storage._delta {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoCRDTGCounter.ReplicaState: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = ProtoCRDTGCounter.protoMessageName + ".ReplicaState"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "replicaID"),
    2: .same(proto: "count"),
  ]

  fileprivate class _StorageClass {
    var _replicaID: ProtoVersionReplicaID? = nil
    var _count: UInt64 = 0

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _replicaID = source._replicaID
      _count = source._count
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
        case 2: try decoder.decodeSingularUInt64Field(value: &_storage._count)
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
      if _storage._count != 0 {
        try visitor.visitSingularUInt64Field(value: _storage._count, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoCRDTGCounter.ReplicaState, rhs: ProtoCRDTGCounter.ReplicaState) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._replicaID != rhs_storage._replicaID {return false}
        if _storage._count != rhs_storage._count {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoCRDTGCounter.Delta: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = ProtoCRDTGCounter.protoMessageName + ".Delta"
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

  public static func ==(lhs: ProtoCRDTGCounter.Delta, rhs: ProtoCRDTGCounter.Delta) -> Bool {
    if lhs.state != rhs.state {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoCRDTORSet: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = "CRDTORSet"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "replicaID"),
    2: .same(proto: "state"),
  ]

  fileprivate class _StorageClass {
    var _replicaID: ProtoVersionReplicaID? = nil
    var _state: ProtoCRDTVersionedContainer? = nil

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _replicaID = source._replicaID
      _state = source._state
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
        case 2: try decoder.decodeSingularMessageField(value: &_storage._state)
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
      if let v = _storage._state {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: ProtoCRDTORSet, rhs: ProtoCRDTORSet) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._replicaID != rhs_storage._replicaID {return false}
        if _storage._state != rhs_storage._state {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
