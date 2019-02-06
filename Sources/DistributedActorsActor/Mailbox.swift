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

enum WrappedMessage<Message> {
    case userMessage(Message)
    case closure(() throws -> Void)
}

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

    init(cell: ActorCell<Message>, capacity: Int, maxRunLength: Int = 100) {
        self.mailbox = cmailbox_create(Int64(capacity), Int64(maxRunLength));
        self.cell = cell
        self.path = cell.path
        self.deadLetters = cell.system.deadLetters

        // We first need set the functions, in order to allow the context objects to close over self safely (and even compile)

        self.interpretMessage = { ctxPtr, msgPtr, runPhase in
            defer { msgPtr?.deallocate() }
            let ctx = ctxPtr?.assumingMemoryBound(to: InterpretMessageClosureContext.self)

            var shouldContinue: Bool
            do {
                shouldContinue = try ctx?.pointee.exec(with: msgPtr!, runPhase: runPhase) ?? false
            } catch {
                traceLog_Mailbox("Error while processing message! Was: \(error) TODO supervision decisions...")

                // TODO: supervision can decide to stop... we now stop always though
                shouldContinue = ctx?.pointee.fail(error: error) ?? false // TODO: supervision could be looped in here somehow...? fail returns the behavior to interpret etc, 2nd failure is a hard crash tho perhaps -- ktoso
            }

            return shouldContinue
        }
        self.dropMessage = { (ctxPtr, msgPtr) in
            defer { msgPtr?.deallocate() }
            let ctx = ctxPtr?.assumingMemoryBound(to: DropMessageClosureContext.self)
            do {
                try ctx?.pointee.drop(with: msgPtr!)
            } catch {
                traceLog_Mailbox("Error while dropping message! Was: \(error) TODO supervision decisions...")
            }
        }
        self.invokeSupervision = { ctxPtr, runPhase, failedMessagePtr in
            traceLog_Mailbox("Actor has faulted, supervisor to decide course of action.")

            if let crashDetails = FaultHandling.getCrashDetails() {
                if let ctx: InvokeSupervisionClosureContext = ctxPtr?.assumingMemoryBound(to: InvokeSupervisionClosureContext.self).pointee {
                    traceLog_Mailbox("Run failed in phase \(runPhase)")

                    let messageDescription = ctx.renderMessageDescription(runPhase: runPhase, failedMessageRaw: failedMessagePtr!)
                    let failure = MessageProcessingFailure(messageDescription: messageDescription, backtrace: crashDetails.backtrace)

                    do {
                        return try ctx.handleMessageFailure(.fault(failure), whileProcessing: runPhase)
                    } catch {
                        traceLog_Supervision("Supervision: Double-fault during supervision, unconditionally hard crashing the system: \(error)")
                        exit(-1)
                    }
                } else {

                    traceLog_Supervision("No crash details...")
                    // no crash details, so we can't invoke supervision; Let it Crash!
                    return .failure
                }
            } else {

                traceLog_Supervision("No crash details...")
                // no crash details, so we can't invoke supervision; Let it Crash!
                return .failure
            }
        }

        // Contexts aim to capture self.cell, but can't since we are not done initializing
        // all self references so Swift does not allow us to write self.cell in them.

        self.messageClosureContext = InterpretMessageClosureContext(exec: { [weak _cell = cell] envelopePtr, runPhase in
            assert(runPhase == .processingUserMessages, "Expected to be in runPhase = ProcessingSystemMessages, but was not!")
            guard let cell = _cell else {
                return false
            }

            let envelopePtr = envelopePtr.assumingMemoryBound(to: Envelope<Message>.self)
            let envelope = envelopePtr.move()
            let msg = envelope.payload

            let oldMetadata = Mailbox.populateLoggerMetadata(cell, from: envelope)
            defer { Mailbox.resetLoggerMetadata(cell, to: oldMetadata) }

            traceLog_Mailbox("INVOKE MSG: \(msg)")
            switch msg {
            case .userMessage(let message): return try cell.interpretMessage(message: message)
            case .closure(let f):           return try cell.interpretClosure(f)
            }
        }, fail: { [weak _cell = cell] error in
            _cell?.fail(error: error)
        })
        self.systemMessageClosureContext = InterpretMessageClosureContext(exec: { [weak _cell = cell] sysMsgPtr, runPhase in
            assert(runPhase == .processingSystemMessages, "Expected to be in runPhase = ProcessingSystemMessages, but was not!")
            guard let cell = _cell else {
                return false
            }

            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            traceLog_Mailbox("INVOKE SYSTEM MSG: \(msg)")
            return try cell.interpretSystemMessage(message: msg)
        }, fail: { [weak _cell = cell] error in
            _cell?.fail(error: error)
        })

        self.deadLetterMessageClosureContext = DropMessageClosureContext(drop: { [weak _cell = cell] envelopePtr in
            guard let cell = _cell else {
                return
            }

            let envelopePtr = envelopePtr.assumingMemoryBound(to: Envelope<Message>.self)
            let envelope = envelopePtr.move()
            let msg = envelope.payload
            traceLog_Mailbox("DEAD LETTER USER MESSAGE [\(msg)]:\(type(of: msg))") // TODO this is dead letters, not dropping
            cell.sendToDeadLetters(message: msg)
        })
        self.deadLetterSystemMessageClosureContext = DropMessageClosureContext(drop: { [weak _cell = cell] sysMsgPtr in
            guard let cell = _cell else {
                return
            }
            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            traceLog_Mailbox("DEAD SYSTEM LETTERING [\(msg)]:\(type(of: msg))") // TODO this is dead letters, not dropping
            cell.sendToDeadLetters(message: msg)
        })

        self.invokeSupervisionClosureContext = InvokeSupervisionClosureContext(
            logger: cell.log,
            handleMessageFailure: { [weak _cell = cell] supervisionFailure, runPhase in
                guard let cell = _cell else {
                    return .close
                }

                traceLog_Supervision("INVOKE SUPERVISION !!! FAILURE: \(supervisionFailure)")

                let supervisionResultingBehavior: Behavior<Message>

                // TODO improve logging, should include what decision was taken; same for THROWN
                cell.log.warning("Supervision: Actor has FAULTED [\(String(describing: supervisionFailure))]:\(type(of: supervisionFailure)) while interpreting \(runPhase), handling with \(cell.supervisor); Failure details: \(String(reflecting: supervisionFailure))")

                switch runPhase {
                case .processingSystemMessages:
                    supervisionResultingBehavior = try cell.supervisor.handleFailure(cell.context, target: cell.behavior, failure: supervisionFailure, processingType: .signal)
                case .processingUserMessages:
                    supervisionResultingBehavior = try cell.supervisor.handleFailure(cell.context, target: cell.behavior, failure: supervisionFailure, processingType: .message)
                }

                // TODO: this handling MUST be aligned with the throws handling.
                switch supervisionResultingBehavior {
                case .stopped:
                    // decision is to stop which is terminal, thus: Let it Crash!
                    return .failure
                case .failed(let error): // TODO: Carry this error to supervision?
                    // decision is to fail, Let it Crash!
                    return .failure
                case let restartWithBehavior:
                    // received new behavior, attempting restart:
                    do {
                        try cell.restart(behavior: restartWithBehavior)
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
        cmailbox_destroy(mailbox)
    }

    @inlinable
    func sendMessage(envelope: Envelope<Message>) {
        // while terminating (closing) the mailbox, we immediately dead-letter new user messages
        guard !cmailbox_is_closed(mailbox) else { // TODO: additional atomic read... would not be needed if we "are" the (c)mailbox, since first thing it does is to read status
            traceLog_Mailbox("Mailbox(\(self.path)) is closing, dropping message \(envelope)")
            return // TODO: drop messages (if we see Closed (terminated, terminating) it means the mailbox has been freed already) -> can't enqueue
        }

        guard let cell = self.cell else {
            traceLog_Mailbox("Actor(\(self.path)) has already stopped, dropping message \(envelope)")
            return // TODO: drop messages (if we see Closed (terminated, terminating) it means the mailbox has been freed already) -> can't enqueue
        }

        let ptr = UnsafeMutablePointer<Envelope<Message>>.allocate(capacity: 1)
        ptr.initialize(to: envelope)

        let shouldSchedule = cmailbox_send_message(mailbox, ptr)
        if shouldSchedule { // TODO: if we were the same as the cmailbox, a single status read would tell us if we can exec or not (see above guard)
            cell.dispatcher.execute(self.run)
        }
    }

    @inlinable
    func sendSystemMessage(_ systemMessage: SystemMessage) {
        // TODO: additional atomic read... would not be needed if we "are" the (c)mailbox, since first thing it does is to read status
        // performing an additional read is incorrect, since we have to make all decisions based on the same read value
        // we could pull this off if we had a swift mailbox here, OR we pass in the read status into the send_message...
        // though that splits the logic between swift and C even more making it more confusing I think

        guard let cell = self.cell else {
            self.deadLetters.tell(DeadLetter(systemMessage))
            traceLog_Mailbox("Actor(\(self.path)) has already stopped, dropping system message \(systemMessage)")
            return // TODO: drop messages (if we see Closed (terminated, terminating) it means the mailbox has been freed already) -> can't enqueue
        }

        let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
        ptr.initialize(to: systemMessage)

        let schedulingDecision = cmailbox_send_system_message(mailbox, ptr)
        if schedulingDecision == 0 {
            // enqueued, we have to schedule
            traceLog_Mailbox("\(self.path) Enqueued system message \(systemMessage), we trigger scheduling")
            cell.dispatcher.execute(self.run)
        } else if schedulingDecision < 0 {
            // not enqueued, mailbox is closed, actor is terminating/terminated
            //
            // it is crucial for correctness of death watch that we drain messages to dead letters,
            // which in turn is able to handle watch() automatically for us there;
            // knowing that the watch() was sent to a terminating or dead actor.
            traceLog_Mailbox("Dead letter: \(systemMessage), since mailbox is closed")
            cell.sendToDeadLetters(message: systemMessage) // FIXME: we need to have a ref to dead letters even if cell is gone
        } else { // schedulingDecision > 0 {
            // this means we enqueued, and the mailbox already will be scheduled by someone else
            traceLog_Mailbox("\(self.path) Enqueued system message \(systemMessage), someone scheduled already")
        }
    }

    @inlinable
    func run() {
        // For every run we make we mark "we are inside of an mailbox run now" and remove the marker once the run completes.
        // This is because fault handling MUST ONLY be triggered for mailbox runs, we do not want to handle arbitrary failures on this thread.
        FaultHandling.enableFaultHandling()
        defer { FaultHandling.disableFaultHandling() }

        guard let cell = self.cell else {
            traceLog_Mailbox("Actor(\(self.path)) has already stopped, ignoring run")
            return // TODO: drop messages (if we see Closed (terminated, terminating) it means the mailbox has been freed already) -> can't enqueue
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
            // no more messages to run, we are done here
            return
        case .close:
            // termination has been set as mailbox status and we should send ourselves the .tombstone
            // which serves as final system message after which termination will completely finish.
            // We do this since while the mailbox was running, more messages could have been enqueued,
            // and now we need to handle those that made it in, before the terminating status was set.
            self.sendSystemMessage(.tombstone) // Rest in Peace
        case .failure:
            let failedRunPhase = runPhase
            self.crashFailCellWithBestPossibleError(failedMessagePtr: failedMessagePtr, runPhase: failedRunPhase)
        case .failureRestart:
            // FIXME: !!! we must know if we should schedule or not after a restart...
            traceLog_Supervision("Supervision: Mailbox run complete, restart decision! RESCHEDULING (TODO FIXME IF WE SHOULD OR NOT)") // FIXME
            cell.dispatcher.execute(self.run)
        }
    }

    /// May only be invoked by the cell and puts the mailbox into TERMINATING state.
    func setFailed() {
        traceLog_Mailbox("<<< SET_FAILED \(self.path) >>>")
        cmailbox_set_terminating(self.mailbox)
    }

    /// May only be invoked when crossing TERMINATING->CLOSED states, only by the ActorCell.
    func setClosed() {
        traceLog_Mailbox("<<< SET_CLOSED \(self.path) >>>")
        cmailbox_set_closed(self.mailbox)
    }
}

// MARK: Crash handling functions for Mailbox

extension Mailbox {
    private func crashFailCellWithBestPossibleError(failedMessagePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>, runPhase: MailboxRunPhase) {
        guard let cell = self.cell else {
            traceLog_Mailbox("Actor(\(self.path)) has already stopped, ignoring run")
            return // TODO: drop messages (if we see Closed (terminated, terminating) it means the mailbox has been freed already) -> can't enqueue
        }

        if let crashDetails = FaultHandling.getCrashDetails() {
            if let failedMessageRaw = failedMessagePtr.pointee {
                defer { failedMessageRaw.deallocate() }

                // appropriately render the message (recovering generic information thanks to the passed in type)
                let messageDescription = renderMessageDescription(runPhase: runPhase, failedMessageRaw: failedMessageRaw, userMessageType: Message.self)
                let failure = MessageProcessingFailure(messageDescription: messageDescription, backtrace: crashDetails.backtrace)
                cell.crashFail(error: failure)
            } else {
                let failure = MessageProcessingFailure(messageDescription: "UNKNOWN", backtrace: crashDetails.backtrace)
                cell.crashFail(error: failure)
            }
        } else {
            let failure: MessageProcessingFailure = MessageProcessingFailure(messageDescription: "Error received, but no details set. Supervision omitted.", backtrace: [])
            cell.crashFail(error: failure)
        }
    }
}

// TODO: separate metadata things from the mailbox, perhaps rather we should do it inside the run (pain to do due to C interop a bit?)
extension Mailbox {
    internal static func populateLoggerMetadata(_ cell:  ActorCell<Message>, from envelope: Envelope<Message>) -> Logging.Metadata {
        let old = cell.log.metadata
        #if SACT_DEBUG
        cell.log[metadataKey: "actorSenderPath"] = .lazy({ .string(envelope.senderPath.description) })
        #endif
        return old
    }
    internal static func resetLoggerMetadata(_ cell:  ActorCell<Message>, to metadata: Logging.Metadata) {
        cell.log.metadata = metadata
    }
}

internal struct MessageProcessingFailure: Error {
    let messageDescription: String
    let backtrace: [String] // TODO: Could be worth it to carry it as struct rather than the raw string?
}

extension MessageProcessingFailure: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        let backtraceStr = backtrace.joined(separator: "\n")
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
    private let _exec: (UnsafeMutableRawPointer, MailboxRunPhase) throws -> Bool
    private let _fail: (Error) -> ()

    init(exec: @escaping (UnsafeMutableRawPointer, MailboxRunPhase) throws -> Bool,
         fail: @escaping (Error) -> ()) {
        self._exec = exec
        self._fail = fail
    }

    @inlinable
    func exec(with ptr: UnsafeMutableRawPointer, runPhase: MailboxRunPhase) throws -> Bool {
        return try self._exec(ptr, runPhase)
    }

    @inlinable
    func fail(error: Error) -> Bool {
        _fail(error) // mutates ActorCell to become failed
        return false // TODO: cell to decide if to continue later on (supervision); cleanup how we use this return value
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
        case .done:
            return "MailboxRunResult.done"
        case .reschedule:
            return "MailboxRunResult.reschedule"
        case .failure:
            return "MailboxRunResult.failure"
        case .failureRestart:
            return "MailboxRunResult.failureRestart"
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
