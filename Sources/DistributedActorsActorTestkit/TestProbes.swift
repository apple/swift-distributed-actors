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

import Swift Distributed ActorsActor
import Atomics

public class TestProbe<Message> {

  // TODO is weak the right thing here?
  private weak var system: ActorSystem?
  public let name: String

  public let ref: ActorRef<Message>

  let testProbeBehavior: Behavior<Message> = .receive { message in

    return .same
  }

  public init(_ system: ActorSystem, named name: String) {
    self.system = system
    // extract config here
    self.name = name

    self.ref = system.spawn(testProbeBehavior, named: name)
  }

  public func expectMessage(_ message: Message) throws {

  }

  public func expectSignal(_ signal: Signal) throws {
    let got: Signal = undefined() // await on the signal queue
    fatalError("Expected [\(signal)] got: [\(got)]")
  }

  public func expectTerminated<T>(ref: ActorRef<T>) throws {

  }

}


// --- support infra ---

// TODO get Dario's queue as a baseline and take it from there... we need poll with a timeout mostly
fileprivate class LinkedBlockingQueue<A> {
  public class Node<A> {
    var item: A?
    var next: Node<A>?

    public init(_ item: A?) {
      self.item = item
    }
  }

  private var producer: Node<A>
  private var consumer: Node<A>
  private let putLock: Mutex = Mutex()
  private let takeLock: Mutex = Mutex()
  private let notEmpty: Condition = Condition()
  private var count: AtomicInt = AtomicInt()

  public init() {
    producer = Node(nil)
    consumer = producer
  }

  public func enqueue(_ item: A) -> Void {
    var oldCount = 0
    putLock.synchronized {
      let next = Node(item)
      producer.next = next
      producer = next
      oldCount = count.increment()
    }

    if oldCount == 0 {
      takeLock.synchronized {
        notEmpty.signal()
      }
    }
  }

  public func dequeue() -> A {
    return takeLock.synchronized { () -> A in
      while true {
        if count.load() > 0 {
          let newNext = consumer.next!
          let res = newNext.item!
          newNext.item = nil
          consumer.next = nil
          consumer = newNext
          if count.decrement() > 1 {
            notEmpty.signal()
          }
          return res
        }
        notEmpty.wait(takeLock)
      }
    }
  }

  public func size() -> Int {
    return count.load()
  }
}