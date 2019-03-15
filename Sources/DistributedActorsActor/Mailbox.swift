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

import DistributedActorsConcurrencyHelpers
import CSwiftDistributedActorsMailbox
import Foundation
import Logging

enum WrappedMessage<Message> {
    case userMessage(Message)
    case closure(() throws -> Void)
}
extension WrappedMessage: NoSerializationVerification {}

/// INTERNAL API
struct Envelope<Message> {
    let payload: WrappedMessage<Message>

    // Note that we can pass around senders however we can not automatically get the type of them right.
    // We may want to carry around the sender path for debugging purposes though "[pathA] crashed because message [Y] from [pathZ]"
    // TODO: explain this more
    #if SACT_DEBUG
    let senderPath: UniqueActorPath
    #endif

    // Implementation notes:
    // Envelopes are also used to enable tracing, both within an local actor system as well as across systems
    // the beauty here is that we basically have the "right place" to put the trace metadata - the envelope
    // and don't need to do any magic around it

    // TODO: let trace: TraceMetadata
}

// TODO: we may have to make public to enable inlining? :-( https://github.com/apple/swift-distributed-actors/issues/69
final class Mailbox<Message> {
    private var mailbox: UnsafeMutablePointer<CMailbox>
    private let path: UniqueActorPath
    private weak var cell: ActorCell<Message>?
    private let deadLetters: ActorRef<DeadLetter>

    // Implementation note: context for closure callbacks used for C-interop
    // They are never mutated, yet have to be `var` since passed to C (need inout semantics)
    private var messageClosureContext: InterpretMessageClosureContext! = nil // FIXME encountered  error: 'self' captured by a closure before all members were initialized suddenly otherwise...
    private var systemMessageClosureContext: InterpretMessageClosureContext! = nil // FIXME encountered  error: 'self' captured by a closure before all members were initialized suddenly otherwise...
    private var deadLetterMessageClosureContext: DropMessageClosureContext! = nil // FIXME encountered  error: 'self' captured by a closure before all members were initialized suddenly otherwise...
    private var deadLetterSystemMessageClosureContext: DropMessageClosureContext! = nil // FIXME encountered  error: 'self' captured by a closure before all members were initialized suddenly otherwise...
    private var invokeSupervisionClosureContext: InvokeSupervisionClosureContext! = nil // FIXME encountered  error: 'self' captured by a closure before all members were initialized suddenly otherwise...

    // Implementation note: closure callbacks passed to C-mailbox
    private let interpretMessage: InterpretMessageCallback
    private let dropMessage: DropMessageCallback
    // Enables supervision to work for faults (and not only errors).
    // If the currently run behavior is wrapped using a supervision interceptor,
    // we store a reference to its Supervisor handler, that we invoke
    private let invokeSupervision: InvokeSupervisionCallback

    /// If `true`, all messages should be attempted to be serialized before sending
    private let serializeAllMessages: Bool

