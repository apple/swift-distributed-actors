//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
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

internal protocol Scheduler: Sendable {
    func scheduleOnce(delay: Duration, _ f: @escaping () -> Void) -> Cancelable
    func scheduleOnceAsync(delay: Duration, _ f: @Sendable @escaping () async -> Void) -> Cancelable

    func scheduleOnce<Message>(delay: Duration, receiver: _ActorRef<Message>, message: Message) -> Cancelable

    func schedule(initialDelay: Duration, interval: Duration, _ f: @escaping () -> Void) -> Cancelable
    func scheduleAsync(initialDelay: Duration, interval: Duration, _ f: @Sendable @escaping () async -> Void) -> Cancelable

    func schedule<Message>(initialDelay: Duration, interval: Duration, receiver: _ActorRef<Message>, message: Message) -> Cancelable
}

final class FlagCancelable: Cancelable, @unchecked Sendable {
    private let flag: ManagedAtomic<Bool> = .init(false)

    deinit {
//        self.flag.destroy()
    }

    func cancel() {
        _ = self.flag.compareExchange(expected: false, desired: true, ordering: .relaxed)
    }

    @usableFromInline
    var isCanceled: Bool {
        self.flag.load(ordering: .relaxed)
    }
}

extension DispatchWorkItem: Cancelable {
    @usableFromInline
    var isCanceled: Bool {
        self.isCancelled
    }
}

// TODO: this is mostly only a placeholder impl; we'd need a proper wheel timer most likely
extension DispatchQueue: Scheduler, @unchecked Sendable {
    func scheduleOnce(delay: Duration, _ f: @escaping () -> Void) -> Cancelable {
        let workItem = DispatchWorkItem(block: f)
        self.asyncAfter(deadline: .now() + Dispatch.DispatchTimeInterval.nanoseconds(Int(delay.nanoseconds)), execute: workItem)
        return workItem
    }

    func scheduleOnceAsync(delay: Duration, _ f: @Sendable @escaping () async -> Void) -> Cancelable {
        let workItem = DispatchWorkItem { () in
            Task {
                await f()
            }
        }
        self.asyncAfter(deadline: .now() + Dispatch.DispatchTimeInterval.nanoseconds(Int(delay.nanoseconds)), execute: workItem)
        return workItem
    }

    func scheduleOnce<Message>(delay: Duration, receiver: _ActorRef<Message>, message: Message) -> Cancelable {
        self.scheduleOnce(delay: delay) {
            receiver.tell(message)
        }
    }

    func schedule(initialDelay: Duration, interval: Duration, _ f: @escaping () -> Void) -> Cancelable {
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

    func scheduleAsync(initialDelay: Duration, interval: Duration, _ f: @Sendable @escaping () async -> Void) -> Cancelable {
        let cancellable = FlagCancelable()

        @Sendable func sched() {
            if !cancellable.isCanceled {
                let nextDeadline = DispatchTime.now() + Dispatch.DispatchTimeInterval.nanoseconds(Int(interval.nanoseconds))
                Task {
                    await f()
                    self.asyncAfter(deadline: nextDeadline, execute: sched)
                }
            }
        }

        self.asyncAfter(deadline: .now() + Dispatch.DispatchTimeInterval.nanoseconds(Int(initialDelay.nanoseconds)), execute: sched)

        return cancellable
    }

    func schedule<Message>(initialDelay: Duration, interval: Duration, receiver: _ActorRef<Message>, message: Message) -> Cancelable {
        self.schedule(initialDelay: initialDelay, interval: interval) {
            receiver.tell(message)
        }
    }
}
