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

struct ProtoSWIMMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var request: OneOf_Request? {
    get {return _storage._request}
    set {_uniqueStorage()._request = newValue}
  }

  var ping: ProtoSWIMPing {
    get {
      if case .ping(let v)? = _storage._request {return v}
      return ProtoSWIMPing()
    }
    set {_uniqueStorage()._request = .ping(newValue)}
  }

  var pingRequest: ProtoSWIMPingRequest {
    get {
      if case .pingRequest(let v)? = _storage._request {return v}
      return ProtoSWIMPingRequest()
    }
    set {_uniqueStorage()._request = .pingRequest(newValue)}
  }

  var unknownFields = SwiftProtobuf.UnknownStorage()

  enum OneOf_Request: Equatable {
    case ping(ProtoSWIMPing)
    case pingRequest(ProtoSWIMPingRequest)

  #if !swift(>=4.1)
    static func ==(lhs: ProtoSWIMMessage.OneOf_Request, rhs: ProtoSWIMMessage.OneOf_Request) -> Bool {
      switch (lhs, rhs) {
      case (.ping(let l), .ping(let r)): return l == r
      case (.pingRequest(let l), .pingRequest(let r)): return l == r
      default: return false
      }
    }
  #endif
  }

  init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

struct ProtoSWIMPing {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var lastKnownStatus: ProtoSWIMStatus {
    get {return _storage._lastKnownStatus ?? ProtoSWIMStatus()}
    set {_uniqueStorage()._lastKnownStatus = newValue}
  }
  /// Returns true if `lastKnownStatus` has been explicitly set.
  var hasLastKnownStatus: Bool {return _storage._lastKnownStatus != nil}
  /// Clears the value of `lastKnownStatus`. Subsequent reads from it will return its default value.
  mutating func clearLastKnownStatus() {_uniqueStorage()._lastKnownStatus = nil}

  var replyTo: ProtoActorAddress {
    get {return _storage._replyTo ?? ProtoActorAddress()}
    set {_uniqueStorage()._replyTo = newValue}
  }
  /// Returns true if `replyTo` has been explicitly set.
  var hasReplyTo: Bool {return _storage._replyTo != nil}
  /// Clears the value of `replyTo`. Subsequent reads from it will return its default value.
  mutating func clearReplyTo() {_uniqueStorage()._replyTo = nil}

  var payload: ProtoSWIMPayload {
    get {return _storage._payload ?? ProtoSWIMPayload()}
    set {_uniqueStorage()._payload = newValue}
  }
  /// Returns true if `payload` has been explicitly set.
  var hasPayload: Bool {return _storage._payload != nil}
  /// Clears the value of `payload`. Subsequent reads from it will return its default value.
  mutating func clearPayload() {_uniqueStorage()._payload = nil}

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

struct ProtoSWIMPingRequest {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var target: ProtoActorAddress {
    get {return _storage._target ?? ProtoActorAddress()}
    set {_uniqueStorage()._target = newValue}
  }
  /// Returns true if `target` has been explicitly set.
  var hasTarget: Bool {return _storage._target != nil}
  /// Clears the value of `target`. Subsequent reads from it will return its default value.
  mutating func clearTarget() {_uniqueStorage()._target = nil}

  var lastKnownStatus: ProtoSWIMStatus {
    get {return _storage._lastKnownStatus ?? ProtoSWIMStatus()}
    set {_uniqueStorage()._lastKnownStatus = newValue}
  }
  /// Returns true if `lastKnownStatus` has been explicitly set.
  var hasLastKnownStatus: Bool {return _storage._lastKnownStatus != nil}
  /// Clears the value of `lastKnownStatus`. Subsequent reads from it will return its default value.
  mutating func clearLastKnownStatus() {_uniqueStorage()._lastKnownStatus = nil}

  var replyTo: ProtoActorAddress {
    get {return _storage._replyTo ?? ProtoActorAddress()}
    set {_uniqueStorage()._replyTo = newValue}
  }
  /// Returns true if `replyTo` has been explicitly set.
  var hasReplyTo: Bool {return _storage._replyTo != nil}
  /// Clears the value of `replyTo`. Subsequent reads from it will return its default value.
  mutating func clearReplyTo() {_uniqueStorage()._replyTo = nil}

  var payload: ProtoSWIMPayload {
    get {return _storage._payload ?? ProtoSWIMPayload()}
    set {_uniqueStorage()._payload = newValue}
  }
  /// Returns true if `payload` has been explicitly set.
  var hasPayload: Bool {return _storage._payload != nil}
  /// Clears the value of `payload`. Subsequent reads from it will return its default value.
  mutating func clearPayload() {_uniqueStorage()._payload = nil}

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

struct ProtoSWIMAck {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var pinged: ProtoActorAddress {
    get {return _storage._pinged ?? ProtoActorAddress()}
    set {_uniqueStorage()._pinged = newValue}
  }
  /// Returns true if `pinged` has been explicitly set.
  var hasPinged: Bool {return _storage._pinged != nil}
  /// Clears the value of `pinged`. Subsequent reads from it will return its default value.
  mutating func clearPinged() {_uniqueStorage()._pinged = nil}