    init(cell: ActorCell<Message>, capacity: UInt32, maxRunLength: UInt32 = 100) {
        self.mailbox = cmailbox_create(capacity, maxRunLength)
        self.cell = cell
        self.path = cell.path
        self.deadLetters = cell.system.deadLetters

        // TODO not entirely happy about the added weight, but I suppose avoiding going all the way "into" the settings on each send is even worse?
        let serialization: SerializationSettings? = self.cell?.system.settings.serialization
        self.serializeAllMessages = serialization?.allMessages ?? false

        // We first need set the functions, in order to allow the context objects to close over self safely (and even compile)

        self.interpretMessage = { ctxPtr, msgPtr, runPhase in
            defer { msgPtr?.deallocate() }
            guard let context = ctxPtr?.assumingMemoryBound(to: InterpretMessageClosureContext.self) else {
                return .shouldStop
            }

            var shouldContinue: ActorRunResult
            do {
                shouldContinue = try context.pointee.exec(with: msgPtr!, runPhase: runPhase)
            } catch {
                traceLog_Mailbox(nil, "Error while processing message! Error was: [\(error)]:\(type(of: error))")

                // TODO: supervision can decide to stop... we now stop always though
                shouldContinue = context.pointee.fail(error: error) // TODO: supervision could be looped in here somehow...? fail returns the behavior to interpret etc, 2nd failure is a hard crash tho perhaps -- ktoso
            }

            return shouldContinue
        }
        self.dropMessage = { (ctxPtr, msgPtr) in
            defer { msgPtr?.deallocate() }
            let context = ctxPtr?.assumingMemoryBound(to: DropMessageClosureContext.self)
            do {
                try context?.pointee.drop(with: msgPtr!)
            } catch {
                traceLog_Mailbox(nil, "Error while dropping message! Was: \(error) TODO supervision decisions...")
            }
        }
        self.invokeSupervision = { ctxPtr, runPhase, failedMessagePtr in
            traceLog_Mailbox(nil, "Actor has faulted, supervisor to decide course of action.")

            if let crashDetails = FaultHandling.getCrashDetails() {
                if let context: InvokeSupervisionClosureContext = ctxPtr?.assumingMemoryBound(to: InvokeSupervisionClosureContext.self).pointee {
                    traceLog_Mailbox(nil, "Run failed in phase \(runPhase)")

                    let messageDescription = context.renderMessageDescription(runPhase: runPhase, failedMessageRaw: failedMessagePtr!)
                    let failure = MessageProcessingFailure(messageDescription: messageDescription, backtrace: crashDetails.backtrace)

                    do {
                        return try context.handleMessageFailure(.fault(failure), whileProcessing: runPhase)
                    } catch {
                        traceLog_Supervision("Supervision: Double-fault during supervision, unconditionally hard crashing the system: \(error)")
                        exit(-1)
                    }
                } else {

                    traceLog_Supervision("No crash details...")
                    // no crash details, so we can't invoke supervision; Let it Crash!
                    return .failureTerminate
                }
            } else {

                traceLog_Supervision("No crash details...")
                // no crash details, so we can't invoke supervision; Let it Crash!
                return .failureTerminate
            }
        }

        // Contexts aim to capture self.cell, but can't since we are not done initializing
        // all self references so Swift does not allow us to write self.cell in them.

        self.messageClosureContext = InterpretMessageClosureContext(exec: { [weak _cell = cell] envelopePtr, runPhase in
            assert(runPhase == .processingUserMessages, "Expected to be in runPhase = ProcessingSystemMessages, but was not!")
            guard let cell = _cell else {
                return .shouldStop
            }

            let envelopePtr = envelopePtr.assumingMemoryBound(to: Envelope<Message>.self)
            let envelope = envelopePtr.move()
            let msg = envelope.payload

            let oldMetadata = Mailbox.populateLoggerMetadata(cell, from: envelope)
            defer { Mailbox.resetLoggerMetadata(cell, to: oldMetadata) }

            switch msg {
            case .userMessage(let message): 
                traceLog_Mailbox(self.path, "INVOKE MSG: \(message)")
                return try cell.interpretMessage(message: message)
            case .closure(let f):
                traceLog_Mailbox(self.path, "INVOKE CLOSURE: \(String(describing: f))")
                return try cell.interpretClosure(f)
            }
        }, fail: { [weak _cell = cell, path = self.path] error in
            traceLog_Mailbox(_cell?.path, "FAIL THE MAILBOX")
            switch _cell {
            case .some(let cell): cell.fail(error)
            case .none:           pprint("Mailbox(\(path)) TRIED TO FAIL ON AN ALREADY DEAD CELL")
            }
        })
        self.systemMessageClosureContext = InterpretMessageClosureContext(exec: { [weak _cell = cell] sysMsgPtr, runPhase in
            assert(runPhase == .processingSystemMessages, "Expected to be in runPhase = ProcessingSystemMessages, but was not!")
            guard let cell = _cell else {
                return .shouldStop
            }

            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            traceLog_Mailbox(self.path, "INVOKE SYSTEM MSG: \(msg)")
            return try cell.interpretSystemMessage(message: msg)
        }, fail: { [weak _cell = cell, path = self.path] error in
            traceLog_Mailbox(_cell?.path, "FAIL THE MAILBOX")
            switch _cell {
            case .some(let cell): cell.fail(error)
            case .none: pprint("\(path) TRIED TO FAIL ON AN ALREADY DEAD CELL")
            }
        })

        self.deadLetterMessageClosureContext = DropMessageClosureContext(drop: { [deadLetters = self.deadLetters] envelopePtr in
            let envelopePtr = envelopePtr.assumingMemoryBound(to: Envelope<Message>.self)
            let envelope = envelopePtr.move()
            let wrapped = envelope.payload
            switch wrapped {
            case .userMessage(let userMessage):
                deadLetters.tell(DeadLetter(userMessage))
            case .closure(let f):
                deadLetters.tell(DeadLetter("[\(f)]:closure"))
            }
        })
        self.deadLetterSystemMessageClosureContext = DropMessageClosureContext(drop: { [deadLetters = self.deadLetters] sysMsgPtr in
            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            deadLetters.tell(DeadLetter(msg))
        })

        self.invokeSupervisionClosureContext = InvokeSupervisionClosureContext(
            logger: cell.log,
            handleMessageFailure: { [weak _cell = cell] supervisionFailure, runPhase in
                guard let cell = _cell else {
                    /// if we cannot unwrap the cell it means it was closed and deallocated
                    return .close
                }

                traceLog_Mailbox(self.path, "INVOKE SUPERVISION !!! FAILURE: \(supervisionFailure)")

                let supervisionResultingBehavior: Behavior<Message>

                // TODO improve logging, should include what decision was taken; same for THROWN
                cell.log.warning("Supervision: Actor has FAULTED while interpreting \(runPhase), handling with \(cell.supervisor); Failure details: \(String(reflecting: supervisionFailure))")

                switch runPhase {
                case .processingSystemMessages:
                    supervisionResultingBehavior = try cell.supervisor.handleFailure(cell.context, target: cell.behavior, failure: supervisionFailure, processingType: .signal)
                case .processingUserMessages:
                    supervisionResultingBehavior = try cell.supervisor.handleFailure(cell.context, target: cell.behavior, failure: supervisionFailure, processingType: .message)
                }

                // TODO: this handling MUST be aligned with the throws handling.
                switch supervisionResultingBehavior.underlying {
                case .stopped:
                    // decision is to stop which is terminal, thus: Let it Crash!
                    return .failureTerminate
                case .failed: // TODO: Carry this error to supervision?
                    // decision is to fail, Let it Crash!
                    return .failureTerminate
                default:
                    // received new behavior, attempting restart:
                    do {
                        try cell.restart(behavior: supervisionResultingBehavior)
                    } catch {
                        cell.system.terminate() // FIXME nicer somehow, or hard exit() here?
                        fatalError("Double fault while restarting actor \(cell.path). Terminating.")
                    }
                    return .failureRestart
                }
            },
            describeMessage: { failedMessageRawPtr in
                // guaranteed to be of our generic Message type, however the context could not close over the generic type
                return renderUserMessageDescription(failedMessageRawPtr, type: Message.self)
            })
    }

