// DO NOT EDIT.
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: CRDT/CRDTReplication.proto
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
private struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
    struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
    typealias Version = _2
}

struct ProtoCRDTReplicatorMessage {
    // SwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
    // methods supported on all messages.

    var value: OneOf_Value? {
        get { return self._storage._value }
        set { _uniqueStorage()._value = newValue }
    }

    var write: ProtoCRDTWrite {
        get {
            if case .write(let v)? = self._storage._value { return v }
            return ProtoCRDTWrite()
        }
        set { _uniqueStorage()._value = .write(newValue) }
    }

    var unknownFields = SwiftProtobuf.UnknownStorage()

    enum OneOf_Value: Equatable {
        case write(ProtoCRDTWrite)

        #if !swift(>=4.1)
        static func == (lhs: ProtoCRDTReplicatorMessage.OneOf_Value, rhs: ProtoCRDTReplicatorMessage.OneOf_Value) -> Bool {
            switch (lhs, rhs) {
            case (.write(let l), .write(let r)): return l == r
            }
        }
        #endif
    }

    init() {}

    fileprivate var _storage = _StorageClass.defaultInstance
}

struct ProtoCRDTWrite {
    // SwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
    // methods supported on all messages.

    var identity: ProtoCRDTIdentity {
        get { return self._storage._identity ?? ProtoCRDTIdentity() }
        set { _uniqueStorage()._identity = newValue }
    }

    /// Returns true if `identity` has been explicitly set.
    var hasIdentity: Bool { return _storage._identity != nil }
    /// Clears the value of `identity`. Subsequent reads from it will return its default value.
    mutating func clearIdentity() { _uniqueStorage()._identity = nil }

    var data: ProtoReplicatedData {
        get { return self._storage._data ?? ProtoReplicatedData() }
        set { _uniqueStorage()._data = newValue }
    }

    /// Returns true if `data` has been explicitly set.
    var hasData: Bool { return _storage._data != nil }
    /// Clears the value of `data`. Subsequent reads from it will return its default value.
    mutating func clearData() { _uniqueStorage()._data = nil }

    var replyTo: ProtoActorAddress {
        get { return self._storage._replyTo ?? ProtoActorAddress() }
        set { _uniqueStorage()._replyTo = newValue }
    }

    /// Returns true if `replyTo` has been explicitly set.
    var hasReplyTo: Bool { return _storage._replyTo != nil }
    /// Clears the value of `replyTo`. Subsequent reads from it will return its default value.
    mutating func clearReplyTo() { _uniqueStorage()._replyTo = nil }

    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    fileprivate var _storage = _StorageClass.defaultInstance
}

struct ProtoCRDTWriteResult {
    // SwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
    // methods supported on all messages.

    var type: ProtoCRDTWriteResult.TypeEnum {
        get { return self._storage._type }
        set { _uniqueStorage()._type = newValue }
    }

    var error: ProtoCRDTWriteError {
        get { return self._storage._error ?? ProtoCRDTWriteError() }
        set { _uniqueStorage()._error = newValue }
    }

    /// Returns true if `error` has been explicitly set.
    var hasError: Bool { return _storage._error != nil }
    /// Clears the value of `error`. Subsequent reads from it will return its default value.
    mutating func clearError() { _uniqueStorage()._error = nil }

    var unknownFields = SwiftProtobuf.UnknownStorage()

    enum TypeEnum: SwiftProtobuf.Enum {
        typealias RawValue = Int
        case success // = 0
        case failed // = 1
        case UNRECOGNIZED(Int)

        init() {
            self = .success
        }

        init?(rawValue: Int) {
            switch rawValue {
            case 0: self = .success
            case 1: self = .failed
            default: self = .UNRECOGNIZED(rawValue)
            }
        }

        var rawValue: Int {
            switch self {
            case .success: return 0
            case .failed: return 1
            case .UNRECOGNIZED(let i): return i
            }
        }
    }

    init() {}

    fileprivate var _storage = _StorageClass.defaultInstance
}

#if swift(>=4.2)

extension ProtoCRDTWriteResult.TypeEnum: CaseIterable {
    // The compiler won't synthesize support with the UNRECOGNIZED case.
    static var allCases: [ProtoCRDTWriteResult.TypeEnum] = [
        .success,
        .failed,
    ]
}