  var incarnation: UInt64 {
    get {return _storage._incarnation}
    set {_uniqueStorage()._incarnation = newValue}
  }

  var payload: ProtoSWIMPayload {
    get {return _storage._payload ?? ProtoSWIMPayload()}
    set {_uniqueStorage()._payload = newValue}
  }
  /// Returns true if `payload` has been explicitly set.
  var hasPayload: Bool {return _storage._payload != nil}
  /// Clears the value of `payload`. Subsequent reads from it will return its default value.
  mutating func clearPayload() {_uniqueStorage()._payload = nil}

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

struct ProtoSWIMStatus {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var type: ProtoSWIMStatus.TypeEnum = .alive

  var incarnation: UInt64 = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  enum TypeEnum: SwiftProtobuf.Enum {
    typealias RawValue = Int
    case alive // = 0
    case suspect // = 1
    case unreachable // = 2
    case dead // = 3
    case UNRECOGNIZED(Int)

    init() {
      self = .alive
    }

    init?(rawValue: Int) {
      switch rawValue {
      case 0: self = .alive
      case 1: self = .suspect
      case 2: self = .unreachable
      case 3: self = .dead
      default: self = .UNRECOGNIZED(rawValue)
      }
    }

    var rawValue: Int {
      switch self {
      case .alive: return 0
      case .suspect: return 1
      case .unreachable: return 2
      case .dead: return 3
      case .UNRECOGNIZED(let i): return i
      }
    }

  }

  init() {}
}

#if swift(>=4.2)

extension ProtoSWIMStatus.TypeEnum: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  static var allCases: [ProtoSWIMStatus.TypeEnum] = [
    .alive,
    .suspect,
    .unreachable,
    .dead,
  ]
}

#endif  // swift(>=4.2)

struct ProtoSWIMMember {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var address: ProtoActorAddress {
    get {return _storage._address ?? ProtoActorAddress()}
    set {_uniqueStorage()._address = newValue}
  }
  /// Returns true if `address` has been explicitly set.
  var hasAddress: Bool {return _storage._address != nil}
  /// Clears the value of `address`. Subsequent reads from it will return its default value.
  mutating func clearAddress() {_uniqueStorage()._address = nil}

  var status: ProtoSWIMStatus {
    get {return _storage._status ?? ProtoSWIMStatus()}
    set {_uniqueStorage()._status = newValue}
  }
  /// Returns true if `status` has been explicitly set.
  var hasStatus: Bool {return _storage._status != nil}
  /// Clears the value of `status`. Subsequent reads from it will return its default value.
  mutating func clearStatus() {_uniqueStorage()._status = nil}

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  fileprivate var _storage = _StorageClass.defaultInstance
}

struct ProtoSWIMPayload {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var member: [ProtoSWIMMember] = []

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension ProtoSWIMMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "SWIMMessage"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "ping"),
    2: .same(proto: "pingRequest"),
  ]

