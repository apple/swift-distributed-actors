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

class RemotingMessagingTests: RemotingTestBase {

    override var systemName: String {
        return "2RemotingMessagingTests"
    }

    func test_association_shouldStayAliveWhenMessageSerializationFailsOnSendingSide() throws {
        setUpLocal()

        setUpRemote {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let remoteTestKit = ActorTestKit(remote)
        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance")

        let codableRefOnRemoteSystem: ActorRef<String> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance2")


        local.remoting.tell(.command(.handshakeWith(remoteUniqueAddress.address))) // TODO nicer API
        sleep(2) // TODO make it such that we don't need to sleep but assertions take care of it

        try assertAssociated(system: local, expectAssociatedAddress: remote.settings.remoting.uniqueBindAddress)

        let nonCodableResolvedRef = self.resolveRemoteRef(type: SerializationTestMessage.self, path: nonCodableRefOnRemoteSystem.path)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        let codableResolvedRef = self.resolveRemoteRef(type: String.self, path: codableRefOnRemoteSystem.path)
        codableResolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    func test_association_shouldStayAliveWhenMessageSerializationFailsOnReceivingSide() throws {
        setUpLocal {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        setUpRemote()

        let remoteTestKit = ActorTestKit(remote)
        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance")

        let codableRefOnRemoteSystem: ActorRef<String> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance2")


        local.remoting.tell(.command(.handshakeWith(remoteUniqueAddress.address))) // TODO nicer API
        sleep(2) // TODO make it such that we don't need to sleep but assertions take care of it

        try assertAssociated(system: local, expectAssociatedAddress: remote.settings.remoting.uniqueBindAddress)

        let nonCodableResolvedRef = self.resolveRemoteRef(type: SerializationTestMessage.self, path: nonCodableRefOnRemoteSystem.path)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        let codableResolvedRef = self.resolveRemoteRef(type: String.self, path: codableRefOnRemoteSystem.path)
        codableResolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    func test_association_shouldStayAliveWhenMessageSerializationThrowsOnSendingSide() throws {
        setUpLocal {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        setUpRemote {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let remoteTestKit = ActorTestKit(remote)
        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let refOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance")


        local.remoting.tell(.command(.handshakeWith(remoteUniqueAddress.address))) // TODO nicer API
        sleep(2) // TODO make it such that we don't need to sleep but assertions take care of it

        try assertAssociated(system: local, expectAssociatedAddress: remote.settings.remoting.uniqueBindAddress)

        let nonCodableResolvedRef = self.resolveRemoteRef(type: SerializationTestMessage.self, path: refOnRemoteSystem.path)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .failEncoding))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))
        try probeOnRemote.expectMessage("forwarded:SerializationTestMessage")
    }

    func test_association_shouldStayAliveWhenMessageSerializationThrowsOnReceivingSide() throws {
        setUpLocal {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        setUpRemote {
            $0.serialization.registerCodable(for: SerializationTestMessage.self, underId: 1001)
        }

        let remoteTestKit = ActorTestKit(remote)
        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let nonCodableRefOnRemoteSystem: ActorRef<SerializationTestMessage> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
            }, name: "remoteAcquaintance")


        local.remoting.tell(.command(.handshakeWith(remoteUniqueAddress.address))) // TODO nicer API
        sleep(2) // TODO make it such that we don't need to sleep but assertions take care of it

        try assertAssociated(system: local, expectAssociatedAddress: remote.settings.remoting.uniqueBindAddress)

        let nonCodableResolvedRef = self.resolveRemoteRef(type: SerializationTestMessage.self, path: nonCodableRefOnRemoteSystem.path)
        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .failDecoding))

        try probeOnRemote.expectNoMessage(for: .milliseconds(100))

        nonCodableResolvedRef.tell(SerializationTestMessage(serializationBehavior: .succeed))
        try probeOnRemote.expectMessage("forwarded:SerializationTestMessage")
    }
}

fileprivate enum SerializationBehavior {
    case succeed
    case failEncoding
    case failDecoding
}

fileprivate struct SerializationTestMessage {
    let serializationBehavior: SerializationBehavior
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