#endif // swift(>=4.2)

struct ProtoCRDTWriteError {
    // SwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
    // methods supported on all messages.

    var type: ProtoCRDTWriteError.TypeEnum = .missingCrdtForDelta

    var unknownFields = SwiftProtobuf.UnknownStorage()

    enum TypeEnum: SwiftProtobuf.Enum {
        typealias RawValue = Int
        case missingCrdtForDelta // = 0
        case incorrectDeltaType // = 1
        case cannotWriteDeltaForNonDeltaCrdt // = 2
        case inputAndStoredDataTypeMismatch // = 3
        case unsupportedCrdt // = 4
        case UNRECOGNIZED(Int)

        init() {
            self = .missingCrdtForDelta
        }

        init?(rawValue: Int) {
            switch rawValue {
            case 0: self = .missingCrdtForDelta
            case 1: self = .incorrectDeltaType
            case 2: self = .cannotWriteDeltaForNonDeltaCrdt
            case 3: self = .inputAndStoredDataTypeMismatch
            case 4: self = .unsupportedCrdt
            default: self = .UNRECOGNIZED(rawValue)
            }
        }

        var rawValue: Int {
            switch self {
            case .missingCrdtForDelta: return 0
            case .incorrectDeltaType: return 1
            case .cannotWriteDeltaForNonDeltaCrdt: return 2
            case .inputAndStoredDataTypeMismatch: return 3
            case .unsupportedCrdt: return 4
            case .UNRECOGNIZED(let i): return i
            }
        }
    }

    init() {}
}

#if swift(>=4.2)

extension ProtoCRDTWriteError.TypeEnum: CaseIterable {
    // The compiler won't synthesize support with the UNRECOGNIZED case.
    static var allCases: [ProtoCRDTWriteError.TypeEnum] = [
        .missingCrdtForDelta,
        .incorrectDeltaType,
        .cannotWriteDeltaForNonDeltaCrdt,
        .inputAndStoredDataTypeMismatch,
        .unsupportedCrdt,
    ]
}

#endif // swift(>=4.2)

struct ProtoReplicatedData {
    // SwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
    // methods supported on all messages.

    var payload: OneOf_Payload? {
        get { return self._storage._payload }
        set { _uniqueStorage()._payload = newValue }
    }

    var cvrdt: ProtoAnyCvRDT {
        get {
            if case .cvrdt(let v)? = self._storage._payload { return v }
            return ProtoAnyCvRDT()
        }
        set { _uniqueStorage()._payload = .cvrdt(newValue) }
    }

    var deltaCrdt: ProtoAnyDeltaCRDT {
        get {
            if case .deltaCrdt(let v)? = self._storage._payload { return v }
            return ProtoAnyDeltaCRDT()
        }
        set { _uniqueStorage()._payload = .deltaCrdt(newValue) }
    }

    var unknownFields = SwiftProtobuf.UnknownStorage()

    enum OneOf_Payload: Equatable {
        case cvrdt(ProtoAnyCvRDT)
        case deltaCrdt(ProtoAnyDeltaCRDT)

        #if !swift(>=4.1)
        static func == (lhs: ProtoReplicatedData.OneOf_Payload, rhs: ProtoReplicatedData.OneOf_Payload) -> Bool {
            switch (lhs, rhs) {
            case (.cvrdt(let l), .cvrdt(let r)): return l == r
            case (.deltaCrdt(let l), .deltaCrdt(let r)): return l == r
            default: return false
            }
        }
        #endif
    }

    init() {}

