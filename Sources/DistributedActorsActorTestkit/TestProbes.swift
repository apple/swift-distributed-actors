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
import SwiftDistributedActorsDungeon
import NIOConcurrencyHelpers
import NIO // TODO feels so so to import entire NIO for the TimeAmount only hm...

public class TestActorProbe<Message> {

  // TODO is weak the right thing here?
  private weak var system: ActorSystem?
  public let name: String

  public let ref: ActorRef<Message>

  private let expectationTimeout: TimeAmount

  /// Blocking linked queue, available to run assertions on
  private let messagesQueue: LinkedBlockingQueue<Message>
  /// Blocking linked queue, available to run assertions on
  // private let signalQueue = LinkedBlockingQueue<Message>()

// // TODO too bad that we can't make this happen... since the self
//  let testProbeBehavior: Behavior<Message> = .receiveMessage { message in
//    self.messagesQueue.enqueue(message)
//    return .same
//  }

  public init(_ system: ActorSystem, named name: String) {
    self.system = system
    // extract config here
    self.name = name

    self.expectationTimeout = .seconds(1) // would really love "1.second" // TODO config

    self.messagesQueue = LinkedBlockingQueue<Message>()
    let behavior = TestActorProbe.behavior(messageQueue: self.messagesQueue)
    self.ref = system.spawn(behavior, named: name)
  }

  private static func behavior(messageQueue: LinkedBlockingQueue<Message>) -> Behavior<Message> {
    return .receiveMessage { message in
      messageQueue.enqueue(message)
      return .same
    }
  }
  
  public func expectMessage(_ message: Message) throws {

  }

  public func expectSignal(_ signal: Signal) throws {
    let got: Signal = undefined() // await on the signal queue
    fatalError("Expected [\(signal)] got: [\(got)]")
  }

  public func expectTerminated<T>(ref: ActorRef<T>) throws {
    print("IMPLEMENT: expectTerminated")
  }

}

extension TestActorProbe: ReceivesMessages {
  public func tell(_ message: Message) {
    self.ref.tell(message)
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
  private let putLock = Mutex()
  private let takeLock = Mutex()
   private let notEmpty: Condition = Condition()
  private var count = Atomic<Int>(value: 0)

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
      oldCount = count.add(1)
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
          if count.sub(1) > 1 {
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