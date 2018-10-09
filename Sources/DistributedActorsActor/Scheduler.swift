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

/// TODO Proper User API for timers is Timers, which have to be coming from an actor context for the lifecycles to not leak
///
// Implementation notes:
// We very very likely do not want to expose a full blown scheduler like this to users.
// This is a lesson learnt from Akka, where people would forget to cancel tasks when the actor would terminate,
// so we need to have a way to terminate Timers (hint, that's the name) when actors terminate
internal protocol Scheduler {
  func scheduleOnce(delay: DispatchTimeInterval, _ f: @escaping () -> Void) -> Void

  func scheduleOnce<Message>(delay: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Void

  // FIXME must not return void, since it has to be cancellable
  func schedule(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, _ f: @escaping () -> Void) -> Void

  // FIXME must not return void, since it has to be cancellable
  func schedule<Message>(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Void
}

// TODO this is mostly only a placeholder impl; we'd need a proper wheel timer most likely
extension DispatchQueue : Scheduler {
  public func scheduleOnce(delay: DispatchTimeInterval, _ f: @escaping () -> Void) -> Void {
    self.asyncAfter(deadline: .now() + delay, execute: f)
  }

  public func scheduleOnce<Message>(delay: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Void {
    scheduleOnce(delay: delay) {
      receiver ! message
    }
  }

  public func schedule(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, _ f: @escaping () -> Void) -> Void {
    func sched() -> Void {
      f()
      self.asyncAfter(deadline: .now() + interval, execute: sched)
    }

    self.asyncAfter(deadline: .now() + initialDelay, execute: sched)
  }

  public func schedule<Message>(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Void {
    schedule(initialDelay: initialDelay, interval: interval) {
      receiver ! message
    }
  }
}
