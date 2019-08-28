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

import CDistributedActorsMailbox
import DistributedActorsConcurrencyHelpers
import Foundation
import Logging

// this used to be typed according to the actor message type, but we found
// that it added some runtime overhead when retrieving the messages from the
// queue, because additional metatype information was retrieved, therefore
// we removed it
internal enum WrappedMessage {
    case message(Any)
    case closure(ActorClosureCarry)
}

extension WrappedMessage: NoSerializationVerification {}

/// Envelopes are used to carry messages with metadata, and are what is enqueued into actor mailboxes.
internal struct Envelope {
    let payload: WrappedMessage

    // Note that we can pass around senders however we can not automatically get the type of them right.
    // We may want to carry around the sender path for debugging purposes though "[pathA] crashed because message [Y] from [pathZ]"
    // TODO: explain this more
    #if SACT_DEBUG
    let senderAddress: ActorAddress
    #endif

    // Implementation notes:
    // Envelopes are also used to enable tracing, both within an local actor system as well as across systems
    // the beauty here is that we basically have the "right place" to put the trace metadata - the envelope
    // and don't need to do any magic around it

    // TODO: let trace: TraceMetadata
}

/// Can carry a closure for later execution on specific actor context.
@usableFromInline
internal struct ActorClosureCarry {
    @usableFromInline
    class _Storage {
        @usableFromInline
        let function: () throws -> Void
        @usableFromInline
        let location: String

        @usableFromInline
        init(function: @escaping () throws -> Void, location: String) {
            self.function = function
            self.location = location
        }
    }

    let _storage: _Storage

    @usableFromInline
    init(function: @escaping () throws -> Void, location: String) {
        self._storage = .init(function: function, location: location)
    }

    @usableFromInline
    var function: () throws -> Void {
        return self._storage.function
    }

    @usableFromInline
    var location: String {
        return self._storage.location
    }
}

internal final class Mailbox<Message> {
    private var mailbox: UnsafeMutablePointer<CSActMailbox>

    internal let address: ActorAddress
    private weak var shell: ActorShell<Message>?
    internal let deadLetters: ActorRef<DeadLetter>

    // Implementation note: context for closure callbacks used for C-interop
    // They are never mutated, yet have to be `var` since passed to C (need inout semantics)
    private var messageClosureContext: InterpretMessageClosureContext!
    private var systemMessageClosureContext: InterpretMessageClosureContext!
    private var deadLetterMessageClosureContext: DropMessageClosureContext!
    private var deadLetterSystemMessageClosureContext: DropMessageClosureContext!

    // Implementation note: closure callbacks passed to C-mailbox
    private let interpretMessage: SActInterpretMessageCallback
    private let deadLetterMessage: SActDropMessageCallback

    /// If `true`, all messages should be attempted to be serialized before sending
    private let serializeAllMessages: Bool
    private var _run: () -> Void = {}

