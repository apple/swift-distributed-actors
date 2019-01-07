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
import DistributedActorsConcurrencyHelpers
import NIO // TODO: feels so so to import entire NIO for the TimeAmount only hm...
import XCTest

internal enum ActorTestProbeCommand<M> {
    case watchCommand(who: AnyReceivesSystemMessages)
    case unwatchCommand(who: AnyReceivesSystemMessages)
    case stopCommand

    case realMessage(message: M)
}

/// A special actor that can be used in place of real actors, yet in addition exposes useful assertion methods
/// which make testing asynchronous actor interactions simpler.
final public class ActorTestProbe<Message> {

    // TODO: is weak the right thing here?
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
    private let terminationsQueue = LinkedBlockingQueue<Signals.Terminated>()

    private var lastMessageObserved: Message? = nil

    /// Prepares and spawns a new test probe. Users should use `testKit.spawnTestProbe(...)` instead.
    internal init(spawn: (Behavior<ProbeCommands>) throws -> ActorRef<ProbeCommands>) {
        // extract config here; pass in the config here
        self.expectationTimeout = .seconds(3) // would really love "1.second" // TODO: config

        let behavior: Behavior<ProbeCommands> = ActorTestProbe.behavior(
            messageQueue: self.messagesQueue,
            signalQueue: self.signalQueue,
            terminationsQueue: self.terminationsQueue)
        self.internalRef = try! spawn(behavior)

        self.name = internalRef.path.name

        let wrapRealMessages: (Message) -> ProbeCommands = { msg in
            ProbeCommands.realMessage(message: msg)
        }
        self.exposedRef = self.internalRef.adapt(with: wrapRealMessages) // TODO: the simple adapter we have breaks in face of watching
    }

