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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

class RemoteMessagingTests: ClusteredNodesTestBase {
    func test_association_shouldStayAliveWhenMessageSerializationFailsOnSendingSide() throws {
        let local = setUpNode("local")

        let remote = setUpNode("remote") {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let probeOnRemote = self.testKit(remote).spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn("remoteAcquaintance1", .receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        })

        let codableRefOnRemoteSystem: ActorRef<String> = try remote.spawn("remoteAcquaintance2", .receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        })

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let nonCodableResolvedRef = self.resolveRef(local, type: SerializationTestMessage.self, address: nonCodableRefOnRemoteSystem.address, on: remote)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        let codableResolvedRef = self.resolveRef(local, type: String.self, address: codableRefOnRemoteSystem.address, on: remote)
        codableResolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    func test_association_shouldStayAliveWhenMessageSerializationFailsOnReceivingSide() throws {
        let local = self.setUpNode("local") {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let remote = setUpNode("remote")

        let probeOnRemote = self.testKit(remote).spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn("remoteAcquaintance1", .receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        })

        let codableRefOnRemoteSystem: ActorRef<String> = try remote.spawn("remoteAcquaintance2", .receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        })

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let nonCodableResolvedRef = self.resolveRef(local, type: SerializationTestMessage.self, address: nonCodableRefOnRemoteSystem.address, on: remote)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        let codableResolvedRef = self.resolveRef(local, type: String.self, address: codableRefOnRemoteSystem.address, on: remote)
        codableResolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    func test_association_shouldStayAliveWhenMessageSerializationThrowsOnSendingSide() throws {
        let (local, remote) = setUpPair {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let probeOnRemote = self.testKit(remote).spawnTestProbe(expecting: String.self)
        let refOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.anonymous, .receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        })

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let nonCodableResolvedRef = self.resolveRef(local, type: SerializationTestMessage.self, address: refOnRemoteSystem.address, on: remote)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .failEncoding))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))
        try probeOnRemote.expectMessage("forwarded:SerializationTestMessage")
    }

    func test_association_shouldStayAliveWhenMessageSerializationThrowsOnReceivingSide() throws {
        let (local, remote) = setUpPair {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let probeOnRemote = self.testKit(remote).spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.anonymous, .receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        })

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let nonCodableResolvedRef = self.resolveRef(local, type: SerializationTestMessage.self, address: nonCodableRefOnRemoteSystem.address, on: remote)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .failDecoding))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))
        try probeOnRemote.expectMessage("forwarded:SerializationTestMessage")
    }

    func test_sendingToRefWithAddressWhichIsActuallyLocalAddress_shouldWork() throws {
        let local = self.setUpNode("local") {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let testKit = ActorTestKit(local)
        let probe = testKit.spawnTestProbe(expecting: String.self)
        let localRef: ActorRef<String> = try local.spawn("local", .receiveMessage { message in
            probe.tell("received:\(message)")
            return .same
        })

        let localResolvedRefWithLocalAddress =
            self.resolveRef(local, type: String.self, address: localRef.address, on: local)

        localResolvedRefWithLocalAddress.tell("hello")
        try probe.expectMessage("received:hello")
    }

    func test_remoteActors_echo() throws {
        let (local, remote) = setUpPair {
            $0.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }

        let probe = self.testKit(local).spawnTestProbe("X", expecting: String.self)

        let localRef: ActorRef<String> = try local.spawn("localRef", .receiveMessage { message in
            probe.tell("response:\(message)")
            return .same
        })

        let refOnRemoteSystem: ActorRef<EchoTestMessage> = try remote.spawn("remoteAcquaintance", .receiveMessage { message in
            message.respondTo.tell("echo:\(message.string)")
            return .same
        })

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let remoteRef = self.resolveRef(local, type: EchoTestMessage.self, address: refOnRemoteSystem.address, on: remote)
        remoteRef.tell(EchoTestMessage(string: "test", respondTo: localRef))

        try probe.expectMessage("response:echo:test")
    }

    func test_sendingToNonTopLevelRemoteRef_shouldWork() throws {
        let (local, remote) = setUpPair {
            $0.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }

        let probe = self.testKit(local).spawnTestProbe("X", expecting: String.self)

        let refOnRemoteSystem: ActorRef<EchoTestMessage> = try remote.spawn("remoteAcquaintance", .receiveMessage { message in
            message.respondTo.tell("echo:\(message.string)")
            return .same
        })

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let remoteRef = self.resolveRef(local, type: EchoTestMessage.self, address: refOnRemoteSystem.address, on: remote)

        let _: ActorRef<Never> = try local.spawn("localRef", .setup { context in
            let child: ActorRef<String> = try context.spawn(.anonymous, .receiveMessage { message in
                probe.tell("response:\(message)")
                return .same
            })

            remoteRef.tell(EchoTestMessage(string: "test", respondTo: child))

            return .receiveMessage { _ in .same }
        })

        try probe.expectMessage("response:echo:test")
    }

    func test_sendingToRemoteAdaptedRef_shouldWork() throws {
        let (local, remote) = setUpPair {
            $0.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }

        let probe = self.testKit(local).spawnTestProbe("X", expecting: String.self)

        let refOnRemoteSystem: ActorRef<EchoTestMessage> = try remote.spawn("remoteAcquaintance", .receiveMessage { message in
            message.respondTo.tell("echo:\(message.string)")
            return .same
        })

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let remoteRef = self.resolveRef(local, type: EchoTestMessage.self, address: refOnRemoteSystem.address, on: remote)

        let _: ActorRef<WrappedString> = try local.spawn("localRef", .setup { context in
            let adaptedRef = context.messageAdapter(from: String.self) { WrappedString(string: $0) }
            remoteRef.tell(EchoTestMessage(string: "test", respondTo: adaptedRef))
            return .receiveMessage { message in
                probe.tell("response:\(message.string)")
                return .same
            }
        })

        try probe.expectMessage("response:echo:test")
    }

    func test_actorRefsThatWereSentAcrossMultipleNodeHops_shouldBeAbleToReceiveMessages() throws {
        let (local, remote) = setUpPair { settings in
            settings.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }
        remote.cluster.join(node: local.cluster.node.node)

        try assertAssociated(local, withExactly: remote.cluster.node)

        let thirdSystem = self.setUpNode("ClusterAssociationTests") { settings in
            settings.cluster.bindPort = 9119
            settings.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }
        defer { thirdSystem.shutdown() }

        thirdSystem.cluster.join(node: local.cluster.node.node)
        thirdSystem.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(thirdSystem, withExactly: [local.cluster.node, remote.cluster.node])
        let thirdTestKit = ActorTestKit(thirdSystem)

        let localRef: ActorRef<EchoTestMessage> = try local.spawn("Local", .receiveMessage { message in
            message.respondTo.tell("local:\(message.string)")
            return .stop
        })

        let localRefRemote = remote._resolveKnownRemote(localRef, onRemoteSystem: local)

        let remoteRef: ActorRef<EchoTestMessage> = try remote.spawn("Remote", .receiveMessage { message in
            localRefRemote.tell(EchoTestMessage(string: "remote:\(message.string)", respondTo: message.respondTo))
            return .stop
        })

        let remoteRefThird = thirdSystem._resolveKnownRemote(remoteRef, onRemoteSystem: remote)

        let probeThird = thirdTestKit.spawnTestProbe(expecting: String.self)

        remoteRefThird.tell(EchoTestMessage(string: "test", respondTo: probeThird.ref))

        try probeThird.expectMessage().shouldEqual("local:remote:test")
    }
}

struct WrappedString {
    let string: String
}

private enum SerializationBehavior {
    case succeed
    case failEncoding
    case failDecoding
}

private struct SerializationTestMessage {
    let serializationBehavior: SerializationBehavior
}

private struct EchoTestMessage: Codable {
    let string: String
    let respondTo: ActorRef<String>
}

struct Boom: Error {
    let message: String

    init(_ message: String = "") {
        self.message = message
    }
}

extension SerializationTestMessage: Codable {
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

extension SerializationTestMessage: CustomStringConvertible {
    var description: String {
        return "SerializationTestMessage"
    }
}