    deinit {
        // TODO: maybe we can free the queues themselfes earlier, and only keep the status marker somehow?
        // TODO: if Closed we know we'll never allow an enqueue ever again after all // FIXME: hard to pull off with the CMailbox...
        
        // TODO: assert that no system messages in queue
        
        traceLog_Mailbox(self.path, "Mailbox deinit")
        cmailbox_destroy(mailbox)
    }

    @inlinable
    func sendMessage(envelope: Envelope<Message>) {
        if self.serializeAllMessages {
            var messageDescription = "[\(envelope.payload)]"
            do {
                if case .userMessage(let message) = envelope.payload {
                    messageDescription = "[\(message)]:\(type(of: message))"
                    try cell?.system.serialization.verifySerializable(message: message)
                }
            } catch {
                fatalError("Serialization check failed for message \(messageDescription). " + 
                    "Make sure this type has either a serializer registered OR is marked as `NoSerializationVerification`. " + 
                    "This check was performed since `settings.serialization.allMessages` was enabled.")
            }
        }

        guard let cell = self.cell else {
            traceLog_Mailbox(self.path, "has already stopped, dropping message \(envelope)")
            return // TODO: drop messages (if we see Closed (terminated, terminating) it means the mailbox has been freed already) -> can't enqueue
        }

        let ptr = UnsafeMutablePointer<Envelope<Message>>.allocate(capacity: 1)
        ptr.initialize(to: envelope)

        func sendAndDropAsDeadLetter() {
            self.deadLetters.tell(DeadLetter(envelope.payload))
            _ = ptr.move()
            ptr.deallocate()
        }

        switch cmailbox_send_message(mailbox, ptr) {
        case .needsScheduling:
            traceLog_Mailbox(self.path, "Enqueued message \(envelope.payload), scheduling for execution")
            cell.dispatcher.execute(self.run)
        case .alreadyScheduled:
            traceLog_Mailbox(self.path, "Enqueued message \(envelope.payload), someone scheduled already")

        case .mailboxTerminating:
            // TODO: Sanity check; we can't immediately send it to dead letters just yet since first all user messages
            //       already enqueued must be dropped. This is done by the "tombstone run". After it mailbox becomes closed 
            //       and we can immediately send things to dead letters then. 
            sendAndDropAsDeadLetter()
        case .mailboxClosed:
            traceLog_Mailbox(self.path, "is CLOSED, dropping message \(envelope)")
            sendAndDropAsDeadLetter()
        case .mailboxFull:
            traceLog_Mailbox(self.path, "is full, dropping message \(envelope)")
            sendAndDropAsDeadLetter() // TODO "Drop" rather than DeadLetter
        }
    }

