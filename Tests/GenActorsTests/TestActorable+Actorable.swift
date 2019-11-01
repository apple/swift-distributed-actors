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

// TODO: take into account that type may not be public
public struct TestActorable: Actorable {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: State

    var messages: [String] = []

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Init

    let context: ActorContext<Message>

    public init(context: ActorContext<Message>) {
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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Replying

    public mutating func greetReplyToActorRef(name: String, replyTo: ActorRef<String>) {
        self.messages.append("\(#function):\(name),\(replyTo)")
        replyTo.tell("Hello \(name)!")
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
