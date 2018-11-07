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

import Foundation
import Swift Distributed ActorsActor
import NIOConcurrencyHelpers
import NIO // TODO feels so so to import entire NIO for the TimeAmount only hm...
import XCTest

// TODO find another way to keep it, so it's per-actor-system unique, we may need "akka extensions" style value holders
private let testProbeNames = AtomicAnonymousNamesGenerator(prefix: "testActor-")

/// A special actor that can be used in place of real actors, yet in addition exposes useful assertion methods
/// which make testing asynchronous actor interactions simpler.
final public class ActorTestProbe<Message> {

  // TODO is weak the right thing here?
  private weak var system: ActorSystem?
  public let name: String

  public let ref: ActorRef<Message>

  private let expectationTimeout: TimeAmount

  /// Blocking linked queue, available to run assertions on
  private let messagesQueue: LinkedBlockingQueue<Message>
  /// Blocking linked queue, available to run assertions on
  // private let signalQueue = LinkedBlockingQueue<Message>()

// TODO make this work
//  public static func spawnAnonymous<Message>(on system: ActorSystem) -> ActorTestProbe<Message> {
//    return ActorTestProbe<Message>(system, named: testProbeNames.nextName())
//  }
//
//  public static func spawn<Message>(named name: String, on system: ActorSystem) -> ActorTestProbe<Message> {
//    return ActorTestProbe<Message>(system, named: name)
//  }

  public init(named name: String, on system: ActorSystem) {
    self.system = system
    // extract config here
    self.name = name

    self.expectationTimeout = .seconds(1) // would really love "1.second" // TODO config

    self.messagesQueue = LinkedBlockingQueue<Message>()
    let behavior = ActorTestProbe.behavior(messageQueue: self.messagesQueue)
    self.ref = system.spawn(behavior, named: name)
  }

  private static func behavior(messageQueue: LinkedBlockingQueue<Message>) -> Behavior<Message> {
    return .receive { (context, message) in
      context.log.info("Probe received: [\(message)]:\(type(of: message))") // TODO make configurable to log or not
      messageQueue.enqueue(message)
      return .same
    }
  }

  @discardableResult
  private func within<T>(_ timeout: TimeAmount, _ block: () throws -> T) throws -> T {
    // FIXME implement by scheduling checks rather than spinning

    let deadline = Deadline.fromNow(amount: timeout)

    var lastObservedError: Error? = nil

    // TODO make more async than spining like this, also with check interval rather than spin, or use the blocking queue properly
    while !deadline.isOverdue(now: Date()) {
      do {
        let res: T = try block()
        return res
      } catch {
        // keep error, try again...
        lastObservedError = error // TODO show it
      }
    }

    throw ExpectationError.noMessagesInQueue
  }

  enum ExpectationError: Error {
    case noMessagesInQueue
    case timeoutAwaitingMessage(expected: AnyObject, timeout: TimeAmount)
  }

  public func expectSignal(_ signal: Signal) throws {
    messagesQueue.dequeue()
    let got: Signal = undefined() // await on the signal queue
    fatalError("Expected [\(signal)] got: [\(got)]")
  }

  public func expectTerminated<T>(ref: ActorRef<T>) throws {
    print("IMPLEMENT: expectTerminated")
  }

}

extension ActorTestProbe where Message: Equatable {

  ///
  /// - Warning: Blocks the current thread until the `expectationTimeout` is exceeded or an message is received by the actor.
  // TODO is it worth it making the API enforce users to write in tests `try! p.expectMessage(message)`?
  public func expectMessage(_ message: Message, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
    let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
    let timeout = expectationTimeout
    do {
      try within(timeout) {
        guard self.messagesQueue.size() > 0 else { throw ExpectationError.noMessagesInQueue }
        let got = self.messagesQueue.dequeue()
        got.shouldEqual(message, file: callSite.file, line: callSite.line, column: callSite.column) // can fail
      }
    } catch {
      let message = "Did not receive expected [\(message)]:\(type(of: message)) within [\(timeout.prettyDescription)], error: \(error)"
      callSite.fail(message: message)
    }
  }

  public func expectMessageType<T>(_ type: T.Type, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
    try within(expectationTimeout) {
      guard self.messagesQueue.size() > 0 else { throw ExpectationError.noMessagesInQueue }
      let got = self.messagesQueue.dequeue()
      got.shouldBe(type)
    }
  }

  public func expectNoMessage(for timeout: TimeAmount, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
    let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
    if let message = self.messagesQueue.poll(timeout) {
      let message = "Received unexpected message [\(message)]. Did not expect to receive any messages for [\(timeout.prettyDescription)]."
      callSite.fail(message: message)
    }
  }
}

extension ActorTestProbe: ReceivesMessages {
  public func tell(_ message: Message) {
    self.ref.tell(message)
  }
}