    @inlinable
    func sendSystemMessage(_ systemMessage: SystemMessage) {
        guard let cell = self.cell else {
            self.deadLetters.tell(DeadLetter(systemMessage))
            traceLog_Mailbox(self.path, "has already released the actor cell, dropping system message \(systemMessage)")
            return
        }

        let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
        ptr.initialize(to: systemMessage)

        func sendAndDropAsDeadLetter() {
            self.deadLetters.tell(DeadLetter(systemMessage))
            // we can not deallocate yet...
            // _ = ptr.move()
            // ptr.deallocate()
        }

        switch cmailbox_send_system_message(mailbox, ptr) {
        case .needsScheduling:
            traceLog_Mailbox(self.path, "Enqueued system message \(systemMessage), scheduling for execution")
            cell.dispatcher.execute(self.run)
        case .alreadyScheduled:
            traceLog_Mailbox(self.path, "Enqueued system message \(systemMessage), someone scheduled already")
            
        case .mailboxTerminating:
            traceLog_Mailbox(self.path, "Mailbox is terminating. This sendSystemMessage MUST be send to dead letters. System Message: \(systemMessage)")
            sendAndDropAsDeadLetter()
        case .mailboxClosed:
            // not enqueued, mailbox is closed; it cannot and will not interact with any more messages.
            //
            // it is crucial for correctness of death watch that we drain messages to dead letters,
            // which in turn is able to handle watch() automatically for us there;
            // knowing that the watch() was sent to a terminating or dead actor.
            traceLog_Mailbox(self.path, "Dead letter: \(systemMessage), since mailbox is CLOSED")
            sendAndDropAsDeadLetter()
        case .mailboxFull:
            fatalError("Dropped system message because mailbox is full. This should never happen and is a mailbox bug, please report an issue.")
        }
    }

    /// DANGER: Must ONLY be invoked synchronously from an aborted or closed run state.
    /// No other messages may be enqueued concurrently; in other words the mailbox MUST be in terminating stare to enqueue the tombstone.
    private func sendSystemTombstone() {
        traceLog_Mailbox(self.path, "SEND SYSTEM TOMBSTONE")

        let systemMessage: SystemMessage = .tombstone

        guard let cell = self.cell else {
            traceLog_Mailbox(self.path, "has already released the actor cell, dropping system tombstone \(systemMessage)")
            return
        }

        let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
        ptr.initialize(to: systemMessage)

        switch cmailbox_send_system_tombstone(mailbox, ptr) {
        case .mailboxTerminating:
            // Good. After all this function must only be called exactly once, exactly during the run causing the termination.
            cell.dispatcher.execute(self.run)
        default:
            fatalError("!!! BUG !!! Tombstone was attempted to be enqueued at not terminating actor \(self.path). THIS IS A BUG.")
        }

    }