  fileprivate class _StorageClass {
    var _request: ProtoSWIMMessage.OneOf_Request?

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _request = source._request
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
          var v: ProtoSWIMPing?
          if let current = _storage._request {
            try decoder.handleConflictingOneOf()
            if case .ping(let m) = current {v = m}
          }
          try decoder.decodeSingularMessageField(value: &v)
          if let v = v {_storage._request = .ping(v)}
        case 2:
          var v: ProtoSWIMPingRequest?
          if let current = _storage._request {
            try decoder.handleConflictingOneOf()
            if case .pingRequest(let m) = current {v = m}
          }
          try decoder.decodeSingularMessageField(value: &v)
          if let v = v {_storage._request = .pingRequest(v)}
        default: break
        }
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      switch _storage._request {
      case .ping(let v)?:
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      case .pingRequest(let v)?:
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      case nil: break
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoSWIMMessage, rhs: ProtoSWIMMessage) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._request != rhs_storage._request {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoSWIMPing: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "SWIMPing"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "lastKnownStatus"),
    2: .same(proto: "replyTo"),
    3: .same(proto: "payload"),
  ]

  fileprivate class _StorageClass {
    var _lastKnownStatus: ProtoSWIMStatus? = nil
    var _replyTo: ProtoActorAddress? = nil
    var _payload: ProtoSWIMPayload? = nil

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _lastKnownStatus = source._lastKnownStatus
      _replyTo = source._replyTo
      _payload = source._payload
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
        case 1: try decoder.decodeSingularMessageField(value: &_storage._lastKnownStatus)
        case 2: try decoder.decodeSingularMessageField(value: &_storage._replyTo)
        case 3: try decoder.decodeSingularMessageField(value: &_storage._payload)
        default: break
        }
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._lastKnownStatus {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if let v = _storage._replyTo {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      }
      if let v = _storage._payload {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoSWIMPing, rhs: ProtoSWIMPing) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._lastKnownStatus != rhs_storage._lastKnownStatus {return false}
        if _storage._replyTo != rhs_storage._replyTo {return false}
        if _storage._payload != rhs_storage._payload {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoSWIMPingRequest: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "SWIMPingRequest"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "target"),
    2: .same(proto: "lastKnownStatus"),
    3: .same(proto: "replyTo"),
    4: .same(proto: "payload"),
  ]

  fileprivate class _StorageClass {
    var _target: ProtoActorAddress? = nil
    var _lastKnownStatus: ProtoSWIMStatus? = nil
    var _replyTo: ProtoActorAddress? = nil
    var _payload: ProtoSWIMPayload? = nil

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _target = source._target
      _lastKnownStatus = source._lastKnownStatus
      _replyTo = source._replyTo
      _payload = source._payload
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
        case 1: try decoder.decodeSingularMessageField(value: &_storage._target)
        case 2: try decoder.decodeSingularMessageField(value: &_storage._lastKnownStatus)
        case 3: try decoder.decodeSingularMessageField(value: &_storage._replyTo)
        case 4: try decoder.decodeSingularMessageField(value: &_storage._payload)
        default: break
        }
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._target {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if let v = _storage._lastKnownStatus {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      }
      if let v = _storage._replyTo {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
      }
      if let v = _storage._payload {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 4)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoSWIMPingRequest, rhs: ProtoSWIMPingRequest) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._target != rhs_storage._target {return false}
        if _storage._lastKnownStatus != rhs_storage._lastKnownStatus {return false}
        if _storage._replyTo != rhs_storage._replyTo {return false}
        if _storage._payload != rhs_storage._payload {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoSWIMAck: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "SWIMAck"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "pinged"),
    2: .same(proto: "incarnation"),
    3: .same(proto: "payload"),
  ]

  fileprivate class _StorageClass {
    var _pinged: ProtoActorAddress? = nil
    var _incarnation: UInt64 = 0
    var _payload: ProtoSWIMPayload? = nil

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _pinged = source._pinged
      _incarnation = source._incarnation
      _payload = source._payload
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
        case 1: try decoder.decodeSingularMessageField(value: &_storage._pinged)
        case 2: try decoder.decodeSingularUInt64Field(value: &_storage._incarnation)
        case 3: try decoder.decodeSingularMessageField(value: &_storage._payload)
        default: break
        }
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._pinged {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if _storage._incarnation != 0 {
        try visitor.visitSingularUInt64Field(value: _storage._incarnation, fieldNumber: 2)
      }
      if let v = _storage._payload {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoSWIMAck, rhs: ProtoSWIMAck) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._pinged != rhs_storage._pinged {return false}
        if _storage._incarnation != rhs_storage._incarnation {return false}
        if _storage._payload != rhs_storage._payload {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoSWIMStatus: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "SWIMStatus"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "type"),
    2: .same(proto: "incarnation"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularEnumField(value: &self.type)
      case 2: try decoder.decodeSingularUInt64Field(value: &self.incarnation)
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.type != .alive {
      try visitor.visitSingularEnumField(value: self.type, fieldNumber: 1)
    }
    if self.incarnation != 0 {
      try visitor.visitSingularUInt64Field(value: self.incarnation, fieldNumber: 2)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoSWIMStatus, rhs: ProtoSWIMStatus) -> Bool {
    if lhs.type != rhs.type {return false}
    if lhs.incarnation != rhs.incarnation {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoSWIMStatus.TypeEnum: SwiftProtobuf._ProtoNameProviding {
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    0: .same(proto: "ALIVE"),
    1: .same(proto: "SUSPECT"),
    2: .same(proto: "UNREACHABLE"),
    3: .same(proto: "DEAD"),
  ]
}

extension ProtoSWIMMember: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "SWIMMember"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "address"),
    2: .same(proto: "status"),
  ]

  fileprivate class _StorageClass {
    var _address: ProtoActorAddress? = nil
    var _status: ProtoSWIMStatus? = nil

    static let defaultInstance = _StorageClass()

    private init() {}

    init(copying source: _StorageClass) {
      _address = source._address
      _status = source._status
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
        case 1: try decoder.decodeSingularMessageField(value: &_storage._address)
        case 2: try decoder.decodeSingularMessageField(value: &_storage._status)
        default: break
        }
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try withExtendedLifetime(_storage) { (_storage: _StorageClass) in
      if let v = _storage._address {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
      }
      if let v = _storage._status {
        try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
      }
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoSWIMMember, rhs: ProtoSWIMMember) -> Bool {
    if lhs._storage !== rhs._storage {
      let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
        let _storage = _args.0
        let rhs_storage = _args.1
        if _storage._address != rhs_storage._address {return false}
        if _storage._status != rhs_storage._status {return false}
        return true
      }
      if !storagesAreEqual {return false}
    }
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension ProtoSWIMPayload: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "SWIMPayload"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "member"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeRepeatedMessageField(value: &self.member)
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.member.isEmpty {
      try visitor.visitRepeatedMessageField(value: self.member, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ProtoSWIMPayload, rhs: ProtoSWIMPayload) -> Bool {
    if lhs.member != rhs.member {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