    private static func behavior(messageQueue: LinkedBlockingQueue<Message>,
                                 signalQueue: LinkedBlockingQueue<SystemMessage>, // TODO: maybe we don't need this one
                                 terminationsQueue: LinkedBlockingQueue<Signals.Terminated>) -> Behavior<ProbeCommands> {
        return Behavior<ProbeCommands>.receive { (context, message) in
            let cell = context.myself._downcastUnsafe.cell

            switch message {
            case let .realMessage(msg):
                traceLog_Probe("Probe received: [\(msg)]:\(type(of: msg))")
                // real messages are stored directly
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
            traceLog_Probe("Probe received: [\(signal)]:\(type(of: signal))")
            switch signal {
            case let terminated as Signals.Terminated:
                terminationsQueue.enqueue(terminated)
                return .same
            default:
                return .unhandled
            }
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

    /// Expects a message to arrive at the TestProbe and returns it for further assertions.
    /// See also the `expectMessage(_:Message)` overload which provides automatic equality checking.
    ///
    /// - Warning: Blocks the current thread until the `expectationTimeout` is exceeded or an message is received by the actor.
    public func expectMessage(file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws -> Message {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let timeout = expectationTimeout
        do {
            return try within(timeout) {
                guard self.messagesQueue.size() > 0 else {
                    throw ExpectationError.noMessagesInQueue
                }
                let message: Message = self.messagesQueue.dequeue()
                self.lastMessageObserved = message
                return message
            }
        } catch {
            let message = "Did not receive message of type [\(Message.self)] within [\(timeout.prettyDescription)], error: \(error)"
            throw callSite.failure(message: message)
        }
    }

    /// Fails in nice readable ways:
    ///
    /// - Warning: Blocks the current thread until the `expectationTimeout` is exceeded or an message is received by the actor.
    ///
    ///
    /// Example output:
    ///
    ///     sact/Tests/Swift Distributed ActorsActorTestKitTests/ActorTestProbeTests.swift:35: error: -[Swift Distributed ActorsActorTestKitTests.ActorTestProbeTests test_testProbe_expectMessage_shouldFailWhenNoMessageSentWithinTimeout] : XCTAssertTrue failed -
    ///     try! probe.expectMessage("awaiting-forever")
    ///                ^~~~~~~~~~~~~~
    ///     error: Did not receive expected [awaiting-forever]:String within [1s], error: noMessagesInQueue
    ///
    public func expectMessage(_ message: Message, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let timeout = expectationTimeout
        do {
            try within(timeout) {
                guard self.messagesQueue.size() > 0 else {
                    throw ExpectationError.noMessagesInQueue
                }
                let got: Message = self.messagesQueue.dequeue()
                self.lastMessageObserved = got
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
            self.lastMessageObserved = got
            got.shouldBe(type)
        }
    }

}

extension ActorTestProbe: ReceivesMessages {
    public var path: UniqueActorPath {
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

    // MARK: Failure helpers


    /// Returns a failure with additional information of the probes last observed messages.
    /// Most useful as the `else` in an guard expression where the left hand side was an [expectMessage].
    ///
    /// Examples:
    ///
    ///     guard ... else { throw p.failure("failed to extract expected information") }
    ///     guard case let .spawned(child) = p.expectMessage() else { throw p.failure() }
    public func failure(_ message: String? = nil, file: StaticString = #file, line: UInt = #line, column: UInt = #column) -> Error {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)

        var fullMessage: String = message ?? "ActorTestProbe failure."

        switch self.lastMessageObserved {
        case .some(let m):
            fullMessage += " Last message observed was: [\(m)]."
        case .none:
            fullMessage += " No message was observed before this failure."
        }

        return callSite.failure(message: fullMessage)
    }

    // MARK: Expecting messages with matching/extracting callbacks

    /// Expects a message and applies the nested logic to extract values out of it.
    ///
    /// The callback MAY return `nil` in order to signal "this is not the expected message", or throw an error itself.
    // TODO find a better name; it is not exactly "fish for message" though, that can ignore messages for a while, this one does not
    public func expectMessageMatching<T>(file: StaticString = #file, line: UInt = #line, column: UInt = #column, _ matchExtract: (Message) throws -> T?) throws -> T {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let timeout = expectationTimeout
        do {
            return try within(timeout) {
                guard self.messagesQueue.size() > 0 else {
                    throw ExpectationError.noMessagesInQueue
                }
                let got: Message = self.messagesQueue.dequeue()
                guard let extracted = try matchExtract(got) else {
                    let message = "Received \(Message.self) message, however it did not pass the matching check, " + 
                    "and did not produce the requested \(T.self)."
                    throw callSite.failure(message: message)
                }
                return extracted
            }
        } catch {
            let message = "Did not receive matching [\(Message.self)] message within [\(timeout.prettyDescription)], error: \(error)"
            throw callSite.failure(message: message)
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

    /// Instructs this probe to watch the passed in actor.
    /// The watchee actor is from now on being watched and we will receive `.terminated` signals about it.
    ///
    /// There is no difference between keeping the passed in reference or using the returned ref from this method.
    /// The actor is the being watched subject, not a specific reference to it.
    ///
    /// This enables it to use [[expectTerminated]] to await for the watched actors termination.
    /// 
    /// Returns: reference to the passed in watchee actor.
    @discardableResult
    public func watch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        self.internalRef.tell(ProbeCommands.watchCommand(who: watchee._boxAnyReceivesSystemMessages()))
        return watchee
    }

    /// Instructs this probe to unwatch the passed in reference.
    ///
    /// Note that unwatch MIGHT when used with testProbes since the probe may have already stored
    /// the `.terminated` signal in its signal assertion queue, which is not modified upon `unwatching`.
    /// If you want to avoid such race, you can implement your own small actor which performs the watching
    /// and forwards signals appropriately to a probe to trigger the assertions in the tests main thread.
    ///
    /// Returns: reference to the passed in watchee actor.
    @discardableResult
    public func unwatch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        self.internalRef.tell(ProbeCommands.unwatchCommand(who: watchee._boxAnyReceivesSystemMessages()))
        return watchee
    }

    /// Returns the `terminated` message (TODO SIGNAL)
    /// since one may want to perform additional assertions on the termination reason perhaps
    ///
    /// - Warning: Remember to first `watch` the actor you are expecting termination for,
    ///            otherwise the termination signal will never be received.
    /// - Returns: the matched `.terminated` message
    @discardableResult
    public func expectTerminated<T>(_ ref: ActorRef<T>, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws -> Signals.Terminated {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)

        guard let terminated = self.terminationsQueue.poll(expectationTimeout) else {
            throw callSite.failure(message: "Expected [\(ref.path)] to terminate within \(self.expectationTimeout.prettyDescription)")
        }
        guard terminated.path == ref.path else {
            throw callSite.failure(message: "Expected [\(ref.path)] to terminate, but received [\(terminated.path)] terminated signal first instead. " +
                "This could be an ordering issue, inspect your signal order assumptions.")
        }

        return terminated // ok!
    }

    /// Awaits termination of all passed in actors in any order within the default [[expectationTimeout]].
    ///
    /// - Warning: Remember to first `watch` the actors you are expecting termination for,
    ///            otherwise the termination signal will never be received.
    public func expectTerminatedInAnyOrder(_ refs: [AnyAddressableActorRef], file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        var pathSet: Set<UniqueActorPath> = Set(refs.map { $0.path })

        while !pathSet.isEmpty {
            guard let terminated = self.terminationsQueue.poll(expectationTimeout) else {
                throw callSite.failure(message: "Expected [\(refs)] to terminate within \(self.expectationTimeout.prettyDescription)")
            }

            guard pathSet.remove(terminated.path) != nil else {
                throw callSite.failure(message: "Expected any of \(pathSet) to terminate, but received [\(terminated.path)] terminated signal first instead. " +
                    "This could be an ordering issue, inspect your signal order assumptions.")
            }
        }
    }

    // MARK: Stopping test probes

    func stop() {
        // we send the stop command as normal message in order to not "overtake" other commands that were sent to it
        // not strictly required, but can yield more predictable results when used from tests after all
        self.internalRef.tell(.stopCommand)
    }

}

