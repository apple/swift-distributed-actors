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
    public internal(set) var arguments: [Data] = []
    var throwing: Bool = false

    let system: ClusterSystem

    init(system: ClusterSystem) {
        self.system = system
    }
    
    public init(system: ClusterSystem, arguments: [Data]) {
        self.system = system
        self.arguments = arguments
        self.throwing = true
    }

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        fatalError("NOT IMPLEMENTED: \(#function)")
    }

    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
        let serialized = try self.system.serialization.serialize(argument.value)
        let data = serialized.buffer.readData()
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

    let state: _State
    enum _State {
<<<<<<< HEAD
        case remoteCall(system: ClusterSystem, message: InvocationMessage)
        // Potentially used by interceptors, when invoking a local target directly
        case localProxyCall(ClusterSystem.InvocationEncoder)
    }

=======
        case remoteCall(system: ClusterSystem,message: InvocationMessage)
        // Potentially used by interceptors, when invoking a local target directly
        case localProxyCall(ClusterSystem.InvocationEncoder)
    }
>>>>>>> rework how we get hold of intercepted actors
    var argumentIdx = 0

    public init(system: ClusterSystem, message: InvocationMessage) {
        self.state = .remoteCall(system: system, message: message)
    }
<<<<<<< HEAD

=======
    
>>>>>>> rework how we get hold of intercepted actors
    internal init(invocation: ClusterSystem.InvocationEncoder) {
        self.state = .localProxyCall(invocation)
    }

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        fatalError("NOT IMPLEMENTED: \(#function)")
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        switch self.state {
        case .remoteCall(let system, let message):
            guard message.arguments.count > self.argumentIdx else {
                throw SerializationError.notEnoughArgumentsEncoded(expected: self.argumentIdx + 1, have: message.arguments.count)
            }

            let argumentData = message.arguments[self.argumentIdx]
            self.argumentIdx += 1

            // FIXME: make incoming manifest
            let manifest = try system.serialization.outboundManifest(Argument.self)

            let serialized = Serialization.Serialized(
                manifest: manifest,
                buffer: Serialization.Buffer.data(argumentData)
            )
            let argument = try system.serialization.deserialize(as: Argument.self, from: serialized)
            return argument
<<<<<<< HEAD

=======
            
>>>>>>> rework how we get hold of intercepted actors
        case .localProxyCall(let invocation):
            guard invocation.arguments.count > self.argumentIdx else {
                throw SerializationError.notEnoughArgumentsEncoded(expected: self.argumentIdx + 1, have: invocation.arguments.count)
            }
<<<<<<< HEAD

=======
            
>>>>>>> rework how we get hold of intercepted actors
            self.argumentIdx += 1
            return invocation.arguments[self.argumentIdx] as! Argument
        }
    }

    public mutating func decodeErrorType() throws -> Any.Type? {
        return nil // TODO(distributed): might need this
    }

    public mutating func decodeReturnType() throws -> Any.Type? {
        return nil // TODO(distributed): might need this
    }
}
