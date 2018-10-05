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

public protocol Scheduler {
  func scheduleOnce(delay: DispatchTimeInterval, _ f: @escaping () -> Void) -> Void

  func scheduleOnce<Message>(delay: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Void

  func schedule(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, _ f: @escaping () -> Void) -> Void

  func schedule<Message>(initialDelay: DispatchTimeInterval, interval: DispatchTimeInterval, receiver: ActorRef<Message>, message: Message) -> Void
}

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