    @inlinable
    func run() {
        // For every run we make we mark "we are inside of an mailbox run now" and remove the marker once the run completes.
        // This is because fault handling MUST ONLY be triggered for mailbox runs, we do not want to handle arbitrary failures on this thread.
        FaultHandling.enableFaultHandling()
        defer { FaultHandling.disableFaultHandling() }

        guard let cell = self.cell else {
            traceLog_Mailbox(self.path, "has already stopped, ignoring run")
            return
        }

        // Prepare failure context pointers:
        // In case processing of a message fails, this pointer will point to the message that caused the failure
        let failedMessagePtr = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
        failedMessagePtr.initialize(to: nil)
        defer { failedMessagePtr.deallocate() }

        var runPhase: MailboxRunPhase = .processingSystemMessages

        // Run the mailbox:
        let mailboxRunResult: MailboxRunResult = cmailbox_run(mailbox,
            &messageClosureContext, &systemMessageClosureContext,
            &deadLetterMessageClosureContext, &deadLetterSystemMessageClosureContext,
            interpretMessage, dropMessage,
            // fault handling:
            FaultHandling.getErrorJmpBuf(), 
            &invokeSupervisionClosureContext, invokeSupervision, failedMessagePtr, &runPhase)

        // TODO: not in love that we have to do logic like this here... with a plain book to continue running or not it is easier
        // but we have to signal the .tombstone AFTER the mailbox has set status to terminating, so we have to do it here... and can't do inside interpretMessage
        // we could offer even more callbacks to C but that is also not quite nice...

        switch mailboxRunResult {
        case .reschedule:
            // pending messages, and we are the one who should should reschedule
            cell.dispatcher.execute(self.run)
        case .done:
            // No more messages to run, we are done here
            return

        case .failureRestart:
            // FIXME: !!! we must know if we should schedule or not after a restart...
            traceLog_Supervision("Supervision: Mailbox run complete, restart decision! RESCHEDULING (TODO FIXME IF WE SHOULD OR NOT)") // FIXME
            cell.dispatcher.execute(self.run)
        case .failureTerminate:
            // We are now terminating. The run has been aborted and other threads were not yet allowed to activate this
            // actor (since it was in the middle of processing). We MUST therefore activate right now, and at the same time
            // force the enqueue of the tombstone system message, as the actor now will NOT accept any more messages
            // and will dead letter them. We need to process all existing system messages though all the way to the tombstone,
            // before we become CLOSED.

            // Meaning supervision was either applied and decided to fail, or not applied and we should fail anyway.
            // We have to guarantee the processing of any outstanding system messages, and use a tombstone marker to notice this.
            let failedRunPhase = runPhase
            self.reportCrashFailCellWithBestPossibleError(cell: cell, failedMessagePtr: failedMessagePtr, runPhase: failedRunPhase)

            // since we may have faulted while processing user messages, while system messages were being enqueued,
            // we have to perform one last run to potentially drain any remaining system messages to dead letters for
            // death watch correctness.
            traceLog_Mailbox(self.path, "interpret failureTerminate")
            pprint("interpret failureTerminate    \(self.path)")
            self.sendSystemTombstone() // Rest in Peace
        case .close:
            // termination has been set as mailbox status and we should send ourselves the .tombstone
            // which serves as final system message after which termination will completely finish.
            // We do this since while the mailbox was running, more messages could have been enqueued,
            // and now we need to handle those that made it in, before the terminating status was set.
            traceLog_Mailbox(self.path, "interpret CLOSE")
            self.sendSystemTombstone() // Rest in Peace
        case .closed:
            traceLog_Mailbox(self.path, "finishTerminating has completed, and the final run has completed. We are CLOSED.")
        }
    }

    /// May only be invoked by the cell and puts the mailbox into TERMINATING state.
    func setFailed() {
        cmailbox_set_terminating(self.mailbox)
        traceLog_Mailbox(self.path, "<<< SET_FAILED >>>")
    }

    /// May only be invoked when crossing TERMINATING->CLOSED states, only by the ActorCell.
    func setClosed() {
        cmailbox_set_closed(self.mailbox)
        traceLog_Mailbox(self.path, "<<< SET_CLOSED >>>")
    }
}

