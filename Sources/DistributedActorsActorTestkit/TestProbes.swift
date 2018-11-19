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
@testable import Swift Distributed ActorsActor
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
  private let messagesQueue = LinkedBlockingQueue<Message>()
  /// Blocking linked queue, available to run assertions on
  private let signalQueue = LinkedBlockingQueue<SystemMessage>()

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

    let behavior = ActorTestProbe.behavior(messageQueue: self.messagesQueue, signalQueue: self.signalQueue)
    self.ref = try! system.spawn(behavior, named: name)
  }

  private static func behavior(messageQueue: LinkedBlockingQueue<Message>,
                               signalQueue: LinkedBlockingQueue<SystemMessage>) -> Behavior<Message> {
    return Behavior<Message>.receive { (context, message) in
      context.log.info("Probe received: [\(message)]:\(type(of: message))") // TODO make configurable to log or not
      messageQueue.enqueue(message)
      return .same
    }.receiveSignal { (context, signal) in
      context.log.info("Probe received: [\(signal)]:\(type(of: signal))") // TODO make configurable to log or not
      signalQueue.enqueue(signal) // TODO fix naming...
      return .same
    }
  }

  @discardableResult
  private func within<T>(_ timeout: TimeAmount, _ block: () throws -> T) throws -> T {
    // FIXME implement by scheduling checks rather than spinning
    let deadline = Deadline.fromNow(amount: timeout)

     var lastObservedError: Error? = nil

    // TODO make more async than seining like this, also with check interval rather than spin, or use the blocking queue properly
    while !deadline.isOverdue(now: Date()) {
      do {
        let res: T = try block()
        return res
      } catch {
        // keep error, try again...
         lastObservedError = error
      }
    }

    if let lastError = lastObservedError {
      throw lastError
    } else {
      throw ExpectationError.withinDeadlineExceeded(timeout: timeout)
    }
  }

  enum ExpectationError: Error {
    case noMessagesInQueue
    case withinDeadlineExceeded(timeout: TimeAmount)
    case timeoutAwaitingMessage(expected: AnyObject, timeout: TimeAmount)
  }


  // MARK: Expecting termination signals

  /// Expects a signal to be enqueued to this actor within the default [[expectationTimeout]].
  public func expectSignal(file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws -> SystemMessage {
    let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)

    let maybeGot: SystemMessage? = self.signalQueue.poll(expectationTimeout)
    guard let got = maybeGot else {
      throw callSite.failure(message: "Expected Signal however no signal arrived within \(self.expectationTimeout.prettyDescription)")
    }
    return got
  }

  public func expectSignal(expected: SystemMessage, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
    let got: SystemMessage = try self.expectSignal(file: file, line: line, column: column)
    got.shouldEqual(expected, file: file, line: line, column: column)
  }

}

extension ActorTestProbe where Message: Equatable {

  // MARK: Expecting messages

  /// Fails in nice readable ways:
  ///    sact/Tests/Swift Distributed ActorsActorTestkitTests/ActorTestProbeTests.swift:35: error: -[Swift Distributed ActorsActorTestkitTests.ActorTestProbeTests test_testProbe_expectMessage_shouldFailWhenNoMessageSentWithinTimeout] : XCTAssertTrue failed -
  ///        try! probe.expectMessage("awaiting-forever")
  ///                   ^~~~~~~~~~~~~~
  ///    error: Did not receive expected [awaiting-forever]:String within [1s], error: noMessagesInQueue
  ///
  /// - Warning: Blocks the current thread until the `expectationTimeout` is exceeded or an message is received by the actor.
  public func expectMessage(_ message: Message, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
    let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
    let timeout = expectationTimeout
    do {
      try within(timeout) {
        guard self.messagesQueue.size() > 0 else {
          throw ExpectationError.noMessagesInQueue
        }
        let got = self.messagesQueue.dequeue()
        got.shouldEqual(message, file: callSite.file, line: callSite.line, column: callSite.column) // can fail
      }
    } catch {
      let message = "Did not receive expected [\(message)]:\(type(of: message)) within [\(timeout.prettyDescription)], error: \(error)"
      throw callSite.failure(message: message)
    }
  }

  public func expectMessageType<T>(_ type: T.Type, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
    try within(expectationTimeout) {
      guard self.messagesQueue.size() > 0 else {
        throw ExpectationError.noMessagesInQueue
      }
      let got = self.messagesQueue.dequeue()
      got.shouldBe(type)
    }
  }

  /// Asserts that no message is received by the probe during the specified timeout.
  /// Useful for making sure that after some "terminal" message no other messages are sent.
  ///
  /// Warning: The method will block the current thread for the specified timeout.
  public func expectNoMessage(for timeout: TimeAmount, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
    let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
    if let message = self.messagesQueue.poll(timeout) {
      let message = "Received unexpected message [\(message)]:\(type(of: message)). Did not expect to receive any messages for [\(timeout.prettyDescription)]."
      throw callSite.failure(message: message)
    }
  }

}

extension ActorTestProbe: ReceivesMessages {
  public var path: ActorPath {
    return self.ref.path
  }

  public func tell(_ message: Message) {
    self.ref.tell(message)
  }
}

// MARK: Watching Actors

extension ActorTestProbe {

  /// Instructs this probe to watch the passed in reference.
  ///
  /// This enables it to use [[expectTerminated]] to await for the watched actors termination.
  public func watch<M>(_ watchee: ActorRef<M>) {
    let downcast: ActorRefWithCell<M> = watchee.internal_downcast
    downcast.sendSystemMessage(.watch(from: BoxedHashableAnyReceivesSignals(self.ref)))
  }


  /// Returns the `terminated` message (TODO SIGNAL)
  /// since one may want to perform additional assertions on the termination reason perhaps
  /// Returns: the matched `.terminated` message
  @discardableResult
  public func expectTerminated<T>(_ ref: ActorRef<T>, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws -> SystemMessage {
    let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)

    var maybeSignal: SystemMessage? = nil
    do {
      maybeSignal = try self.expectSignal()
    } catch {
      throw callSite.failure(message: "Expected .terminated(\(ref), ...) but no signal received within \(self.expectationTimeout.prettyDescription)")
    }

    guard let signal = maybeSignal else { fatalError("should never happen") }
    switch signal {
    case let .terminated(_ref, _) where _ref.path == ref.path:
      return signal // ok!
    default:
      throw callSite.failure(message: "Expected .terminated(\(ref), ...) but got: \(signal)")
    }
  }

}

