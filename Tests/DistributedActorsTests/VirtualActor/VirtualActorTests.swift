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

final class VirtualActorTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    enum VirtualTestMessage {
        case echo(String, replyTo: ActorRef<String>)
        case stop(replyTo: ActorRef<String>)
        /// doing this breaks the virtual abstraction but ok, we do it on purpose here
        case exposeTrueSelf(replyTo: ActorRef<ActorRef<VirtualTestMessage>>)
    }

    let echoBehavior: Behavior<VirtualTestMessage> = .receive { context, message in
        context.log.info("Received: \(message)")
        switch message {
        case .echo(let string, let replyTo):
            replyTo.tell("echo:\(string)")
        case .stop(let replyTo):
            replyTo.tell("stopping")
            return .stop
        case .exposeTrueSelf(let replyTo):
            replyTo.tell(context.myself)
        }
        return .same
    }

    func test_virtualActor_startsAutomatically() throws {
        let virtualNamespace: VirtualNamespace<VirtualTestMessage> = try VirtualNamespace(system, name: "sensors") {
            // gets started "on demand", whenever a message is sent to an identity that has not been yet started.
            self.echoBehavior
        }

        let ref = virtualNamespace.ref(identifiedBy: "sensor-123")

        let p = self.testKit.spawnTestProbe(expecting: String.self)
        ref.tell(.echo("in the mirror", replyTo: p.ref))

        try p.expectMessage("echo:in the mirror")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Single node

    func test_virtualActor_ensureUniqueness() throws {
        let virtualNamespace = try VirtualNamespace(system, of: VirtualTestMessage.self, name: "sensors") {
            // gets started "on demand", whenever a message is sent to an identity that has not been yet started.
            self.echoBehavior
        }

        // obtain two v-refs to the same entity
        let ref1 = virtualNamespace.ref(identifiedBy: "sensor-123")
        let ref2 = virtualNamespace.ref(identifiedBy: ref1.identity.identifier)

        let p = self.testKit.spawnTestProbe(expecting: String.self)

        ref1.tell(.echo("in the mirror", replyTo: p.ref))
        try p.expectMessage("echo:in the mirror")
        ref2.tell(.echo("rorrim eht ni", replyTo: p.ref))
        try p.expectMessage("echo:rorrim eht ni")

        self.system._printTree()
    }

    func test_virtualActor_exposeTrueSelf() throws {
        let virtualNamespace: VirtualNamespace<VirtualTestMessage> = try VirtualNamespace(system, name: "sensors") {
            // gets started "on demand", whenever a message is sent to an identity that has not been yet started.
            self.echoBehavior
        }

        // obtain two v-refs to the same entity
        let ref1 = virtualNamespace.ref(identifiedBy: "sensor-123")
        let ref2 = virtualNamespace.ref(identifiedBy: ref1.identity.identifier)

        let p = self.testKit.spawnTestProbe(expecting: ActorRef<VirtualTestMessage>.self)

        ref1.tell(.exposeTrueSelf(replyTo: p.ref))
        let ref1p = try p.expectMessage()
        ref2.tell(.exposeTrueSelf(replyTo: p.ref))
        let ref2p = try p.expectMessage()

        self.system._printTree()
        ref2p.shouldEqual(ref1p)
    }
}
