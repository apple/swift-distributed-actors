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

public final class FixedThreadPool: MessageDispatcher {
  public var name: String = ""

  private let q: LinkedBlockingQueue<() -> Void> = LinkedBlockingQueue()
  private var threads: [Thread] = []
  private var stopping: Atomic<Bool> = Atomic(value: false)

  public init(_ threadCount: Int) throws {
    for _ in 1...threadCount {
      let thread = try Thread {
        while !self.stopping.load() {
          self.q.dequeue()()
        }
      }

      self.threads.append(thread)
    }
  }

  public func shutdown() -> Void {
    stopping.store(true)
  }

  public func shutdownNow() -> Void {
    shutdown()
    threads.forEach { $0.cancel() }
  }

  public func submit(_ f: @escaping () -> Void) -> Void {
    q.enqueue(f)
  }

  public func execute(_ f: @escaping () -> Void) {
    submit(f)
  }
}
