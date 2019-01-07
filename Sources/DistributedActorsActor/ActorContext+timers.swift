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

import NIO
import DistributedActorsConcurrencyHelpers
import Dispatch // TODO: abstract away depending on it here somehow, we only want "the scheduler that we have"

// FIXME: this is very rough and needs a reimpl with a proper "scheduler" abstraction

// MARK: Timer extensions

/// Timer extensions
public extension ActorContext {

    /// - warning: May only be accessed from within the Actor which owns this context!
    var timers: TimerContext<Message> {
        return TimerContext(self)
    }
}

public class TimerContext<Message> {

    private let context: ActorContext<Message>

    public init(_ context: ActorContext<Message>) {
        self.context = context
    }

    /// Short-hand for scheduling a reminder message to myself.
    ///
    /// TODO:
    /// If the actor terminates before the scheduled message is triggered we should cancel it and ignore it.
    /// Implement independently from Dispatch -- if we are on dispatch, use it, but if not then not, top here we must be scheduler agnostic
    @discardableResult
    public func scheduleOnce(after: TimeAmount, reminder: Message, jitter: Double = 0) -> Cancellable {
        // TODO: add jitter support
        // TODO: should not touch dispatch directly
        let delay = DispatchTimeInterval.nanoseconds(after.nanoseconds)
        return DispatchQueue.global().scheduleOnce(delay: delay) {
            self.context.myself.tell(reminder)
        }
    }


}