    init(shell: ActorShell<Message>, capacity: UInt32, maxRunLength: UInt32 = 100) {
        #if SACT_TESTS_LEAKS
        if shell.address.segments.first?.value == "user" {
            _ = shell._system.userMailboxInitCounter.add(1)
        }
        #endif

        self.mailbox = cmailbox_create(capacity, maxRunLength)
        self.shell = shell
        self.address = shell.address
        self.deadLetters = shell.system.deadLetters

        // TODO: not entirely happy about the added weight, but I suppose avoiding going all the way "into" the settings on each send is even worse?
        self.serializeAllMessages = shell.system.settings.serialization.allMessages

        // We first need set the functions, in order to allow the context objects to close over self safely (and even compile)

        self.interpretMessage = { ctxPtr, cellPtr, msgPtr, runPhase in
            defer { msgPtr?.deallocate() }
            guard let context = ctxPtr?.assumingMemoryBound(to: InterpretMessageClosureContext.self) else {
                return .shouldStop
            }

            var shouldContinue: SActActorRunResult
            do {
                shouldContinue = try context.pointee.exec(cellPtr: cellPtr!, messagePtr: msgPtr!, runPhase: runPhase)
            } catch {
                traceLog_Mailbox(nil, "Error while processing message! Error was: [\(error)]:\(type(of: error))")

                // TODO: supervision can decide to stop... we now stop always though
                shouldContinue = context.pointee.fail(error: error) // TODO: supervision could be looped in here somehow...? fail returns the behavior to interpret etc, 2nd failure is a hard crash tho perhaps -- ktoso
            }

            return shouldContinue
        }
        self.deadLetterMessage = { ctxPtr, msgPtr in
            defer { msgPtr?.deallocate() }
            let context = ctxPtr?.assumingMemoryBound(to: DropMessageClosureContext.self)
            do {
                try context?.pointee.drop(with: msgPtr!)
            } catch {
                traceLog_Mailbox(nil, "Error while dropping message! Was: \(error) TODO supervision decisions...")
            }
        }

        // Contexts aim to capture self.cell, but can't since we are not done initializing
        // all self references so Swift does not allow us to write self.cell in them.

        self.messageClosureContext = InterpretMessageClosureContext(exec: { cellPtr, envelopePtr, runPhase in
            assert(runPhase == .processingUserMessages, "Expected to be in runPhase = ProcessingSystemMessages, but was not!")
            let shell = cellPtr.assumingMemoryBound(to: ActorShell<Message>.self).pointee
            let envelopePtr = envelopePtr.assumingMemoryBound(to: Envelope.self)
            defer { envelopePtr.deinitialize(count: 1) }

            let envelope = envelopePtr.pointee
            let msg = envelope.payload

            // TODO: Depends on https://github.com/apple/swift-log/issues/37
            // let oldMetadata = Mailbox.populateLoggerMetadata(shell, from: envelope)
            // defer { Mailbox.resetLoggerMetadata(shell, to: oldMetadata) }

            switch msg {
            case .message(let message):
                traceLog_Mailbox(self.address.path, "INVOKE MSG: \(message)")
                return try shell.interpretMessage(message: message as! Message)
            case .closure(let closure):
                traceLog_Mailbox(self.address.path, "INVOKE CLOSURE: \(String(describing: closure.function)) defined at \(closure.location)")
                return try shell.interpretClosure(closure)
            }
        }, fail: { [weak _shell = shell, path = self.address.path] error in
            traceLog_Mailbox(_shell?.path, "FAIL THE MAILBOX")
            switch _shell {
            case .some(let cell): cell.fail(error)
            case .none: pprint("Mailbox(\(path)) TRIED TO FAIL ON AN ALREADY DEAD CELL")
            }
        })
        self.systemMessageClosureContext = InterpretMessageClosureContext(exec: { shellPtr, sysMsgPtr, runPhase in
            assert(runPhase == .processingSystemMessages, "Expected to be in runPhase = ProcessingSystemMessages, but was not!")
            let shell = shellPtr.assumingMemoryBound(to: ActorShell<Message>.self).pointee
            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            defer { envelopePtr.deinitialize(count: 1) }

            let msg = envelopePtr.pointee
            traceLog_Mailbox(self.address.path, "INVOKE SYSTEM MSG: \(msg)")
            return try shell.interpretSystemMessage(message: msg)
        }, fail: { [weak _shell = shell, path = self.address.path] error in
            traceLog_Mailbox(_shell?.path, "FAIL THE MAILBOX")
            switch _shell {
            case .some(let cell): cell.fail(error)
            case .none: pprint("\(path) TRIED TO FAIL ON AN ALREADY DEAD CELL")
            }
        })

        self.deadLetterMessageClosureContext = DropMessageClosureContext(drop: {
            [deadLetters = self.deadLetters, address = self.address] envelopePtr in
            let envelopePtr = envelopePtr.assumingMemoryBound(to: Envelope.self)
            let envelope = envelopePtr.move()
            let wrapped = envelope.payload
            switch wrapped {
            case .message(let userMessage):
                deadLetters.tell(DeadLetter(userMessage, recipient: address))
            case .closure(let carry):
                deadLetters.tell(DeadLetter("[\(String(describing: carry.function))]:closure defined at \(carry.location)", recipient: address))
            }
        })
        self.deadLetterSystemMessageClosureContext = DropMessageClosureContext(drop: {
            [deadLetters = self.deadLetters, address = self.address] sysMsgPtr in
            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            deadLetters.tell(DeadLetter(msg, recipient: address))
        })

                let supervisionDirective: SupervisionDirective<Message>
                switch runPhase {
                case .processingSystemMessages:
                    supervisionDirective = try shell.supervisor.handleFailure(shell, target: shell.behavior, failure: supervisionFailure, processingType: .signal)
                case .processingUserMessages:
                    supervisionDirective = try shell.supervisor.handleFailure(shell, target: shell.behavior, failure: supervisionFailure, processingType: .message)
                }

                // TODO: this handling MUST be aligned with the throws handling.
                switch supervisionDirective {
                case .stop:
                    pnote("Fault handling is not implemented, skipping '\(#function)'") // Fault handling is not implemented
                    // decision is to stop which is terminal, thus: Let it Crash!
                    return .failureTerminate

                case .escalate:
                    pnote("Fault handling is not implemented, skipping '\(#function)'") // Fault handling is not implemented
                    // failure escalated "all the way", so decision is to fail, Let it Crash!
                    // TODO: escalate to parent via terminated with the error?
                    // TODO: do we need to crash children explicitly here?
                    return .failureTerminate

                case .restartImmediately(let nextBehavior):
                    pnote("Fault handling is not implemented, skipping '\(#function)'") // Fault handling is not implemented
                    do {
                        // received new behavior, restarting immediately
                        try shell._restartPrepare()
                        _ = try shell._restartComplete(with: nextBehavior)
                        return .failureRestart
                    } catch {
                        fatalError("Double fault while restarting actor \(shell.path). Terminating.")
                    }

                case .restartDelayed(let delay, let nextBehavior):
                    pnote("Fault handling is not implemented, skipping '\(#function)'") // Fault handling is not implemented
                    do {
                        // received new behavior, however actual restart is delayed, so we only prepare
                        try shell._restartPrepare()
                        // and become the restarting behavior which schedules the wakeUp system message on setup
                        try shell.becomeNext(behavior: SupervisionRestartDelayedBehavior.after(delay: delay, with: nextBehavior))
                        return .failureRestart
                    } catch {
                        fatalError("Double fault while restarting actor \(shell.path). Terminating.")
                    }
                }
            },
            describeMessage: { failedMessageRawPtr in
                // guaranteed to be of our generic Message type, however the context could not close over the generic type
                renderUserMessageDescription(failedMessageRawPtr, type: Message.self)
            }
        )

        // cache `run`, seems to give performance benefit
        self._run = self.run
    }

    deinit {
        // TODO: maybe we can free the queues themselfes earlier, and only keep the status marker somehow?
        // TODO: if Closed we know we'll never allow an enqueue ever again after all // FIXME: hard to pull off with the CMailbox...

        #if SACT_TESTS_LEAKS

        if self.address.segments.first?.value == "user" {
            _ = self.deadLetters._system!.userMailboxInitCounter.sub(1)
        }
        #endif

        // TODO: assert that no system messages in queue
        traceLog_Mailbox(self.address.path, "Mailbox deinit")
        cmailbox_destroy(mailbox)
    }

    @inlinable
    func sendMessage(envelope: Envelope, file: String, line: UInt) {
        if self.serializeAllMessages {
            var messageDescription = "[\(envelope.payload)]"
            do {
                if case .message(let message) = envelope.payload {
                    messageDescription = "[\(message)]:\(type(of: message))"
                    try self.shell?.system.serialization.verifySerializable(message: message as! Message)
                }
            } catch {
                fatalError("Serialization check failed for message \(messageDescription) sent at \(file):\(line). " +
                    "Make sure this type has either a serializer registered OR is marked as `NoSerializationVerification`. " +
                    "This check was performed since `settings.serialization.allMessages` was enabled.")
            }
        }

        let ptr = UnsafeMutablePointer<Envelope>.allocate(capacity: 1)
        ptr.initialize(to: envelope)

        func sendAndDropAsDeadLetter() {
            self.deadLetters.tell(DeadLetter(envelope.payload, recipient: self.address, sentAtFile: file, sentAtLine: line))

            _ = ptr.move()
            ptr.deallocate()
        }

        switch cmailbox_send_message(self.mailbox, ptr) {
        case .needsScheduling:
            traceLog_Mailbox(self.address.path, "Enqueued message \(envelope.payload), scheduling for execution")
            guard let shell = self.shell else {
                traceLog_Mailbox(self.address.path, "ActorShell was released! Unable to complete sendMessage, dropping: \(envelope)")
                self.deadLetters.tell(DeadLetter(envelope.payload, recipient: self.address, sentAtFile: file, sentAtLine: line))
                break
            }
            shell.dispatcher.execute(self._run)

        case .alreadyScheduled:
            traceLog_Mailbox(self.address.path, "Enqueued message \(envelope.payload), someone scheduled already")

        case .mailboxTerminating:
            // TODO: Sanity check; we can't immediately send it to dead letters just yet since first all user messages
            //       already enqueued must be dropped. This is done by the "tombstone run". After it mailbox becomes closed
            //       and we can immediately send things to dead letters then.
            sendAndDropAsDeadLetter()

        case .mailboxClosed:
            traceLog_Mailbox(self.address.path, "is CLOSED, dropping message \(envelope)")
            sendAndDropAsDeadLetter()

        case .mailboxFull:
            traceLog_Mailbox(self.address.path, "is full, dropping message \(envelope)")
            sendAndDropAsDeadLetter() // TODO: "Drop" rather than DeadLetter
        }
    }

    @inlinable
    func sendSystemMessage(_ systemMessage: SystemMessage, file: String, line: UInt) {
        let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
        ptr.initialize(to: systemMessage)

        func sendAndDropAsDeadLetter() {
            // TODO: should deadLetters be special, since watching it is nonsense?
            self.deadLetters.tell(DeadLetter(systemMessage, recipient: self.address, sentAtFile: file, sentAtLine: line), file: file, line: line)
        }

        switch cmailbox_send_system_message(self.mailbox, ptr) {
        case .needsScheduling:
            traceLog_Mailbox(self.address.path, "Enqueued system message \(systemMessage), scheduling for execution")
            guard let shell = self.shell else {
                self.deadLetters.tell(DeadLetter(systemMessage, recipient: nil))
                traceLog_Mailbox(self.address.path, "has already released the actor cell, dropping system message \(systemMessage)")
                break
            }
            shell.dispatcher.execute(self._run)

        case .alreadyScheduled:
            traceLog_Mailbox(self.address.path, "Enqueued system message \(systemMessage), someone scheduled already")

        case .mailboxTerminating:
            traceLog_Mailbox(self.address.path, "Mailbox is terminating. This sendSystemMessage MUST be send to dead letters. System Message: \(systemMessage)")
            sendAndDropAsDeadLetter()
        case .mailboxClosed:
            // not enqueued, mailbox is closed; it cannot and will not interact with any more messages.
            //
            // it is crucial for correctness of death watch that we drain messages to dead letters,
            // which in turn is able to handle watch() automatically for us there;
            // knowing that the watch() was sent to a terminating or dead actor.
            traceLog_Mailbox(self.address.path, "Dead letter: \(systemMessage), since mailbox is CLOSED")
            sendAndDropAsDeadLetter()
        case .mailboxFull:
            fatalError("Dropped system message because mailbox is full. This should never happen and is a mailbox bug, please report an issue.")
        }
    }

    /// DANGER: Must ONLY be invoked synchronously from an aborted or closed run state.
    /// No other messages may be enqueued concurrently; in other words the mailbox MUST be in terminating stare to enqueue the tombstone.
    private func sendSystemTombstone() {
        traceLog_Mailbox(self.address.path, "SEND SYSTEM TOMBSTONE")

        let systemMessage: SystemMessage = .tombstone

        guard let cell = self.shell else {
            traceLog_Mailbox(self.address.path, "has already released the actor cell, dropping system tombstone \(systemMessage)")
            return
        }

        let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
        ptr.initialize(to: systemMessage)

        let res = cmailbox_send_system_tombstone(self.mailbox, ptr)
        switch res {
        case .mailboxTerminating:
            // Good. After all this function must only be called exactly once, exactly during the run causing the termination.
            cell.dispatcher.execute(self._run)
        default:
            fatalError("!!! BUG !!! RES(\(res)) Tombstone was attempted to be enqueued at not terminating actor \(self.address). THIS IS A BUG.")
        }
    }

    @inlinable
    func run() {
        guard var cell = self.shell else {
            traceLog_Mailbox(self.address.path, "has already stopped, ignoring run")
            return
        }

        // Prepare failure context pointers:
        // In case processing of a message fails, this pointer will point to the message that caused the failure
        let failedMessagePtr = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
        failedMessagePtr.initialize(to: nil)
        defer { failedMessagePtr.deallocate() }

        var runPhase: SActMailboxRunPhase = .processingSystemMessages

        // Run the mailbox:
        let mailboxRunResult: SActMailboxRunResult = cmailbox_run(mailbox,
                                                                  &cell,
                                                                  &self.messageClosureContext, &self.systemMessageClosureContext,
                                                                  &self.deadLetterMessageClosureContext, &self.deadLetterSystemMessageClosureContext,
                                                                  self.interpretMessage, self.deadLetterMessage)

        // TODO: not in love that we have to do logic like this here... with a plain book to continue running or not it is easier
        // but we have to signal the .tombstone AFTER the mailbox has set status to terminating, so we have to do it here... and can't do inside interpretMessage
        // we could offer even more callbacks to C but that is also not quite nice...

        switch mailboxRunResult {
        case .reschedule:
            // pending messages, and we are the one who should should reschedule
            cell.dispatcher.execute(self._run)

        case .done:
            // No more messages to run, we are done here
            return

        case .close:
            // termination has been set as mailbox status and we should send ourselves the .tombstone
            // which serves as final system message after which termination will completely finish.
            // We do this since while the mailbox was running, more messages could have been enqueued,
            // and now we need to handle those that made it in, before the terminating status was set.
            traceLog_Mailbox(self.address.path, "interpret CLOSE")
            self.sendSystemTombstone() // Rest in Peace

        case .closed:
            // Meaning that the tombstone was processed and this mailbox will never again run any messages.
            // Its actor and shell will be released, and the mailbox should also deinit; in order to vacillate this,
            // we need to clean up any self references that we may still be holding (as we had to pass them to C).
            self.onTombstoneProcessedClosed()

            traceLog_Mailbox(self.address.path, "finishTerminating has completed, and the final run has completed. We are CLOSED.")
        }
    }

    /// May only be invoked by the cell and puts the mailbox into TERMINATING state.
    func setFailed() {
        cmailbox_set_terminating(self.mailbox)
        traceLog_Mailbox(self.address.path, "<<< SET_FAILED >>>")
    }

    /// May only be invoked when crossing TERMINATING->CLOSED states, only by the ActorCell.
    func setClosed() {
        cmailbox_set_closed(self.mailbox)
        traceLog_Mailbox(self.address.path, "<<< SET_CLOSED >>>")
    }

    func onTombstoneProcessedClosed() {
        self._run = {}
        self.messageClosureContext = nil
        self.systemMessageClosureContext = nil
        self.deadLetterMessageClosureContext = nil
        self.deadLetterSystemMessageClosureContext = nil
    }
}