// MARK: Crash handling functions for Mailbox

extension Mailbox {
    
    // TODO rename to "log crash error"?
    private func reportCrashFailCellWithBestPossibleError(cell: ActorCell<Message>, failedMessagePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>, runPhase: MailboxRunPhase) {
        
        let failure: MessageProcessingFailure
        
        if let crashDetails = FaultHandling.getCrashDetails() {
            if let failedMessageRaw = failedMessagePtr.pointee {
                defer { failedMessageRaw.deallocate() }

                // appropriately render the message (recovering generic information thanks to the passed in type)
                let messageDescription = renderMessageDescription(runPhase: runPhase, failedMessageRaw: failedMessageRaw, userMessageType: Message.self)
                failure = MessageProcessingFailure(messageDescription: messageDescription, backtrace: crashDetails.backtrace)
            } else {
                failure = MessageProcessingFailure(messageDescription: "UNKNOWN", backtrace: crashDetails.backtrace)
            }
        } else {
            failure = MessageProcessingFailure(messageDescription: "Error received, but no details set. Supervision omitted.", backtrace: [])
        }

        cell.reportCrashFail(error: failure)
    }
}

// TODO: separate metadata things from the mailbox, perhaps rather we should do it inside the run (pain to do due to C interop a bit?)
extension Mailbox {
    internal static func populateLoggerMetadata(_ cell:  ActorCell<Message>, from envelope: Envelope<Message>) -> Logger.Metadata {
        let old = cell.log.metadata
        #if SACT_DEBUG
        cell.log[metadataKey: "actorSenderPath"] = .lazy({ .string(envelope.senderPath.description) })
        #endif
        return old
    }
    internal static func resetLoggerMetadata(_ cell:  ActorCell<Message>, to metadata: Logger.Metadata) {
        cell.log.metadata = metadata
    }
}

internal struct MessageProcessingFailure: Error {
    let messageDescription: String
    let backtrace: [String] // TODO: Could be worth it to carry it as struct rather than the raw string?
}

extension MessageProcessingFailure: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        return "Actor faulted while processing message '\(messageDescription)', with backtrace"
    }
    public var debugDescription: String {
        let backtraceStr = backtrace.joined(separator: "\n")
        return "Actor faulted while processing message '\(messageDescription)':\n\(backtraceStr)"
    }
}

// MARK: Closure contexts for interop with C-mailbox

/// Wraps context for use in closures passed to C
private struct InterpretMessageClosureContext {
    private let _exec: (UnsafeMutableRawPointer, MailboxRunPhase) throws -> ActorRunResult
    private let _fail: (Error) -> ()

    init(exec: @escaping (UnsafeMutableRawPointer, MailboxRunPhase) throws -> ActorRunResult,
         fail: @escaping (Error) -> ()) {
        self._exec = exec
        self._fail = fail
    }

    @inlinable
    func exec(with ptr: UnsafeMutableRawPointer, runPhase: MailboxRunPhase) throws -> ActorRunResult {
        return try self._exec(ptr, runPhase)
    }

    @inlinable
    func fail(error: Error) -> ActorRunResult {
        _fail(error) // mutates ActorCell to become failed
        return .shouldStop // TODO: cell to decide if to continue later on (supervision); cleanup how we use this return value
    }
}
/// Wraps context for use in closures passed to C
private struct DropMessageClosureContext {
    private let _drop: (UnsafeMutableRawPointer) throws -> ()

    init(drop: @escaping (UnsafeMutableRawPointer) throws -> ()) {
        self._drop = drop
    }

    @inlinable
    func drop(with ptr: UnsafeMutableRawPointer) throws -> () {
        return try self._drop(ptr)
    }
}
/// Wraps context for use in closures passed to C
private struct InvokeSupervisionClosureContext {
    // Implementation note: we wold like to execute the usual handle failure here, but we can't since the passed
    // over to C ClosureContext may not close over generic context. Thus the passed in closure here has to contain all the logic,
    // and only yield us the "supervised run result", which usually will be `Failure` or `FailureRestart`
    //
    // private let _handleMessageFailure: (UnsafeMutableRawPointer) throws -> Behavior<Message>
    private let _handleMessageFailureBecauseC: (Supervision.Failure, MailboxRunPhase) throws -> MailboxRunResult

