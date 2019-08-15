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
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

class RemotingMessagingTests: ClusteredTwoNodesTestBase {
    func test_association_shouldStayAliveWhenMessageSerializationFailsOnSendingSide() throws {
        setUpLocal()

        setUpRemote {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance")

        let codableRefOnRemoteSystem: ActorRef<String> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance2")


        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueNode.node, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindNode)

        let nonCodableResolvedRef = self.resolveRemoteRef(on: self.local, type: SerializationTestMessage.self, address: nonCodableRefOnRemoteSystem.address)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        let codableResolvedRef = self.resolveRemoteRef(on: self.local, type: String.self, address: codableRefOnRemoteSystem.address)
        codableResolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    func test_association_shouldStayAliveWhenMessageSerializationFailsOnReceivingSide() throws {
        setUpLocal {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        setUpRemote()

        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance")

        let codableRefOnRemoteSystem: ActorRef<String> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance2")


        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueNode.node, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindNode)

        let nonCodableResolvedRef = self.resolveRemoteRef(on: self.local, type: SerializationTestMessage.self, address: nonCodableRefOnRemoteSystem.address)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        let codableResolvedRef = self.resolveRemoteRef(on: self.local, type: String.self, address: codableRefOnRemoteSystem.address)
        codableResolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    func test_association_shouldStayAliveWhenMessageSerializationThrowsOnSendingSide() throws {
        setUpBoth {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let refOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance")


        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueNode.node, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindNode)

        let nonCodableResolvedRef = self.resolveRemoteRef(on: self.local, type: SerializationTestMessage.self, address: refOnRemoteSystem.address)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .failEncoding))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))
        try probeOnRemote.expectMessage("forwarded:SerializationTestMessage")
    }

    func test_association_shouldStayAliveWhenMessageSerializationThrowsOnReceivingSide() throws {
        setUpBoth {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance")


        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueNode.node, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindNode)

        let nonCodableResolvedRef = self.resolveRemoteRef(on: self.local, type: SerializationTestMessage.self, address: nonCodableRefOnRemoteSystem.address)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .failDecoding))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))
        try probeOnRemote.expectMessage("forwarded:SerializationTestMessage")
    }

    func test_sendingToRefWithAddressWhichIsActuallyLocalAddress_shouldWork() throws {
        setUpLocal {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let testKit = ActorTestKit(self.local)
        let probe = testKit.spawnTestProbe(expecting: String.self)
        let localRef: ActorRef<String> = try local.spawn(.receiveMessage { message in
            probe.tell("received:\(message)")
            return .same
        }, name: "local")

        let localResolvedRefWithLocalAddress =
            self.resolveLocalRef(on: self.local, type: String.self, address: localRef.address)

        localResolvedRefWithLocalAddress.tell("hello")
        try probe.expectMessage("received:hello")
    }

    func test_remoteActors_echo() throws {
        setUpBoth {
            $0.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }

        let probe = self.localTestKit.spawnTestProbe(name: "X", expecting: String.self)

        let localRef: ActorRef<String> = try local.spawn(.receiveMessage { message in
                probe.tell("response:\(message)")
                return .same
            }, name: "localRef")

        let refOnRemoteSystem: ActorRef<EchoTestMessage> = try remote.spawn(.receiveMessage { message in
                message.respondTo.tell("echo:\(message.string)")
                return .same
            }, name: "remoteAcquaintance")

        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueNode.node, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindNode)

        let remoteRef = self.resolveRemoteRef(on: self.local, type: EchoTestMessage.self, address: refOnRemoteSystem.address)
        remoteRef.tell(EchoTestMessage(string: "test", respondTo: localRef))

        try probe.expectMessage("response:echo:test")
    }

    func test_sendingToNonTopLevelRemoteRef_shouldWork() throws {
        setUpBoth {
            $0.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }

        let probe = self.localTestKit.spawnTestProbe(name: "X", expecting: String.self)

        let refOnRemoteSystem: ActorRef<EchoTestMessage> = try remote.spawn(.receiveMessage { message in
                message.respondTo.tell("echo:\(message.string)")
                return .same
            }, name: "remoteAcquaintance")

        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueNode.node, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindNode)

        let remoteRef = self.resolveRemoteRef(on: self.local, type: EchoTestMessage.self, address: refOnRemoteSystem.address)

        let _: ActorRef<Never> = try local.spawn(.setup { context in
                let child: ActorRef<String> = try context.spawnAnonymous(.receiveMessage { message in
                    probe.tell("response:\(message)")
                    return .same
                })

                remoteRef.tell(EchoTestMessage(string: "test", respondTo: child))

                return .receiveMessage { _ in .same }
            }, name: "localRef")

        try probe.expectMessage("response:echo:test")
    }
    
    func test_sendingToRemoteAdaptedRef_shouldWork() throws {
        setUpBoth {
            $0.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }

        let probe = self.localTestKit.spawnTestProbe(name: "X", expecting: String.self)

        let refOnRemoteSystem: ActorRef<EchoTestMessage> = try remote.spawn(.receiveMessage { message in
            message.respondTo.tell("echo:\(message.string)")
            return .same
        }, name: "remoteAcquaintance")

        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueNode.node, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindNode)

        let remoteRef = self.resolveRemoteRef(on: self.local, type: EchoTestMessage.self, address: refOnRemoteSystem.address)

        let _: ActorRef<WrappedString> = try local.spawn(.setup { context in
            let adaptedRef = context.messageAdapter(String.self) { WrappedString(string: $0) }
            remoteRef.tell(EchoTestMessage(string: "test", respondTo: adaptedRef))
            return .receiveMessage { message in
                probe.tell("response:\(message.string)")
                return .same
            }
        }, name: "localRef")

        try probe.expectMessage("response:echo:test")
    }

    func test_actorRefsThatWereSentAcrossMultipleNodeHops_shouldBeAbleToReceiveMessages() throws {
        setUpBoth { settings in
            settings.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }
        remote.cluster.join(node: self.localUniqueNode.node)

        try assertAssociated(local, with: self.remoteUniqueNode)

        let thirdSystem = ActorSystem("ClusterAssociationTests") { settings in
            settings.cluster.enabled = true
            settings.cluster.bindPort = 9119
            settings.serialization.registerCodable(for: EchoTestMessage.self, underId: 1001)
        }
        defer { thirdSystem.shutdown() }

        thirdSystem.cluster.join(node: self.localUniqueNode.node)
        thirdSystem.cluster.join(node: self.remoteUniqueNode.node)
        try assertAssociated(thirdSystem, withExactly: [self.localUniqueNode, self.remoteUniqueNode])
        let thirdTestKit = ActorTestKit(thirdSystem)

        let localRef: ActorRef<EchoTestMessage> = try local.spawn(.receiveMessage { message in
            message.respondTo.tell("local:\(message.string)")
            return .stop
        }, name: "Local")

        let localRefRemote = remote._resolveKnownRemote(localRef, onRemoteSystem: local)

        let remoteRef: ActorRef<EchoTestMessage> = try remote.spawn(.receiveMessage { message in
            localRefRemote.tell(EchoTestMessage(string: "remote:\(message.string)", respondTo: message.respondTo))
            return .stop
        }, name: "Remote")

        let remoteRefThird = thirdSystem._resolveKnownRemote(remoteRef, onRemoteSystem: remote)

        let probeThird = thirdTestKit.spawnTestProbe(expecting: String.self)

        remoteRefThird.tell(EchoTestMessage(string: "test", respondTo: probeThird.ref))

        try probeThird.expectMessage().shouldEqual("local:remote:test")
    }
}

struct WrappedString {
    let string: String
}

fileprivate enum SerializationBehavior {
    case succeed
    case failEncoding
    case failDecoding
}

fileprivate struct SerializationTestMessage {
    let serializationBehavior: SerializationBehavior
}

fileprivate struct EchoTestMessage: Codable {
    let string: String
    let respondTo: ActorRef<String>
}

struct Boom: Error {}

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
