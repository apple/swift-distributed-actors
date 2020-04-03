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
import DistributedActorsConcurrencyHelpers

@usableFromInline
protocol Cancelable {
    /// Attempts to cancel the cancellable. Returns true when successful, or false
    /// when unsuccessful, or it was already cancelled.
    func cancel()

    /// Returns true if the cancellable has already been cancelled, false otherwise.
    var isCanceled: Bool { get }
}

internal protocol Scheduler {
    func scheduleOnce(delay: TimeAmount, _ f: @escaping () -> Void) -> Cancelable

    func scheduleOnce<Message>(delay: TimeAmount, receiver: ActorRef<Message>, message: Message) -> Cancelable

    func schedule(initialDelay: TimeAmount, interval: TimeAmount, _ f: @escaping () -> Void) -> Cancelable

    func schedule<Message>(initialDelay: TimeAmount, interval: TimeAmount, receiver: ActorRef<Message>, message: Message) -> Cancelable
}

class FlagCancelable: Cancelable {
    private let flag = Atomic<Bool>(value: false)

    func cancel() {
        _ = self.flag.compareAndExchange(expected: false, desired: true)
    }

    @usableFromInline
    var isCanceled: Bool {
        self.flag.load()
    }
}

extension DispatchWorkItem: Cancelable {
    @usableFromInline
    var isCanceled: Bool {
        self.isCancelled
    }
}

// TODO: this is mostly only a placeholder impl; we'd need a proper wheel timer most likely
extension DispatchQueue: Scheduler {
    func scheduleOnce(delay: TimeAmount, _ f: @escaping () -> Void) -> Cancelable {
        let workItem = DispatchWorkItem(block: f)
        self.asyncAfter(deadline: .now() + Dispatch.DispatchTimeInterval.nanoseconds(Int(delay.nanoseconds)), execute: workItem)
        return workItem
    }

    func scheduleOnce<Message>(delay: TimeAmount, receiver: ActorRef<Message>, message: Message) -> Cancelable {
        self.scheduleOnce(delay: delay) {
            receiver.tell(message)
        }
    }

    func schedule(initialDelay: TimeAmount, interval: TimeAmount, _ f: @escaping () -> Void) -> Cancelable {
        let cancellable = FlagCancelable()

        func sched() {
            if !cancellable.isCanceled {
                let nextDeadline = DispatchTime.now() + Dispatch.DispatchTimeInterval.nanoseconds(Int(interval.nanoseconds))
                f()
                self.asyncAfter(deadline: nextDeadline, execute: sched)
            }
        }

        self.asyncAfter(deadline: .now() + Dispatch.DispatchTimeInterval.nanoseconds(Int(initialDelay.nanoseconds)), execute: sched)

        return cancellable
    }

    func schedule<Message>(initialDelay: TimeAmount, interval: TimeAmount, receiver: ActorRef<Message>, message: Message) -> Cancelable {
        self.schedule(initialDelay: initialDelay, interval: interval) {
            receiver.tell(message)
        }
    }
}
