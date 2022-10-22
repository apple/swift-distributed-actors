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
import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import NIO
import XCTest

final class DispatcherTests: SingleClusterSystemXCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Running "on NIO" for fun and profit

    func test_runOn_nioEventLoop() throws {
        let p = self.testKit.makeTestProbe(expecting: String.self)
        let behavior: _Behavior<String> = .receive { context, message in
            context.log.info("HELLO")
            p.tell("Received: \(message)")
            p.tell("Dispatcher: \((context as! _ActorShell<String>)._dispatcher.name)")
            return .same
        }

        let w = try system._spawn(.anonymous, props: .dispatcher(.nio(self.eventLoopGroup.next())), behavior)
        w.tell("Hello")

        let received: String = try p.expectMessage()
        received.dropFirst("Received: ".count).shouldEqual("Hello")

        let dispatcher: String = try p.expectMessage()
        dispatcher.dropFirst("Dispatcher: ".count).shouldStartWith(prefix: "nio:")
    }

    func test_runOn_nioEventLoopGroup() throws {
        let p = self.testKit.makeTestProbe(expecting: String.self)
        let behavior: _Behavior<String> = .receive { context, message in
            context.log.info("HELLO")
            p.tell("Received: \(message)")
            p.tell("Dispatcher: \((context as! _ActorShell<String>)._dispatcher.name)")
            return .same
        }

        let w = try system._spawn(.anonymous, props: .dispatcher(.nio(self.eventLoopGroup)), behavior)
        w.tell("Hello")

        let received: String = try p.expectMessage()
        received.dropFirst("Received: ".count).shouldEqual("Hello")

        let dispatcher: String = try p.expectMessage()
        dispatcher.dropFirst("Dispatcher: ".count).shouldStartWith(prefix: "nio:")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Grand Central Dispatch

    func test_runOn_dispatchQueue() throws {
        let p = self.testKit.makeTestProbe(expecting: String.self)
        let behavior: _Behavior<String> = .receive { context, message in
            context.log.info("HELLO")
            p.tell("\(message)")
            p.tell("\((context as! _ActorShell<String>)._dispatcher.name)")
            return .same
        }

        let global: DispatchQueue = .global()
        let w = try system._spawn(.anonymous, props: .dispatcher(.dispatchQueue(global)), behavior)
        w.tell("Hello")
        w.tell("World")

        func expectWasOnDispatchQueue(p: ActorTestProbe<String>) throws {
            #if os(Linux)
            try p.expectMessage().shouldContain("Dispatch.DispatchQueue")
            #else
            try p.expectMessage().shouldContain("OS_dispatch_queue_global:")
            #endif
        }

        try p.expectMessage("Hello")
        try expectWasOnDispatchQueue(p: p)

        try p.expectMessage("World")
        try expectWasOnDispatchQueue(p: p)

        for i in 1 ... 100 {
            w.tell("\(i)")
        }
        for i in 1 ... 100 {
            try p.expectMessage("\(i)")
            try expectWasOnDispatchQueue(p: p)
        }
    }
}
