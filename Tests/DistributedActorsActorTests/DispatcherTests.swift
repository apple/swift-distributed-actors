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
import NIO
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit
import Dispatch

class DispatcherTests: XCTestCase {

    var group: EventLoopGroup!
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(system)
    }

    override func tearDown() {
        self.system.shutdown()
        self.group.shutdownGracefully(queue: DispatchQueue.global(), { error in
            _ = error.map { err in fatalError("Failed terminating event loops: \(err)") }
        })
    }

    // MARK: Running "on NIO" for fun and profit

    func test_runOn_nioEventLoop() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)
        let behavior: Behavior<String> = .receive { context, message in
            context.log.info("HELLO")
            p.tell("Received: \(message)")
            p.tell("Dispatcher: \(context.dispatcher.name)")
            return .same
        }

        let w = try system.spawn(behavior, name: .anonymous, props: .withDispatcher(.nio(self.group.next())))
        w.tell("Hello")

        let received: String = try p.expectMessage()
        received.dropFirst("Received: ".count).shouldEqual("Hello")

        let dispatcher: String = try p.expectMessage()
        dispatcher.dropFirst("Dispatcher: ".count).shouldStartWith(prefix: "nio:")
    }

    func test_runOn_nioEventLoopGroup() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)
        let behavior: Behavior<String> = .receive { context, message in
            context.log.info("HELLO")
            p.tell("Received: \(message)")
            p.tell("Dispatcher: \(context.dispatcher.name)")
            return .same
        }

        let w = try system.spawn(behavior, name: .anonymous, props: .withDispatcher(.nio(self.group)))
        w.tell("Hello")

        let received: String = try p.expectMessage()
        received.dropFirst("Received: ".count).shouldEqual("Hello")

        let dispatcher: String = try p.expectMessage()
        dispatcher.dropFirst("Dispatcher: ".count).shouldStartWith(prefix: "nio:")
    }


    
}