    fileprivate var _storage = _StorageClass.defaultInstance
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension ProtoCRDTReplicatorMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName: String = "CRDTReplicatorMessage"
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "write"),
    ]

    fileprivate class _StorageClass {
        var _value: ProtoCRDTReplicatorMessage.OneOf_Value?

        static let defaultInstance = _StorageClass()

        private init() {}

        init(copying source: _StorageClass) {
            self._value = source._value
        }
    }

    fileprivate mutating func _uniqueStorage() -> _StorageClass {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = _StorageClass(copying: self._storage)
        }
        return self._storage
    }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        _ = self._uniqueStorage()
        try withExtendedLifetime(self._storage) { (_storage: _StorageClass) in
            while let fieldNumber = try decoder.nextFieldNumber() {
                switch fieldNumber {
                case 1:
                    var v: ProtoCRDTWrite?
                    if let current = _storage._value {
                        try decoder.handleConflictingOneOf()
                        if case .write(let m) = current { v = m }
                    }
                    try decoder.decodeSingularMessageField(value: &v)
                    if let v = v { _storage._value = .write(v) }
                default: break
                }
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        try withExtendedLifetime(self._storage) { (_storage: _StorageClass) in
            if case .write(let v)? = _storage._value {
                try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
            }
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ProtoCRDTReplicatorMessage, rhs: ProtoCRDTReplicatorMessage) -> Bool {
        if lhs._storage !== rhs._storage {
            let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
                let _storage = _args.0
                let rhs_storage = _args.1
                if _storage._value != rhs_storage._value { return false }
                return true
            }
            if !storagesAreEqual { return false }
        }
        if lhs.unknownFields != rhs.unknownFields { return false }
        return true
    }
}

extension ProtoCRDTWrite: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName: String = "CRDTWrite"
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "identity"),
        2: .same(proto: "data"),
        3: .same(proto: "replyTo"),
    ]

    fileprivate class _StorageClass {
        var _identity: ProtoCRDTIdentity?
        var _data: ProtoReplicatedData?
        var _replyTo: ProtoActorAddress?

        static let defaultInstance = _StorageClass()

        private init() {}

        init(copying source: _StorageClass) {
            self._identity = source._identity
            self._data = source._data
            self._replyTo = source._replyTo
        }
    }

    fileprivate mutating func _uniqueStorage() -> _StorageClass {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = _StorageClass(copying: self._storage)
        }
        return self._storage
    }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        _ = self._uniqueStorage()
        try withExtendedLifetime(self._storage) { (_storage: _StorageClass) in
            while let fieldNumber = try decoder.nextFieldNumber() {
                switch fieldNumber {
                case 1: try decoder.decodeSingularMessageField(value: &_storage._identity)
                case 2: try decoder.decodeSingularMessageField(value: &_storage._data)
                case 3: try decoder.decodeSingularMessageField(value: &_storage._replyTo)
                default: break
                }
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        try withExtendedLifetime(self._storage) { (_storage: _StorageClass) in
            if let v = _storage._identity {
                try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
            }
            if let v = _storage._data {
                try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
            }
            if let v = _storage._replyTo {
                try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
            }
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ProtoCRDTWrite, rhs: ProtoCRDTWrite) -> Bool {
        if lhs._storage !== rhs._storage {
            let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
                let _storage = _args.0
                let rhs_storage = _args.1
                if _storage._identity != rhs_storage._identity { return false }
                if _storage._data != rhs_storage._data { return false }
                if _storage._replyTo != rhs_storage._replyTo { return false }
                return true
            }
            if !storagesAreEqual { return false }
        }
        if lhs.unknownFields != rhs.unknownFields { return false }
        return true
    }
}

extension ProtoCRDTWriteResult: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName: String = "CRDTWriteResult"
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "type"),
        2: .same(proto: "error"),
    ]

    fileprivate class _StorageClass {
        var _type: ProtoCRDTWriteResult.TypeEnum = .success
        var _error: ProtoCRDTWriteError?

        static let defaultInstance = _StorageClass()

        private init() {}

        init(copying source: _StorageClass) {
            self._type = source._type
            self._error = source._error
        }
    }

    fileprivate mutating func _uniqueStorage() -> _StorageClass {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = _StorageClass(copying: self._storage)
        }
        return self._storage
    }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        _ = self._uniqueStorage()
        try withExtendedLifetime(self._storage) { (_storage: _StorageClass) in
            while let fieldNumber = try decoder.nextFieldNumber() {
                switch fieldNumber {
                case 1: try decoder.decodeSingularEnumField(value: &_storage._type)
                case 2: try decoder.decodeSingularMessageField(value: &_storage._error)
                default: break
                }
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        try withExtendedLifetime(self._storage) { (_storage: _StorageClass) in
            if _storage._type != .success {
                try visitor.visitSingularEnumField(value: _storage._type, fieldNumber: 1)
            }
            if let v = _storage._error {
                try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
            }
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ProtoCRDTWriteResult, rhs: ProtoCRDTWriteResult) -> Bool {
        if lhs._storage !== rhs._storage {
            let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
                let _storage = _args.0
                let rhs_storage = _args.1
                if _storage._type != rhs_storage._type { return false }
                if _storage._error != rhs_storage._error { return false }
                return true
            }
            if !storagesAreEqual { return false }
        }
        if lhs.unknownFields != rhs.unknownFields { return false }
        return true
    }
}

