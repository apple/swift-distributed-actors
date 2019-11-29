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

class VirtualActorTests: XCTestCase {
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
    }

    func test_virtualActor_startsAutomatically() throws {
        let echoBehavior: Behavior<VirtualTestMessage> = .receive { context, message in
            context.log.info("Received: \(message)")
            switch message {
            case .echo(let string, let replyTo):
                replyTo.tell("echo:\(string)")
            }
            return .stop
        }

        let virtualNamespace: VirtualNamespace<VirtualTestMessage> = try VirtualNamespace(system, name: "sensors") {
            // gets started "on demand", whenever a message is sent to an identity that has not been yet started.
            echoBehavior
        }

        let ref: ActorRef<VirtualTestMessage> = virtualNamespace.lookup(identity: "sensor-123")

        let p = testKit.spawnTestProbe(expecting: String.self)
        ref.tell(.echo("in the mirror", replyTo: p.ref))

        try p.expectMessage("echo:in the mirror")
    }
}

