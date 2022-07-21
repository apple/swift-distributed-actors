//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class RemoteCallTests: ClusteredActorSystemsXCTestCase {
    func test_remoteCall() async throws {
        let local = await setUpNode("local") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        let remote = await setUpNode("remote") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let value = try await shouldNotThrow {
            try await remoteGreeterRef.hello()
        }
        value.shouldEqual("hello")
    }

    func test_remoteCall_shouldCarryBackThrownError_Codable() async throws {
        let local = await setUpNode("local") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        let remote = await setUpNode("remote") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            _ = try await remoteGreeterRef.helloThrow(codable: true)
        }
        guard error is GreeterCodableError else {
            throw TestError("Expected GreeterCodableError, got \(error)")
        }
    }

    func test_remoteCall_shouldCarryBackThrownError_nonCodable() async throws {
        let local = await setUpNode("local") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        let remote = await setUpNode("remote") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            _ = try await remoteGreeterRef.helloThrow(codable: false)
        }
        guard let remoteCallError = error as? GenericRemoteCallError else {
            throw TestError("Expected GenericRemoteCallError, got \(error)")
        }
        remoteCallError.message.shouldStartWith(prefix: "Remote call error of [GreeterNonCodableError] type occurred")
    }

    func test_remoteCallVoid() async throws {
        let local = await setUpNode("local")
        let remote = await setUpNode("remote") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        try await shouldNotThrow {
            try await remoteGreeterRef.muted()
        }
    }

    func test_remoteCallVoid_shouldCarryBackThrownError_Codable() async throws {
        let local = await setUpNode("local")
        let remote = await setUpNode("remote") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            try await remoteGreeterRef.mutedThrow(codable: true)
        }
        guard error is GreeterCodableError else {
            throw TestError("Expected GreeterCodableError, got \(error)")
        }
    }

    func test_remoteCallVoid_shouldCarryBackThrownError_nonCodable() async throws {
        let local = await setUpNode("local")
        let remote = await setUpNode("remote") { settings in
            settings.serialization.registerInbound(GreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            try await remoteGreeterRef.mutedThrow(codable: false)
        }
        guard let remoteCallError = error as? GenericRemoteCallError else {
            throw TestError("Expected GenericRemoteCallError, got \(error)")
        }
        remoteCallError.message.shouldStartWith(prefix: "Remote call error of [GreeterNonCodableError] type occurred")
    }

    func test_remoteCall_shouldConfigureTimeout() async throws {
        let local = await setUpNode("local")
        let remote = await setUpNode("remote")
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            try await RemoteCall.with(timeout: .milliseconds(200)) {
                _ = try await remoteGreeterRef.hello(delayNanos: 3_000_000_000)
            }
        }

        guard case RemoteCallError.timedOut(_, let timeoutError) = error else {
            throw TestError("Expected RemoteCallError.timedOut, got \(error)")
        }
        guard timeoutError.timeout == .milliseconds(200) else {
            throw TestError("Expected timeout to be 200 milliseconds but was \(timeoutError.timeout)")
        }
    }

    func test_remoteCallVoid_shouldConfigureTimeout() async throws {
        let local = await setUpNode("local")
        let remote = await setUpNode("remote")
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            try await RemoteCall.with(timeout: .milliseconds(200)) {
                try await remoteGreeterRef.muted(delayNanos: 3_000_000_000)
            }
        }

        guard case RemoteCallError.timedOut(_, let timeoutError) = error else {
            throw TestError("Expected RemoteCallError.timedOut, got \(error)")
        }
        guard timeoutError.timeout == .milliseconds(200) else {
            throw TestError("Expected timeout to be 200 milliseconds but was \(timeoutError.timeout)")
        }
    }

    func test_remoteCallGeneric() async throws {
        let local = await setUpNode("local")
        let remote = await setUpNode("remote")
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let message: String = "hello"
        let value = try await shouldNotThrow {
            try await remoteGreeterRef.genericEcho(message)
        }
        value.shouldEqual(message)
    }

    func test_remoteCall_codableErrorAllowList_all() async throws {
        let local = await setUpNode("local") { settings in
            settings.remoteCall.codableErrorAllowance = .all
            settings.serialization.registerInbound(GreeterCodableError.self)
            settings.serialization.registerInbound(AnotherGreeterCodableError.self)
        }
        let remote = await setUpNode("remote") { settings in
            settings.remoteCall.codableErrorAllowance = .all
            settings.serialization.registerInbound(GreeterCodableError.self)
            settings.serialization.registerInbound(AnotherGreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            _ = try await remoteGreeterRef.helloThrow(codable: true)
        }
        guard error is GreeterCodableError else {
            throw TestError("Expected GreeterCodableError, got \(error)")
        }
    }

    func test_remoteCall_codableErrorAllowList_none() async throws {
        let local = await setUpNode("local") { settings in
            settings.remoteCall.codableErrorAllowance = .none
            settings.serialization.registerInbound(GreeterCodableError.self)
            settings.serialization.registerInbound(AnotherGreeterCodableError.self)
        }
        let remote = await setUpNode("remote") { settings in
            settings.remoteCall.codableErrorAllowance = .none
            settings.serialization.registerInbound(GreeterCodableError.self)
            settings.serialization.registerInbound(AnotherGreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            _ = try await remoteGreeterRef.helloThrow(codable: true)
        }
        guard let remoteCallError = error as? GenericRemoteCallError else {
            throw TestError("Expected GenericRemoteCallError, got \(error)")
        }
        remoteCallError.message.shouldStartWith(prefix: "Remote call error of [GreeterCodableError] type occurred")
    }

    func test_remoteCall_customCodableErrorAllowList_errorInList() async throws {
        let local = await setUpNode("local") { settings in
            settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [GreeterCodableError.self, AnotherGreeterCodableError.self])
            settings.serialization.registerInbound(GreeterCodableError.self)
            settings.serialization.registerInbound(AnotherGreeterCodableError.self)
        }
        let remote = await setUpNode("remote") { settings in
            settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [GreeterCodableError.self, AnotherGreeterCodableError.self])
            settings.serialization.registerInbound(GreeterCodableError.self)
            settings.serialization.registerInbound(AnotherGreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            _ = try await remoteGreeterRef.helloThrow(codable: true)
        }
        guard error is GreeterCodableError else {
            throw TestError("Expected GreeterCodableError, got \(error)")
        }
    }

    func test_remoteCall_customCodableErrorAllowList_errorInListButNotRegistered() async throws {
        let local = await setUpNode("local") { settings in
            settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [GreeterCodableError.self, AnotherGreeterCodableError.self])
        }
        let remote = await setUpNode("remote") { settings in
            settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [GreeterCodableError.self, AnotherGreeterCodableError.self])
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            try await RemoteCall.with(timeout: .milliseconds(200)) {
                _ = try await remoteGreeterRef.helloThrow(codable: true)
            }
        }
        guard case RemoteCallError.timedOut = error else {
            throw TestError("Expected RemoteCallError.timedOut, got \(error)")
        }
    }

    func test_remoteCall_customCodableErrorAllowList_errorNotInList() async throws {
        let local = await setUpNode("local") { settings in
            settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [AnotherGreeterCodableError.self])
            settings.serialization.registerInbound(GreeterCodableError.self)
            settings.serialization.registerInbound(AnotherGreeterCodableError.self)
        }
        let remote = await setUpNode("remote") { settings in
            settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [AnotherGreeterCodableError.self])
            settings.serialization.registerInbound(GreeterCodableError.self)
            settings.serialization.registerInbound(AnotherGreeterCodableError.self)
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: local)
        let remoteGreeterRef = try Greeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            _ = try await remoteGreeterRef.helloThrow(codable: true)
        }
        guard let remoteCallError = error as? GenericRemoteCallError else {
            throw TestError("Expected GenericRemoteCallError, got \(error)")
        }
        remoteCallError.message.shouldStartWith(prefix: "Remote call error of [GreeterCodableError] type occurred")
    }
}

private distributed actor Greeter {
    typealias ActorSystem = ClusterSystem

    distributed func hello() async throws -> String {
        "hello"
    }

    distributed func helloThrow(codable: Bool) async throws -> String {
        if codable {
            throw GreeterCodableError()
        } else {
            throw GreeterNonCodableError()
        }
    }

    distributed func hello(delayNanos: UInt64) async throws -> String {
        try await Task.sleep(nanoseconds: delayNanos)
        return try await self.hello()
    }

    distributed func muted() async throws {}

    distributed func mutedThrow(codable: Bool) async throws {
        if codable {
            throw GreeterCodableError()
        } else {
            throw GreeterNonCodableError()
        }
    }

    distributed func muted(delayNanos: UInt64) async throws {
        try await Task.sleep(nanoseconds: delayNanos)
        try await self.muted()
    }

    distributed func genericEcho<T: Sendable & Codable>(_ message: T) -> T {
        message
    }
}

private struct GreeterCodableError: Error, Codable {}
private struct GreeterNonCodableError: Error {}
private struct AnotherGreeterCodableError: Error, Codable {}