extension ProtoCRDTWriteResult.TypeEnum: SwiftProtobuf._ProtoNameProviding {
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        0: .same(proto: "SUCCESS"),
        1: .same(proto: "FAILED"),
    ]
}

extension ProtoCRDTWriteError: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName: String = "CRDTWriteError"
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "type"),
    ]

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularEnumField(value: &self.type)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if self.type != .missingCrdtForDelta {
            try visitor.visitSingularEnumField(value: self.type, fieldNumber: 1)
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ProtoCRDTWriteError, rhs: ProtoCRDTWriteError) -> Bool {
        if lhs.type != rhs.type { return false }
        if lhs.unknownFields != rhs.unknownFields { return false }
        return true
    }
}

extension ProtoCRDTWriteError.TypeEnum: SwiftProtobuf._ProtoNameProviding {
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        0: .same(proto: "MISSING_CRDT_FOR_DELTA"),
        1: .same(proto: "INCORRECT_DELTA_TYPE"),
        2: .same(proto: "CANNOT_WRITE_DELTA_FOR_NON_DELTA_CRDT"),
        3: .same(proto: "INPUT_AND_STORED_DATA_TYPE_MISMATCH"),
        4: .same(proto: "UNSUPPORTED_CRDT"),
    ]
}

extension ProtoReplicatedData: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName: String = "ReplicatedData"
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "cvrdt"),
        2: .same(proto: "deltaCrdt"),
    ]

    fileprivate class _StorageClass {
        var _payload: ProtoReplicatedData.OneOf_Payload?

        static let defaultInstance = _StorageClass()

        private init() {}

        init(copying source: _StorageClass) {
            self._payload = source._payload
        }
    }

    fileprivate mutating func _uniqueStorage() -> _StorageClass {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = _StorageClass(copying: self._storage)
        }
        return self._storage
    }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        _ = self._uniqueStorage()
        try withExtendedLifetime(self._storage) { (_storage: _StorageClass) in
            while let fieldNumber = try decoder.nextFieldNumber() {
                switch fieldNumber {
                case 1:
                    var v: ProtoAnyCvRDT?
                    if let current = _storage._payload {
                        try decoder.handleConflictingOneOf()
                        if case .cvrdt(let m) = current { v = m }
                    }
                    try decoder.decodeSingularMessageField(value: &v)
                    if let v = v { _storage._payload = .cvrdt(v) }
                case 2:
                    var v: ProtoAnyDeltaCRDT?
                    if let current = _storage._payload {
                        try decoder.handleConflictingOneOf()
                        if case .deltaCrdt(let m) = current { v = m }
                    }
                    try decoder.decodeSingularMessageField(value: &v)
                    if let v = v { _storage._payload = .deltaCrdt(v) }
                default: break
                }
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        try withExtendedLifetime(self._storage) { (_storage: _StorageClass) in
            switch _storage._payload {
            case .cvrdt(let v)?:
                try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
            case .deltaCrdt(let v)?:
                try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
            case nil: break
            }
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ProtoReplicatedData, rhs: ProtoReplicatedData) -> Bool {
        if lhs._storage !== rhs._storage {
            let storagesAreEqual: Bool = withExtendedLifetime((lhs._storage, rhs._storage)) { (_args: (_StorageClass, _StorageClass)) in
                let _storage = _args.0
                let rhs_storage = _args.1
                if _storage._payload != rhs_storage._payload { return false }
                return true
            }
            if !storagesAreEqual { return false }
        }
        if lhs.unknownFields != rhs.unknownFields { return false }
        return true
    }
}
