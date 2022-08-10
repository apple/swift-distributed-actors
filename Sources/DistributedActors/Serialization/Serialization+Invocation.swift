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
import Foundation // for Codable
import Logging
import NIO
import NIOFoundationCompat
import SwiftProtobuf

public struct ClusterInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = any Codable

    var arguments: [Data] = []
    var genericSubstitutions: [String] = []
    var throwing: Bool = false

    let system: ClusterSystem

    init(system: ClusterSystem) {
        self.system = system
    }

    init(system: ClusterSystem, arguments: [Data]) {
        self.system = system
        self.arguments = arguments
        self.throwing = false
    }

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        let typeName = _mangledTypeName(type) ?? _typeName(type)
        self.genericSubstitutions.append(typeName)
    }

    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
//        let serialized = try self.system.serialization.serialize(argument.value)
//        let data = serialized.buffer.readData()
        let encoder = JSONEncoder()
        encoder.userInfo[.actorSystemKey] = self.system
        encoder.userInfo[.actorSerializationContext] = self.system.serialization.context
        let data = try encoder.encode(argument.value)
        self.arguments.append(data)
    }

    public mutating func recordReturnType<Success: Codable>(_ returnType: Success.Type) throws {}

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
        self.throwing = true
    }

    public mutating func doneRecording() throws {
        // noop
    }
}

public struct ClusterInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = any Codable

    let system: ClusterSystem
    let state: _State
    enum _State {
        case remoteCall(message: InvocationMessage)
        // Potentially used by interceptors, when invoking a local target directly
        case localProxyCall(ClusterSystem.InvocationEncoder)
    }

    var argumentIdx = 0

    public init(system: ClusterSystem, message: InvocationMessage) {
        self.system = system
        self.state = .remoteCall(message: message)
    }

    init(system: ClusterSystem, invocation: ClusterSystem.InvocationEncoder) {
        self.system = system
        self.state = .localProxyCall(invocation)
    }

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        let genericSubstitutions: [String]
        switch self.state {
        case .remoteCall(let message):
            genericSubstitutions = message.genericSubstitutions
        case .localProxyCall(let invocation):
            genericSubstitutions = invocation.genericSubstitutions
        }

        return try genericSubstitutions.map {
            guard let type = _typeByName($0) else {
                throw SerializationError(.notAbleToDeserialize(hint: $0))
            }
            return type
        }
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        let argumentData: Data

        switch self.state {
        case .remoteCall(let message):
            guard self.argumentIdx < message.arguments.count else {
                throw SerializationError(.notEnoughArgumentsEncoded(expected: self.argumentIdx + 1, have: message.arguments.count))
            }

            argumentData = message.arguments[self.argumentIdx]
            self.argumentIdx += 1

            let manifest = try system.serialization.outboundManifest(Argument.self)

            let serialized = Serialization.Serialized(
                manifest: manifest,
                buffer: Serialization.Buffer.data(argumentData)
            )
            let argument = try system.serialization.deserialize(as: Argument.self, from: serialized)
//            let decoder = JSONDecoder()
//            decoder.userInfo[.actorSystemKey] = self.system
//            decoder.userInfo[.actorSerializationContext] = self.system.serialization.context
//            let argument = try decoder.decode(Argument.self, from: serialized.buffer.readData())
            return argument

        case .localProxyCall(let invocation):
            // TODO: potentially able to optimize and avoid serialization round trip for such calls
            guard self.argumentIdx < invocation.arguments.count else {
                throw SerializationError(.notEnoughArgumentsEncoded(expected: self.argumentIdx + 1, have: invocation.arguments.count))
            }

            argumentData = invocation.arguments[self.argumentIdx]
            self.argumentIdx += 1
        }

        // FIXME: make incoming manifest
        let manifest = try self.system.serialization.outboundManifest(Argument.self)

        let serialized = Serialization.Serialized(
            manifest: manifest,
            buffer: Serialization.Buffer.data(argumentData)
        )
        let argument = try self.system.serialization.deserialize(as: Argument.self, from: serialized)
        return argument
    }

    public mutating func decodeErrorType() throws -> Any.Type? {
        return nil // TODO(distributed): might need this
    }

    public mutating func decodeReturnType() throws -> Any.Type? {
        return nil // TODO(distributed): might need this
    }
}
