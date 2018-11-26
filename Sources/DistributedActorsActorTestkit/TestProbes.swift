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
import NIO // TODO: feels so so to import entire NIO for the TimeAmount only hm...
import XCTest

let SACT_TRACE_PROBE = false

// TODO: find another way to keep it, so it's per-actor-system unique, we may need "akka extensions" style value holders
private let testProbeNames = AtomicAnonymousNamesGenerator(prefix: "testActor-")

internal enum ActorTestProbeCommand<M> {
    case watchCommand(who: AnyReceivesSignals)
    case unwatchCommand(who: AnyReceivesSignals)
    case stopCommand

    case realMessage(message: M)
}

/// A special actor that can be used in place of real actors, yet in addition exposes useful assertion methods
/// which make testing asynchronous actor interactions simpler.
final public class ActorTestProbe<Message> {

    // TODO: is weak the right thing here?
    private weak var system: ActorSystem?
    public let name: String

    typealias ProbeCommands = ActorTestProbeCommand<Message>
    internal let internalRef: ActorRef<ProbeCommands>
    internal let exposedRef: ActorRef<Message>

    public var ref: ActorRef<Message> {
        return self.exposedRef
    }

    private let expectationTimeout: TimeAmount

    /// Blocking linked queue, available to run assertions on
    private let messagesQueue = LinkedBlockingQueue<Message>()
    /// Blocking linked queue, available to run assertions on
    private let signalQueue = LinkedBlockingQueue<SystemMessage>()
    /// Blocking linked queue, specialized for keeping only termination signals (so that we can assert terminations, independently of other signals)
    private let terminationsQueue = LinkedBlockingQueue<SystemMessage>()

// TODO: make this work
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

        self.expectationTimeout = .seconds(1) // would really love "1.second" // TODO: config

        let behavior: Behavior<ProbeCommands> = ActorTestProbe.behavior(
            messageQueue: self.messagesQueue,
            signalQueue: self.signalQueue,
            terminationsQueue: self.terminationsQueue)

        self.internalRef = try! system.spawn(behavior, named: name)
        let wrapRealMessages: (Message) -> ProbeCommands = { msg in
            ProbeCommands.realMessage(message: msg)
        }
        self.exposedRef = self.internalRef.adapt(with: wrapRealMessages) // TODO: the simple adapter we have breaks in face of watching
    }

    private static func behavior(messageQueue: LinkedBlockingQueue<Message>,
                                 signalQueue: LinkedBlockingQueue<SystemMessage>, // TODO: maybe we don't need this one
                                 terminationsQueue: LinkedBlockingQueue<SystemMessage>) -> Behavior<ProbeCommands> {
        return Behavior<ProbeCommands>.receive { (context, message) in
            let cell = context.myself.internal_downcast.cell

            switch message {
            case let .realMessage(msg):
                // real messages are stored directly
                if SACT_TRACE_PROBE {
                    context.log.info("Probe received: [\(msg)]:\(type(of: msg))")
                } // TODO: make configurable to log or not
                messageQueue.enqueue(msg)
                return .same

                // probe commands:
            case let .watchCommand(who):
                cell.deathWatch.watch(watchee: who.internal_exposeBox(), myself: context.myself)
                return .same

            case let .unwatchCommand(who):
                cell.deathWatch.unwatch(watchee: who.internal_exposeBox(), myself: context.myself)
                return .same

            case .stopCommand:
                return .stopped
            }
        }.receiveSignal { (context, signal) in
            if SACT_TRACE_PROBE {
                context.log.debug("Probe received: [\(signal)]:\(type(of: signal))")
            } // TODO: make configurable to log or not
            terminationsQueue.enqueue(signal) // TODO: fix naming...
            return .same
        }
    }

    enum ExpectationError: Error {
        case noMessagesInQueue
        case withinDeadlineExceeded(timeout: TimeAmount)
        case timeoutAwaitingMessage(expected: AnyObject, timeout: TimeAmount)
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

}

extension ActorTestProbe: ReceivesMessages {
    public var path: ActorPath {
        return self.exposedRef.path
    }

    public func tell(_ message: Message) {
        self.exposedRef.tell(message)
    }
}

// MARK: Watching Actors

extension ActorTestProbe {

    @discardableResult
    private func within<T>(_ timeout: TimeAmount, _ block: () throws -> T) throws -> T {
        // FIXME implement by scheduling checks rather than spinning
        let deadline = Deadline.fromNow(amount: timeout)

        var lastObservedError: Error? = nil

        // TODO: make more async than seining like this, also with check interval rather than spin, or use the blocking queue properly
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

    // MARK: Expecting no message/signal within a timeout

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

    /// Asserts that no termination signals (specifically) are received by the probe during the specified timeout.
    ///
    /// Warning: The method will block the current thread for the specified timeout.
    public func expectNoTerminationSignal(for timeout: TimeAmount, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        if let termination = self.terminationsQueue.poll(timeout) {
            let message = "Received unexpected termination [\(termination)]. Did not expect to receive any termination for [\(timeout.prettyDescription)]."
            throw callSite.failure(message: message)
        }
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


    // MARK: Death watch methods

    /// Instructs this probe to watch the passed in reference.
    ///
    /// This enables it to use [[expectTerminated]] to await for the watched actors termination.
    public func watch<M>(_ watchee: ActorRef<M>) {
        self.internalRef.tell(ProbeCommands.watchCommand(who: watchee.internal_boxAnyReceivesSignals()))
        //    let downcast: ActorRefWithCell<M> = watchee.internal_downcast
        //    downcast.sendSystemMessage(.watch(from: BoxedHashableAnyReceivesSignals(self.ref)))
    }

    /// Instructs this probe to unwatch the passed in reference.
    ///
    /// Note that unwatch MIGHT when used with testProbes since the probe may have already stored
    /// the `.terminated` signal in its signal assertion queue, which is not modified upon `unwatching`.
    /// If you want to avoid such race, you can implement your own small actor which performs the watching
    /// and forwards signals appropriately to a probe to trigger the assertions in the tests main thread.
    public func unwatch<M>(_ watchee: ActorRef<M>) {
        self.internalRef.tell(ProbeCommands.unwatchCommand(who: watchee.internal_boxAnyReceivesSignals()))
    }

    /// Returns the `terminated` message (TODO SIGNAL)
    /// since one may want to perform additional assertions on the termination reason perhaps
    /// Returns: the matched `.terminated` message
    @discardableResult
    public func expectTerminated<T>(_ ref: ActorRef<T>, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws -> SystemMessage {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)

        guard let termination = self.terminationsQueue.poll(expectationTimeout) else {
            throw callSite.failure(message: "Expected [\(SystemMessage.terminated(ref: ref))], " +
                "but no signal received within \(self.expectationTimeout.prettyDescription)")
        }
        switch termination {
        case let .terminated(_ref) where _ref.path == ref.path:
            return termination // ok!
        default:
            throw callSite.failure(message: "Expected .terminated(\(ref), ...) but got: \(termination)")
        }
    }

    // MARK: Stopping test probes

    func stop() {
        // we send the stop command as normal message in order to not "overtake" other commands that were sent to it
        // not strictly required, but can yield more predictable results when used from tests after all
        self.internalRef.tell(.stopCommand)
    }

}

