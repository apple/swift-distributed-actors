//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import Logging
import NIO
import NIOFoundationCompat
import SwiftProtobuf
import SWIM

import Foundation // for Codable

public struct ClusterInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = any Codable
    var arguments: [Data] = []
    var throwing: Bool = false

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        fatalError("NOT IMPLEMENTED: \(#function)")
    }

    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
        let encoder = JSONEncoder()
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

// FIXME(distributed): make it a struct once rdar://88211172 ([Distributed] SILGen must emit uses of decodeNextArgument so IRGen can get it cross module on `FINAL classes`) is fixed
public struct ClusterInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = any Codable

    let system: ClusterSystem
    let message: InvocationMessage
    var argumentIdx = 0

    public init(system: ClusterSystem, message: InvocationMessage) {
        self.system = system
        self.message = message
    }

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        fatalError("NOT IMPLEMENTED: \(#function)")
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard self.message.arguments.count > self.argumentIdx else {
            throw SerializationError.notEnoughArgumentsEncoded(expected: self.argumentIdx + 1, have: self.message.arguments.count)
        }

        let argumentData = self.message.arguments[self.argumentIdx]
        self.argumentIdx += 1

        // TODO: get serializer for it
        var decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = self.system

        let argument = try decoder.decode(Argument.self, from: argumentData)
        return argument
    }

    public mutating func decodeErrorType() throws -> Any.Type? {
        return nil // TODO(distributed): might need this
    }

    public mutating func decodeReturnType() throws -> Any.Type? {
        return nil // TODO(distributed): might need this
    }
}
