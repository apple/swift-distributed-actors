//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import class NIO.EventLoopFuture

// TODO: take into account that type may not be public
public struct TestActorable: Actorable {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: State

    var messages: [String] = []

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Init

    let context: Actor<Self>.Context

    public init(context: Actor<Self>.Context) {
        self.context = context
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving

    public mutating func ping() {
        self.messages.append("\(#function)")
    }

    public mutating func greet(name: String) {
        self.messages.append("\(#function):\(name)")
    }

    public mutating func greetUnderscoreParam(_ name: String) {
        self.messages.append("\(#function):\(name)")
    }

    public mutating func greet2(name: String, surname: String) {
        self.messages.append("\(#function):\(name),\(surname)")
    }

    public func throwing() throws {
        try self.contextSpawnExample()
    }

    func passMyself(someone: ActorRef<Actor<TestActorable>>) {
        someone.tell(self.context.myself)
    }

    /// Underscored method names are ignored automatically
    public func _ignoreInGenActor() throws {
        // nothing
    }

    private func privateFunc() {
        // nothing
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Replying

    public mutating func greetReplyToActorRef(name: String, replyTo: ActorRef<String>) {
        self.messages.append("\(#function):\(name),\(replyTo)")
        replyTo.tell("Hello \(name)!")
    }

    // The <Self> has to be special handled as well, since in the message it'd be the "wrong" self
    public mutating func greetReplyToActor(name: String, replyTo: Actor<Self>) {
        self.messages.append("\(#function):\(name),\(replyTo)")
        replyTo.greet(name: "name")
    }

    // TODO: would be better served as `async` function; we'd want to forbid non async functions perhaps even?
    public mutating func greetReplyToReturnStrict(name: String) -> String {
        self.messages.append("\(#function):\(name)")
        return "Hello strict \(name)!"
    }

    // TODO: would be better served as `async` function
    public mutating func greetReplyToReturnNIOFuture(name: String) -> EventLoopFuture<String> {
        self.messages.append("\(#function):\(name)")

        return self.context.system._eventLoopGroup.next().makeSucceededFuture("Hello future \(name)!")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Become

    func becomeStopped() -> Behavior<TestActorable.Message> {
        return .stop
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spawning from ActorableContext

    func contextSpawnExample() throws {
        let child = try self.context.spawn("child", TestActorable.init)
        self.context.log.info("Spawned: \(child)")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Scheduling timers

    func timer() {
        self.context.timers.startSingle(key: "tick", message: Message.ping, delay: .seconds(2))
    }
}