internal struct MessageProcessingFailure: Error {
    let messageDescription: String
    let backtrace: [String] // TODO: Could be worth it to carry it as struct rather than the raw string?
}

extension MessageProcessingFailure: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        return "Actor faulted while processing message '\(self.messageDescription)', with backtrace"
    }

    public var debugDescription: String {
        let backtraceStr = self.backtrace.joined(separator: "\n")
        return "Actor faulted while processing message '\(self.messageDescription)':\n\(backtraceStr)"
    }
}

// MARK: Closure contexts for interop with C-mailbox

/// Wraps context for use in closures passed to C
private struct InterpretMessageClosureContext {
    private let _exec: (UnsafeMutableRawPointer, UnsafeMutableRawPointer, SActMailboxRunPhase) throws -> SActActorRunResult
    private let _fail: (Error) -> Void

    init(exec: @escaping (UnsafeMutableRawPointer, UnsafeMutableRawPointer, SActMailboxRunPhase) throws -> SActActorRunResult,
         fail: @escaping (Error) -> Void) {
        self._exec = exec
        self._fail = fail
    }

    @inlinable
    func exec(cellPtr: UnsafeMutableRawPointer, messagePtr: UnsafeMutableRawPointer, runPhase: SActMailboxRunPhase) throws -> SActActorRunResult {
        return try self._exec(cellPtr, messagePtr, runPhase)
    }

