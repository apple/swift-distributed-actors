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

import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct ActorLoggingTests {
    let exampleSenderPath: ActorPath
    let testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))

        var exampleSenderPath = try ActorPath(root: "user")
        exampleSenderPath.append(segment: try! ActorPathSegment("hello"))
        exampleSenderPath.append(segment: try! ActorPathSegment("deep"))
        exampleSenderPath.append(segment: try! ActorPathSegment("path"))
        exampleSenderPath.append(segment: try! ActorPathSegment("avoid-rendering-this-if-possible"))
        self.exampleSenderPath = exampleSenderPath
    }

    @Test
    func test_actorLogger_shouldIncludeActorPath() throws {
        let p = self.testCase.testKit.makeTestProbe("p", expecting: String.self)
        let r = self.testCase.testKit.makeTestProbe("r", expecting: Rendered.self)

        let ref: _ActorRef<String> = try self.testCase.system._spawn(
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

    @Test
    func test_actorLogger_shouldNotRenderLazyMetadataIfLogIsUnderDefinedLogLevel() throws {
        let p = self.testCase.testKit.makeTestProbe("p2", expecting: String.self)
        let r = self.testCase.testKit.makeTestProbe("r2", expecting: Rendered.self)

        let ref: _ActorRef<String> = try self.testCase.system._spawn(
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
                    context.log.info("I got \(message)") // thus should not render any metadata

                    p.ref.tell("Got: \(message)")
                    return .same
                }
            }
        )

        ref.tell("Hello world")
        try p.expectMessage("Got: Hello world")
        try r.expectNoMessage(for: .milliseconds(100))
    }

    @Test
    func test_actorLogger_shouldNotRenderALazyValueIfWeOverwriteItUsingLocalMetadata() throws {
        let p = self.testCase.testKit.makeTestProbe("p2", expecting: String.self)
        let r = self.testCase.testKit.makeTestProbe("r2", expecting: Rendered.self)

        let ref: _ActorRef<String> = try self.testCase.system._spawn(
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
