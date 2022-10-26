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

import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import XCTest

final class RemoteMessagingClusteredTests: ClusteredActorSystemsXCTestCase {
    // TODO: This will start failing once we implement _mangledTypeName manifests
    func test_association_shouldStayAliveWhenMessageSerializationFailsOnReceivingSide() async throws {
        let local = await setUpNode("local") { settings in
            settings.serialization.register(SerializationTestMessage.self)
            settings.serialization.register(EchoTestMessage.self)
        }

        let remote = await setUpNode("remote") { settings in
            // do not register SerializationTestMessage on purpose, we want it to fail when receiving
            settings.serialization.register(EchoTestMessage.self)
        }

        let probeOnRemote = self.testKit(remote).makeTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: _ActorRef<SerializationTestMessage> = try remote._spawn(
            "remoteAcquaintance1",
            .receiveMessage { message in
                probeOnRemote.tell("forwarded:\(message)")
                return .same
            }
        )

        let codableRefOnRemoteSystem: _ActorRef<String> = try remote._spawn(
            "remoteAcquaintance2",
            .receiveMessage { message in
                probeOnRemote.tell("forwarded:\(message)")
                return .same
            }
        )

        local.cluster.join(endpoint: remote.cluster.node.endpoint)

        try assertAssociated(local, withExactly: remote.settings.bindNode)

        let nonCodableResolvedRef = self.resolveRef(local, type: SerializationTestMessage.self, id: nonCodableRefOnRemoteSystem.id, on: remote)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))

        try probeOnRemote.expectNoMessage(for: .milliseconds(500))

        let codableResolvedRef = self.resolveRef(local, type: String.self, id: codableRefOnRemoteSystem.id, on: remote)
        codableResolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    func test_association_shouldStayAliveWhenMessageSerializationThrowsOnSendingSide() async throws {
        try await shouldNotThrow {
            let (local, remote) = await setUpPair { settings in
                settings.serialization.register(SerializationTestMessage.self)
                settings.serialization.register(EchoTestMessage.self)
            }

            let probeOnRemote = self.testKit(remote).makeTestProbe(expecting: String.self)
            let refOnRemoteSystem: _ActorRef<SerializationTestMessage> = try remote._spawn(
                .anonymous,
                .receiveMessage { message in
                    probeOnRemote.tell("forwarded:\(message)")
                    return .same
                }
            )

            local.cluster.join(endpoint: remote.cluster.node.endpoint)

            try assertAssociated(local, withExactly: remote.settings.bindNode)

            let nonCodableResolvedRef = self.resolveRef(local, type: SerializationTestMessage.self, id: refOnRemoteSystem.id, on: remote)
            nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .failEncoding))

            try probeOnRemote.expectNoMessage(for: .milliseconds(100))

            nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))
            try probeOnRemote.expectMessage("forwarded:SerializationTestMessage")
        }
    }

    func test_association_shouldStayAliveWhenMessageSerializationThrowsOnReceivingSide() async throws {
        let (local, remote) = await setUpPair { settings in
            settings.serialization.register(SerializationTestMessage.self)
            settings.serialization.register(EchoTestMessage.self)
        }

        let probeOnRemote = self.testKit(remote).makeTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: _ActorRef<SerializationTestMessage> = try remote._spawn(
            .anonymous,
            .receiveMessage { message in
                probeOnRemote.tell("forwarded:\(message)")
                return .same
            }
        )

        local.cluster.join(endpoint: remote.cluster.node.endpoint)

        try assertAssociated(local, withExactly: remote.settings.bindNode)

        let nonCodableResolvedRef = self.resolveRef(local, type: SerializationTestMessage.self, id: nonCodableRefOnRemoteSystem.id, on: remote)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .failDecoding))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))
        try probeOnRemote.expectMessage("forwarded:SerializationTestMessage")
    }

    func test_sendingToRefWithAddressWhichIsActuallyLocalAddress_shouldWork() async throws {
        let local = await setUpNode("local") { settings in
            settings.serialization.register(SerializationTestMessage.self)
            settings.serialization.register(EchoTestMessage.self)
        }

        let testKit = ActorTestKit(local)
        let probe = testKit.makeTestProbe(expecting: String.self)
        let localRef: _ActorRef<String> = try local._spawn(
            "local",
            .receiveMessage { message in
                probe.tell("received:\(message)")
                return .same
            }
        )

        let localResolvedRefWithLocalAddress =
            self.resolveRef(local, type: String.self, id: localRef.id, on: local)

        localResolvedRefWithLocalAddress.tell("hello")
        try probe.expectMessage("received:hello")
    }

    func test_remoteActors_echo() async throws {
        let (local, remote) = await setUpPair { settings in
            settings.serialization.register(EchoTestMessage.self)
            settings.serialization.register(SerializationTestMessage.self)
            settings.serialization.register(EchoTestMessage.self)
        }

        let probe = self.testKit(local).makeTestProbe("X", expecting: String.self)

        let localRef: _ActorRef<String> = try local._spawn(
            "localRef",
            .receiveMessage { message in
                probe.tell("response:\(message)")
                return .same
            }
        )

        let refOnRemoteSystem: _ActorRef<EchoTestMessage> = try remote._spawn(
            "remoteAcquaintance",
            .receiveMessage { message in
                message.respondTo.tell("echo:\(message.string)")
                return .same
            }
        )

        local.cluster.join(endpoint: remote.cluster.node.endpoint)

        try assertAssociated(local, withExactly: remote.settings.bindNode)

        let remoteRef = self.resolveRef(local, type: EchoTestMessage.self, id: refOnRemoteSystem.id, on: remote)
        remoteRef.tell(EchoTestMessage(string: "test", respondTo: localRef))

        try probe.expectMessage("response:echo:test")
    }

    func test_sendingToNonTopLevelRemoteRef_shouldWork() async throws {
        let (local, remote) = await setUpPair { settings in
            settings.serialization.register(EchoTestMessage.self)
            settings.serialization.register(SerializationTestMessage.self)
            settings.serialization.register(EchoTestMessage.self)
        }

        let probe = self.testKit(local).makeTestProbe("X", expecting: String.self)

        let refOnRemoteSystem: _ActorRef<EchoTestMessage> = try remote._spawn(
            "remoteAcquaintance",
            .receiveMessage { message in
                message.respondTo.tell("echo:\(message.string)")
                return .same
            }
        )

        local.cluster.join(endpoint: remote.cluster.node.endpoint)

        try assertAssociated(local, withExactly: remote.settings.bindNode)

        let remoteRef = self.resolveRef(local, type: EchoTestMessage.self, id: refOnRemoteSystem.id, on: remote)

        let _: _ActorRef<Int> = try local._spawn(
            "localRef",
            .setup { context in
                let child: _ActorRef<String> = try context._spawn(
                    .anonymous,
                    .receiveMessage { message in
                        probe.tell("response:\(message)")
                        return .same
                    }
                )

                remoteRef.tell(EchoTestMessage(string: "test", respondTo: child))

                return .receiveMessage { _ in .same }
            }
        )

        try probe.expectMessage("response:echo:test")
    }

    func test_sendingToRemoteAdaptedRef_shouldWork() async throws {
        let (local, remote) = await setUpPair { settings in
            settings.serialization.register(EchoTestMessage.self)
            settings.serialization.register(SerializationTestMessage.self)
            settings.serialization.register(EchoTestMessage.self)
        }

        let probe = self.testKit(local).makeTestProbe("X", expecting: String.self)

        let refOnRemoteSystem: _ActorRef<EchoTestMessage> = try remote._spawn(
            "remoteAcquaintance",
            .receiveMessage { message in
                message.respondTo.tell("echo:\(message.string)")
                return .same
            }
        )

        local.cluster.join(endpoint: remote.cluster.node.endpoint)

        try assertAssociated(local, withExactly: remote.settings.bindNode)

        let remoteRef = self.resolveRef(local, type: EchoTestMessage.self, id: refOnRemoteSystem.id, on: remote)

        let _: _ActorRef<WrappedString> = try local._spawn(
            "localRef",
            .setup { context in
                let adaptedRef = context.messageAdapter(from: String.self) { WrappedString(string: $0) }
                remoteRef.tell(EchoTestMessage(string: "test", respondTo: adaptedRef))
                return .receiveMessage { message in
                    probe.tell("response:\(message.string)")
                    return .same
                }
            }
        )

        try probe.expectMessage("response:echo:test")
    }

    func test_actorRefsThatWereSentAcrossMultipleNodeHops_shouldBeAbleToReceiveMessages() async throws {
        let (local, remote) = await setUpPair { settings in
            settings.serialization.register(SerializationTestMessage.self)
            settings.serialization.register(EchoTestMessage.self)
        }
        remote.cluster.join(endpoint: local.cluster.node.endpoint)

        try assertAssociated(local, withExactly: remote.cluster.node)

        let thirdSystem = await setUpNode("ClusterAssociationTests") { settings in
            settings.bindPort = 9119
            settings.serialization.register(SerializationTestMessage.self)
            settings.serialization.register(EchoTestMessage.self)
        }
        defer { try! thirdSystem.shutdown().wait() }

        thirdSystem.cluster.join(endpoint: local.cluster.node.endpoint)
        thirdSystem.cluster.join(endpoint: remote.cluster.node.endpoint)
        try assertAssociated(thirdSystem, withExactly: [local.cluster.node, remote.cluster.node])
        let thirdTestKit = ActorTestKit(thirdSystem)

        let localRef: _ActorRef<EchoTestMessage> = try local._spawn(
            "Local",
            .receiveMessage { message in
                message.respondTo.tell("local:\(message.string)")
                return .stop
            }
        )

        let localRefRemote = remote._resolveKnownRemote(localRef, onRemoteSystem: local)

        let remoteRef: _ActorRef<EchoTestMessage> = try remote._spawn(
            "Remote",
            .receiveMessage { message in
                localRefRemote.tell(EchoTestMessage(string: "remote:\(message.string)", respondTo: message.respondTo))
                return .stop
            }
        )

        let remoteRefThird = thirdSystem._resolveKnownRemote(remoteRef, onRemoteSystem: remote)

        let probeThird = thirdTestKit.makeTestProbe(expecting: String.self)

        remoteRefThird.tell(EchoTestMessage(string: "test", respondTo: probeThird.ref))

        try probeThird.expectMessage().shouldEqual("local:remote:test")
    }
}

struct WrappedString: Codable {
    let string: String
}

private enum SerializationBehavior: String, Codable {
    case succeed
    case failEncoding
    case failDecoding
}

private struct SerializationTestMessage: Codable {
    let serializationBehavior: SerializationBehavior
}

extension SerializationTestMessage {
    enum CodingKeys: String, CodingKey {
        case fails
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try !container.decode(Bool.self, forKey: .fails) else {
            throw Boom()
        }

        self.serializationBehavior = .succeed
    }

    func encode(to encoder: Encoder) throws {
        guard self.serializationBehavior != .failEncoding else {
            throw Boom()
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.serializationBehavior == .failDecoding, forKey: .fails)
    }
}

private struct EchoTestMessage: Codable {
    let string: String
    let respondTo: _ActorRef<String>
}

struct Boom: Error {
    let message: String

    init(_ message: String = "") {
        self.message = message
    }
}

extension SerializationTestMessage: CustomStringConvertible {
    var description: String {
        "SerializationTestMessage"
    }
}