    @inlinable
    func fail(error: Error) -> SActActorRunResult {
        self._fail(error) // mutates ActorCell to become failed
        return .shouldStop // TODO: cell to decide if to continue later on (supervision); cleanup how we use this return value
    }
}

/// Wraps context for use in closures passed to C
private struct DropMessageClosureContext {
    private let _drop: (UnsafeMutableRawPointer) throws -> Void

    init(drop: @escaping (UnsafeMutableRawPointer) throws -> Void) {
        self._drop = drop
    }

    @inlinable
    func drop(with ptr: UnsafeMutableRawPointer) throws {
        return try self._drop(ptr)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Custom string representations of C-defined enumerations

/// Helper for rendering the C defined `SActMailboxRunResult` enum in human readable format
extension SActMailboxRunResult: CustomStringConvertible {
    public var description: String {
        switch self {
        case .close:
            return "MailboxRunResult.close"
        case .closed:
            return "MailboxRunResult.closed"
        case .done:
            return "MailboxRunResult.done"
        case .reschedule:
            return "MailboxRunResult.reschedule"
        }
    }
}

/// Helper for rendering the C defined `SActMailboxEnqueueResult` enum in human readable format
extension SActMailboxEnqueueResult: CustomStringConvertible {
    public var description: String {
        switch self {
        case .needsScheduling:
            return "SActMailboxEnqueueResult.needsScheduling"
        case .alreadyScheduled:
            return "SActMailboxEnqueueResult.alreadyScheduled"
        case .mailboxTerminating:
            return "SActMailboxEnqueueResult.mailboxTerminating"
        case .mailboxClosed:
            return "SActMailboxEnqueueResult.mailboxClosed"
        case .mailboxFull:
            return "SActMailboxEnqueueResult.mailboxFull"
        }
    }
}

/// Helper for rendering the C defined `SActActorRunResult` enum in human readable format
extension SActActorRunResult: CustomStringConvertible {
    public var description: String {
        switch self {
        case .continueRunning:
            return "ActorRunResult.continueRunning"
        case .shouldSuspend:
            return "ActorRunResult.shouldSuspend"
        case .shouldStop:
            return "ActorRunResult.shouldStop"
        case .closed:
            return "ActorRunResult.closed"
        }
    }
}

// Since the enum originates from C, we want to pretty render it more nicely
extension SActMailboxRunPhase: CustomStringConvertible {
    public var description: String {
        switch self {
        case .processingUserMessages: return "MailboxRunPhase.processingUserMessages"
        case .processingSystemMessages: return "MailboxRunPhase.processingSystemMessages"
        }
    }
}
