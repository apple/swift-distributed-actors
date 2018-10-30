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

import NIOConcurrencyHelpers
import Dispatch

public protocol Cancellable {
  /// Attempts to cancel the cancellable. Returns true when successful, or false
  /// when unsuccessful, or it was already cancelled.
  func cancel() -> Bool

  /// Returns true if the cancellable has already been cancelled, false otherwise.
  func isCancelled() -> Bool
}

public protocol Scheduler {
  func scheduleOnce(delay: DispatchTimeInterval, _ f: @escaping () -> Void) -> Cancellable

  func scheduleOnce<Message>(delay: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Cancellable

  func schedule(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, _ f: @escaping () -> Void) -> Cancellable

//  public func schedule<Message>(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Cancellable {
}

class FlagCancellable : Cancellable {
  private let flag = Atomic<Bool>(value: false)

  func cancel() -> Bool {
    return flag.compareAndExchange(expected: false, desired: true)
  }

  func isCancelled() -> Bool {
    return flag.load()
  }
}

// TODO this is mostly only a placeholder impl; we'd need a proper wheel timer most likely
extension DispatchQueue : Scheduler {

  public func scheduleOnce(delay: DispatchTimeInterval, _ f: @escaping () -> Void) -> Cancellable {
    let cancellable = FlagCancellable()
    self.asyncAfter(deadline: .now() + delay) {
      if (!cancellable.isCancelled()) {
        f()
      }
    }

    return cancellable
  }

  public func scheduleOnce<Message>(delay: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Cancellable {
    return scheduleOnce(delay: delay) {
      receiver ! message
    }
  }

  public func schedule(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, _ f: @escaping () -> Void) -> Cancellable {
    let cancellable = FlagCancellable()
    func sched() -> Void {
      if (!cancellable.isCancelled()) {
        let nextDeadline = DispatchTime.now() + interval
        f()
        self.asyncAfter(deadline: nextDeadline, execute: sched)
      }
    }

    self.asyncAfter(deadline: .now() + initialDelay, execute: sched)

    return cancellable
  }

  public func schedule<Message>(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Cancellable {
    return schedule(initialDelay: initialDelay, interval: interval) {
      receiver ! message
    }
  }

}
