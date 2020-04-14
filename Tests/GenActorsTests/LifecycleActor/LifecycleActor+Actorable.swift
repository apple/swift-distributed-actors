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

public struct LifecycleActor: Actorable {
    let context: Actor<LifecycleActor>.Context
    let probe: ActorRef<String>

    public func preStart(context: Actor<Self>.Context) {
        probe.tell("\(#function):\(context.path)")
    }

    public func postStop(context: Actor<Self>.Context) {
        probe.tell("\(#function):\(context.path)")
    }

    public func hello() -> String {
        "hello"
    }

    public func pleaseStopViaBehavior() -> Behavior<Message> {
        .stop
    }

    public func pleaseStopViaContextStop() -> String {
        self.context.stop() // no further messages (after this one) will be processed by this actor
        return "stopping"
    }

    public func pleaseStopViaContextStopCalledManyTimes() -> Myself.Behavior {
        self.context.stop() // no further messages (after this one) will be processed by this actor
        self.context.stop() // should be no-op
        self.context.stop() // should be no-op
        return .receiveMessage { _ in
            fatalError("Should not be able to receive anything once a stop has been issued")
        }
    }

    func watchChildAndTerminateIt() throws {
        let child: Actor<LifecycleActor> = try self.context.spawn("child") { LifecycleActor(context: $0, probe: self.probe) }
        self.context.watch(child)
        child.pleaseStopViaBehavior()
    }

    public func receiveTerminated(context: Actor<Self>.Context, terminated: Signals.Terminated) -> DeathPactDirective {
        self.probe.tell("terminated:\(terminated)")
        return .ignore
    }

    public func __skipMe() {
        // noop
    }

    // we treat _messages as "only this actor is sending those to themselves"
    // FIXME: in reality what we want is: "this method, even though private do generate a message for it.
    // We'd need some form of annotations for this...
    internal func _doNOTSkipMe() {
        // noop
    }
}
