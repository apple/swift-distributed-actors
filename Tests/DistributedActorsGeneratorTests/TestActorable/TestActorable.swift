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

    // @actor
    public mutating func ping() {
        self.messages.append("\(#function)")
    }

    // @actor
    public mutating func greet(name: String) {
        self.messages.append("\(#function):\(name)")
    }

    // @actor
    public mutating func greetUnderscoreParam(_ name: String) {
        self.messages.append("\(#function):\(name)")
    }

    // @actor
    public mutating func greet2(name: String, surname: String) {
        self.messages.append("\(#function):\(name),\(surname)")
    }

    // @actor
    public func throwing() throws {
        try self.contextSpawnExample()
    }

    // @actor
    func passMyself(someone: ActorRef<Actor<TestActorable>>) {
        someone.tell(self.context.myself)
    }

    public func _ignoreInGenActor() throws {
        // nothing
    }

    private func privateFunc() {
        // nothing
    }

    // @actor
    func parameterNames(first second: String) {
        // nothing
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Replying

    // @actor
    public mutating func greetReplyToActorRef(name: String, replyTo: ActorRef<String>) {
        self.messages.append("\(#function):\(name),\(replyTo)")
        replyTo.tell("Hello \(name)!")
    }

    // @actor
    public mutating func greetReplyToActor(name: String, replyTo: Actor<Self>) {
        self.messages.append("\(#function):\(name),\(replyTo)")

        replyTo.greet(name: name)
    }

    // TODO: would be better served as `async` function; we'd want to forbid non async functions perhaps even?
    // @actor
    public func greetReplyToReturnStrict(name: String) -> String {
        "Hello strict \(name)!"
    }

    // @actor
    public func greetReplyToReturnStrictThrowing(name: String) throws -> String {
        "Hello strict \(name)!"
    }

    // @actor
    public func greetReplyToReturnResult(name: String) -> Result<String, Error> {
        .success("Hello result \(name)!")
    }

    // TODO: would be better served as `async` function
    // @actor
    public func greetReplyToReturnNIOFuture(name: String) -> EventLoopFuture<String> {
        let loop = self.context.system._eventLoopGroup.next()
        return loop.makeSucceededFuture("Hello NIO \(name)!")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Become

    // @actor
    func becomeStopped() -> Behavior<TestActorable.Message> {
        .stop
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spawning from ActorableContext

    // @actor
    func contextSpawnExample() throws {
        let child: Actor<TestActorable> = try self.context.spawn("child", TestActorable.init)
        self.context.log.info("Spawned: \(child)")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Scheduling timers

    // @actor
    func timer() {
        // This causes the actor to schedule invoking `ping()`
        self.context.timers.startSingle(key: "tick", message: Message.ping, delay: .seconds(2))
    }
}
