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

class ActorLoggingTests: XCTestCase {

    let system = ActorSystem("\(ActorLoggingTests.self)")
    lazy var testKit: ActorTestKit = ActorTestKit(system)

    var exampleSenderPath: ActorPath! = nil
    let exampleTrace = Trace(
        version: 0,
        traceIdHead: UInt64.max,
        traceIdTail: UInt64.max,
        parentId: UInt64.max,
        traceFlags: 134
    )

    override func tearDown() {
        system.terminate()
    }

    override func setUp() {
        self.exampleSenderPath = try! ActorPath(root: "user")
        self.exampleSenderPath.append(segment: try! ActorPathSegment("hello"))
        self.exampleSenderPath.append(segment: try! ActorPathSegment("deep"))
        self.exampleSenderPath.append(segment: try! ActorPathSegment("path"))
        self.exampleSenderPath.append(segment: try! ActorPathSegment("avoid-rendering-this-if-possible"))
    }

    func test_actorLogger_shouldIncludeActorPath() throws {
        let p = testKit.spawnTestProbe(name: "p", expecting: String.self)
        let r = testKit.spawnTestProbe(name: "r", expecting: Rendered.self)

        let ref: ActorRef<String> = try system.spawn(.setup { context in
            // ~~~~~~~ (imagine as) set by swift-distributed-actors library internally ~~~~~~~~~~
            context.log[metadataKey: "senderPath"] = .lazyStringConvertible({
                r.ref.tell(.instance)
                return self.exampleSenderPath.description
            })
            // ~~~~ end of (imagine as) set by swift-distributed-actors library internally ~~~~~~

            return .receiveMessage { message in
                context.log.info("I got \(message)")

                p.ref.tell("Got: \(message)")
                return .same
            }
        }, name: "myName")

        ref.tell("Hello world")
        try p.expectMessage("Got: Hello world")
        // try r.expectNoMessage(for: .milliseconds(100))
    }

    func test_actorLogger_shouldNotRenderLazyMetadataIfLogIsUnderDefinedLogLevel() throws {
        let p = testKit.spawnTestProbe(name: "p2", expecting: String.self)
        let r = testKit.spawnTestProbe(name: "r2", expecting: Rendered.self)

        let ref: ActorRef<String> = try system.spawn(.setup { context in
            // ~~~~~~~ (imagine as) set by swift-distributed-actors library internally ~~~~~~~~~~
            context.log[metadataKey: "senderPath"] = .lazyStringConvertible({
                r.ref.tell(.instance)
                return self.exampleSenderPath.description
            })
            // ~~~~ end of (imagine as) set by swift-distributed-actors library internally ~~~~~~

            return .receiveMessage { message in
                context.log.logLevel = .warning
                context.log.info("I got \(message)") // thus should not render any metadata

                p.ref.tell("Got: \(message)")
                return .same
            }
        }, name: "myName")

        ref.tell("Hello world")
        try p.expectMessage("Got: Hello world")
        try r.expectNoMessage(for: .milliseconds(100))
    }

    func test_actorLogger_shouldNotRenderALazyValueIfWeOverwriteItUsingLocalMetadata() throws {
        let p = testKit.spawnTestProbe(name: "p2", expecting: String.self)
        let r = testKit.spawnTestProbe(name: "r2", expecting: Rendered.self)

        let ref: ActorRef<String> = try system.spawn(.setup { context in
            // ~~~~~~~ (imagine as) set by swift-distributed-actors library internally ~~~~~~~~~~
            context.log[metadataKey: "senderPath"] = .lazyStringConvertible({
                r.ref.tell(.instance)
                return self.exampleSenderPath.description
            })
            // ~~~~ end of (imagine as) set by swift-distributed-actors library internally ~~~~~~

            return .receiveMessage { message in
                // overwrite the metadata with a local one:
                context.log.info("I got \(message)", metadata: ["senderPath": .string("/user/sender/pre-rendered")])

                p.ref.tell("Got: \(message)")
                return .same
            }
        }, name: "myName")

        ref.tell("Hello world")
        try p.expectMessage("Got: Hello world")
        try r.expectNoMessage(for: .milliseconds(100))
    }

}

struct Trace {
    var version: UInt8
    var versionHexString: String {
        return String(self.version, radix: 16)
    }

    // 16 bytes identifier. All zeroes forbidden
    var traceIdHead: UInt64
    var traceIdTail: UInt64
    var traceIdHexString: String {
        return "\(String(self.traceIdHead, radix: 16))\(String(self.traceIdTail, radix: 16))"
    }

    // 8 bytes identifier. All zeroes forbidden
    var parentId: UInt64
    var parentIdHexString: String {
        return String(self.parentId, radix: 16)
    }

    // 8 bit flags. Currently only one bit is used. See below for details
    var traceFlags: UInt8
    var traceFlagsHexString: String {
        return String(self.traceFlags, radix: 16)
    }
}

extension Trace: CustomStringConvertible {
    public var description: String {
        return "\(self.versionHexString)-\(self.traceIdHexString)-\(self.parentIdHexString)-\(self.traceFlagsHexString)"
    }
}

private enum Rendered {
    case instance
}
