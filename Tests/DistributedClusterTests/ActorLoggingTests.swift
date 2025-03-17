//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
import Foundation
import XCTest
import Logging

@testable import DistributedCluster

final class ActorLoggingTests: SingleClusterSystemXCTestCase {
    var exampleSenderPath: ActorPath!

    override func setUp() {
        super.setUp()

        self.exampleSenderPath = try! ActorPath(root: "user")
        self.exampleSenderPath.append(segment: try! ActorPathSegment("hello"))
        self.exampleSenderPath.append(segment: try! ActorPathSegment("deep"))
        self.exampleSenderPath.append(segment: try! ActorPathSegment("path"))
        self.exampleSenderPath.append(segment: try! ActorPathSegment("avoid-rendering-this-if-possible"))
    }

    func test_actorLogger_shouldIncludeActorPath() throws {
        let p = self.testKit.makeTestProbe("p", expecting: String.self)
        let r = self.testKit.makeTestProbe("r", expecting: Rendered.self)

        let ref: _ActorRef<String> = try system._spawn(
            "myName",
            .setup { context in
                // ~~~~~~~ (imagine as) set by swift-distributed-actors library internally ~~~~~~~~~~
                context.log[metadataKey: "senderPath"] = .lazyStringConvertible {
                    r.ref.tell(.instance)
                    return self.exampleSenderPath.description
                }
                // ~~~~ end of (imagine as) set by swift-distributed-actors library internally ~~~~~~

                return .receiveMessage { message in
                    context.log.info("I got \(message)")

                    p.ref.tell("Got: \(message)")
                    return .same
                }
            }
        )

        ref.tell("Hello world")
        try p.expectMessage("Got: Hello world")
        // try r.expectNoMessage(for: .milliseconds(100))
    }

    func test_actorLogger_shouldNotRenderLazyMetadataIfLogIsUnderDefinedLogLevel() throws {
        let p = self.testKit.makeTestProbe("p2", expecting: String.self)
        let r = self.testKit.makeTestProbe("r2", expecting: Rendered.self)

        let ref: _ActorRef<String> = try system._spawn(
            "myName",
            .setup { context in
                // ~~~~~~~ (imagine as) set by swift-distributed-actors library internally ~~~~~~~~~~
                context.log[metadataKey: "senderPath"] = .lazyStringConvertible {
                    r.ref.tell(.instance)
                    return self.exampleSenderPath.description
                }
                // ~~~~ end of (imagine as) set by swift-distributed-actors library internally ~~~~~~

                return .receiveMessage { message in
                    context.log.logLevel = .warning
                    context.log.info("I got \(message)")  // thus should not render any metadata

                    p.ref.tell("Got: \(message)")
                    return .same
                }
            }
        )

        ref.tell("Hello world")
        try p.expectMessage("Got: Hello world")
        try r.expectNoMessage(for: .milliseconds(100))
    }

    func test_actorLogger_shouldNotRenderALazyValueIfWeOverwriteItUsingLocalMetadata() throws {
        let p = self.testKit.makeTestProbe("p2", expecting: String.self)
        let r = self.testKit.makeTestProbe("r2", expecting: Rendered.self)

        let ref: _ActorRef<String> = try system._spawn(
            "myName",
            .setup { context in
                // ~~~~~~~ (imagine as) set by swift-distributed-actors library internally ~~~~~~~~~~
                context.log[metadataKey: "senderPath"] = .lazyStringConvertible {
                    r.ref.tell(.instance)
                    return self.exampleSenderPath.description
                }
                // ~~~~ end of (imagine as) set by swift-distributed-actors library internally ~~~~~~

                return .receiveMessage { message in
                    // overwrite the metadata with a local one:
                    context.log.info("I got \(message)", metadata: ["senderPath": .string("/user/sender/pre-rendered")])

                    p.ref.tell("Got: \(message)")
                    return .same
                }
            }
        )

        ref.tell("Hello world")
        try p.expectMessage("Got: Hello world")
        try r.expectNoMessage(for: .milliseconds(100))
    }
}

private enum Rendered: String, Codable {
    case instance
}