    // Since we cannot close over generic context here, we invoke the generic requiring rendering inside this
    private let _describeMessage: (UnsafeMutableRawPointer) -> String

    /// The cell's logger may be used to log information about the supervision handling.
    /// We assume that since we run supervision only for "not fatal faults" the logger should still be in a usable state
    /// as we run the supervision handling. The good thing is that all metadata of the cell's logger will be included in
    /// crash logs then. It may we worth reconsidering if we need to be even more defensive here, e.g.
    /// take a logger without potential user changes made to it etc.
    private let _log: Logger

    init(logger: Logger, handleMessageFailure: @escaping (Supervision.Failure, MailboxRunPhase) throws -> MailboxRunResult,
         describeMessage: @escaping (UnsafeMutableRawPointer) -> String) {
        self._log = logger
        self._handleMessageFailureBecauseC = handleMessageFailure
        self._describeMessage = describeMessage
    }

    @inlinable
    func handleMessageFailure(_ failure: Supervision.Failure, whileProcessing runPhase: MailboxRunPhase) throws -> MailboxRunResult {
        return try self._handleMessageFailureBecauseC(failure, runPhase)
    }

    // hides the generic Message and provides same capabilities of rendering messages as the free function of the same name
    @inlinable
    func renderMessageDescription(runPhase: MailboxRunPhase, failedMessageRaw: UnsafeMutableRawPointer) -> String {
        switch runPhase {
        case .processingSystemMessages:
            // we can invoke it directly since it is not generic
            return renderSystemMessageDescription(failedMessageRaw)

        case .processingUserMessages:
            // since Message is generic, we need to hop over the provided function which was allowed to close over the generic state
            return self._describeMessage(failedMessageRaw)
        }
    }

    @inlinable
    var log: Logger {
        return self._log
    }

}

/// Renders a `SystemMessage` or user `Message` appropriately given a raw pointer to such message.
/// Only really needed due to the c-interop of failure handling where we need to recover the lost generic information this way.
private func renderMessageDescription<Message>(runPhase: MailboxRunPhase, failedMessageRaw: UnsafeMutableRawPointer, userMessageType: Message.Type) -> String {
    switch runPhase {
    case .processingSystemMessages:
        return renderSystemMessageDescription(failedMessageRaw)
    case .processingUserMessages:
        return renderUserMessageDescription(failedMessageRaw, type: Message.self)
    }
}

// Extracted like this since we need to use it directly, as well as from contexts which may not carry generic information
// such as the InvokeSupervisionClosureContext where we invoke things via a function calling into this one to avoid the
// generics issue.
private func renderUserMessageDescription<Message>(_ ptr: UnsafeMutableRawPointer, type: Message.Type) -> String {
    let envelope = ptr.assumingMemoryBound(to: Envelope<Message>.self).move()
    switch envelope.payload {
    case .closure: return "closure"
    case .userMessage(let message): return "[\(message)]:\(Message.self)"
    }
}
private func renderSystemMessageDescription(_ ptr: UnsafeMutableRawPointer) -> String {
    let systemMessage = ptr.assumingMemoryBound(to: SystemMessage.self).move()
    return "[\(systemMessage)]:\(SystemMessage.self)"
}

// MARK: Custom string representations of C-defined enumerations

/// Helper for rendering the C defined `MailboxRunResult` enum in human readable format
extension MailboxRunResult: CustomStringConvertible {
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
        case .failureTerminate:
            return "MailboxRunResult.failureTerminate"
        case .failureRestart:
            return "MailboxRunResult.failureRestart"
        }
    }
}

/// Helper for rendering the C defined `MailboxRunResult` enum in human readable format
extension ActorRunResult: CustomStringConvertible {
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
extension MailboxRunPhase: CustomStringConvertible {
    public var description: String {
        switch self {
        case MailboxRunPhase.processingUserMessages:   return "MailboxRunPhase.processingUserMessages"
        case MailboxRunPhase.processingSystemMessages: return "MailboxRunPhase.processingSystemMessages"
        }
    }
}
