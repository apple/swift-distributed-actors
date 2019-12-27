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

import Dispatch
@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import NIO
import XCTest

final class DispatcherTests: ActorSystemTestBase {
    // MARK: Running "on NIO" for fun and profit

    func test_runOn_nioEventLoop() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let behavior: Behavior<String> = .receive { context, message in
            context.log.info("HELLO")
            p.tell("Received: \(message)")
            p.tell("Dispatcher: \(context.dispatcher.name)")
            return .same
        }

        let w = try system.spawn(.anonymous, props: .dispatcher(.nio(self.eventLoopGroup.next())), behavior)
        w.tell("Hello")

        let received: String = try p.expectMessage()
        received.dropFirst("Received: ".count).shouldEqual("Hello")

        let dispatcher: String = try p.expectMessage()
        dispatcher.dropFirst("Dispatcher: ".count).shouldStartWith(prefix: "nio:")
    }

    func test_runOn_nioEventLoopGroup() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let behavior: Behavior<String> = .receive { context, message in
            context.log.info("HELLO")
            p.tell("Received: \(message)")
            p.tell("Dispatcher: \(context.dispatcher.name)")
            return .same
        }

        let w = try system.spawn(.anonymous, props: .dispatcher(.nio(self.eventLoopGroup)), behavior)
        w.tell("Hello")

        let received: String = try p.expectMessage()
        received.dropFirst("Received: ".count).shouldEqual("Hello")

        let dispatcher: String = try p.expectMessage()
        dispatcher.dropFirst("Dispatcher: ".count).shouldStartWith(prefix: "nio:")
    }
}
