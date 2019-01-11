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
import CQueue
import CDungeon
import Foundation

/// INTERNAL API
struct Envelope<Message> {
    let payload: Message

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
}

// TODO: we may have to make public to enable inlining? :-( https://github.com/apple/swift-distributed-actors/issues/69
final class Mailbox<Message> {
    private var mailbox: UnsafeMutablePointer<CMailbox>
    private var cell: ActorCell<Message>

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

        // We first need set the functions, in order to allow the context objects to close over self safely (and even compile)

        self.interpretMessage = { (ctxPtr, msgPtr) in
            defer { msgPtr?.deallocate() }
            let ctx = ctxPtr?.assumingMemoryBound(to: InterpretMessageClosureContext.self)

            var shouldContinue: Bool
            do {
                shouldContinue = try ctx?.pointee.exec(with: msgPtr!) ?? false
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
        self.invokeSupervision = { (ctxPtr, failedMessagePtr) in
            traceLog_Mailbox("Supervision: Actor has faulted, supervisor to decide course of action.")

            if let crashDetails = FaultHandling.getCrashDetails() {
                if let ctx = ctxPtr?.assumingMemoryBound(to: InvokeSupervisionClosureContext.self).pointee {

                    let runPhase: MailboxRunPhase = ProcessingUserMessages // FIXME
                    let messageDescription = ctx.renderMessageDescription(runPhase: runPhase, failedMessageRaw: failedMessagePtr!) // FIXME that !
                    let failure = MessageProcessingFailure(messageDescription: messageDescription, backtrace: crashDetails.backtrace)

                    do {
                        return try ctx.handleMessageFailure(.fault(failure), whileProcessing: runPhase)
                    } catch {
                        pprint("Supervision: Double-fault during supervision, unconditionally hard crashing the system: \(error)")
                        exit(-1)
                    }
                } else {

                    pprint("No crash details...")
                    // no crash details, so we can't invoke supervision; Let it Crash!
                    return Failure
                }
            } else {

                pprint("No crash details...")
                // no crash details, so we can't invoke supervision; Let it Crash!
                return Failure
            }
        }

        // Contexts aim to capture self.cell, but can't since we are not done initializing
        // all self references so Swift does not allow us to write self.cell in them.

        self.messageClosureContext = InterpretMessageClosureContext(exec: { envelopePtr in
            let envelopePtr = envelopePtr.assumingMemoryBound(to: Envelope<Message>.self)
            let envelope = envelopePtr.move()
            let msg = envelope.payload
            traceLog_Mailbox("INVOKE MSG: \(msg)")
            return try self.cell.interpretMessage(message: msg)
        }, fail: { error in
            self.cell.fail(error: error)
        })
        self.systemMessageClosureContext = InterpretMessageClosureContext(exec: { sysMsgPtr in
            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            traceLog_Mailbox("INVOKE SYSTEM MSG: \(msg)")
            return try self.cell.interpretSystemMessage(message: msg)
        }, fail: { error in
            self.cell.fail(error: error)
        })

        self.deadLetterMessageClosureContext = DropMessageClosureContext(drop: { envelopePtr in
            let envelopePtr = envelopePtr.assumingMemoryBound(to: Envelope<Message>.self)
            let envelope = envelopePtr.move()
            let msg = envelope.payload
            traceLog_Mailbox("DEAD LETTER USER MESSAGE [\(msg)]:\(type(of: msg))") // TODO this is dead letters, not dropping
            self.cell.sendToDeadLetters(message: msg)
        })
        self.deadLetterSystemMessageClosureContext = DropMessageClosureContext(drop: { sysMsgPtr in
            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            traceLog_Mailbox("DEAD SYSTEM LETTERING [\(msg)]:\(type(of: msg))") // TODO this is dead letters, not dropping
            self.cell.sendToDeadLetters(message: msg)
        })

        self.invokeSupervisionClosureContext = InvokeSupervisionClosureContext(
            logger: self.cell.log,
            handleMessageFailure: { supervisionFailure, runPhase in
                traceLog_Mailbox("INVOKE SUPERVISION !!! FAILURE: \(supervisionFailure)")

                if let supervisor = self.cell.supervisedBy {

                    // TODO: these could throw, make sure they do what is expected there.
                    let supervisionResultingBehavior: Behavior<Message>
                    if runPhase == ProcessingUserMessages {
                        supervisionResultingBehavior = try supervisor.handleMessageFailure(self.cell.context, failure: supervisionFailure)
                    } else if runPhase == ProcessingSystemMessages {
                        supervisionResultingBehavior = try supervisor.handleSignalFailure(self.cell.context, failure: supervisionFailure)
                    } else {
                        // This branch need not exist, but the enum we use is C enum so `switch` seems to not work well.
                        fatalError("Bug! The only runPhases that exist should already be taken care of here.")
                    }

                    // TODO: this handling MUST be aligned with the throws handling.
                    switch supervisionResultingBehavior {
                    case .stopped:
                        // decision is to stop which is terminal, thus: Let it Crash!
                        return Failure
                    case .failed(let error):
                        // decision is to fail, Let it Crash!
                        // TODO substitute error with the one from failed
                        return Failure
                    case let restartWithBehavior:
                        // received new behavior, attempting restart:
                        do {
                            try self.cell.restart(behavior: restartWithBehavior)
                        } catch {
                            self.cell.system.terminate() // FIXME nicer somehow, or hard exit() here?
                            fatalError("Double fault while restarting actor \(self.cell.path). Terminating.")
                        }
                        return FailureRestart
                    }
                } else {
                    self.cell.log.warn("Supervision: Not supervised actor, encountered failure: \(supervisionFailure)")
                    return Failure
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
            traceLog_Mailbox("Mailbox(\(self.cell.path)) is closing, dropping message \(envelope)")
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

        let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
        ptr.initialize(to: systemMessage)

        let schedulingDecision = cmailbox_send_system_message(mailbox, ptr)
        if schedulingDecision == 0 {
            // enqueued, we have to schedule
            traceLog_Mailbox("\(self.cell.path) Enqueued system message \(systemMessage), we trigger scheduling")
            self.cell.dispatcher.execute(self.run)
        } else if schedulingDecision < 0 {
            // not enqueued, mailbox is closed, actor is terminating/terminated
            //
            // it is crucial for correctness of death watch that we drain messages to dead letters,
            // which in turn is able to handle watch() automatically for us there;
            // knowing that the watch() was sent to a terminating or dead actor.
            traceLog_Mailbox("Dead letter: \(systemMessage), since mailbox is closed")
            self.cell.sendToDeadLetters(message: systemMessage) // IMPORTANT
        } else { // schedulingDecision > 0 {
            // this means we enqueued, and the mailbox already will be scheduled by someone else
            traceLog_Mailbox("\(self.cell) Enqueued system message \(systemMessage), someone scheduled already")
        }
    }

    @inlinable
    func run() {
        // For every run we make we mark "we are inside of an mailbox run now" and remove the marker once the run completes.
        // This is because fault handling MUST ONLY be triggered for mailbox runs, we do not want to handle arbitrary failures on this thread.
        FaultHandling.enableFaultHandling()
        defer { FaultHandling.disableFaultHandling() }

        // Prepare failure context pointers:
        // In case processing of a message fails, this pointer will point to the message that caused the failure
        let failedMessagePtr = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
        failedMessagePtr.initialize(to: nil)
        defer { failedMessagePtr.deallocate() }
        // In case of a processing failure, this will mark if the fault occurred while processing System or User messages.
        var runPhase: MailboxRunPhase = ProcessingSystemMessages

        // Run the mailbox:
        let schedulingDecision: CMailboxRunResult = cmailbox_run(mailbox,
            &messageClosureContext, &systemMessageClosureContext,
            &deadLetterMessageClosureContext, &deadLetterSystemMessageClosureContext,
            interpretMessage, dropMessage,
            // fault handling:
            FaultHandling.getErrorJmpBuf(), 
            &invokeSupervisionClosureContext, invokeSupervision, failedMessagePtr, &runPhase)

        // TODO: not in love that we have to do logic like this here... with a plain book to continue running or not it is easier
        // but we have to signal the .tombstone AFTER the mailbox has set status to terminating, so we have to do it here... and can't do inside interpretMessage
        // we could offer even more callbacks to C but that is also not quite nice...
        if schedulingDecision == Reschedule {
            // pending messages, and we are the one who should should reschedule
            cell.dispatcher.execute(self.run)
        } else if schedulingDecision == Done {
            // no more messages to run, we are done here
            return
        } else if schedulingDecision == Close {
            // termination has been set as mailbox status and we should send ourselves the .tombstone
            // which serves as final system message after which termination will completely finish.
            // We do this since while the mailbox was running, more messages could have been enqueued,
            // and now we need to handle those that made it in, before the terminating status was set.
            self.sendSystemMessage(.tombstone) // Rest in Peace
        } else if schedulingDecision == Failure {
            self.crashFailCellWithBestPossibleError(failedMessagePtr: failedMessagePtr, runPhase: runPhase)
        } else if schedulingDecision == FailureRestart {
            // FIXME: !!! we must know if we should schedule or not after a restart...
            pprint("MAILBOX RUN COMPLETE, FailureRestart !!! RESCHEDULING (TODO FIXME IF WE SHOULD OR NOT)")
            cell.dispatcher.execute(self.run)
        } else {
            fatalError("BUG: Mailbox did not account for run scheduling decision: \(schedulingDecision)")
        }
    }

    /// May only be invoked by the cell and puts the mailbox into TERMINATING state.
    func setFailed() {
        traceLog_Mailbox("<<< SET_FAILED \(self.cell.path) >>>")
        cmailbox_set_terminating(self.mailbox)
    }

    /// May only be invoked when crossing TERMINATING->CLOSED states, only by the ActorCell.
    func setClosed() {
        traceLog_Mailbox("<<< SET_CLOSED \(self.cell.path) >>>")
        cmailbox_set_closed(self.mailbox)
    }
}

// MARK: Crash handling functions for Mailbox

extension Mailbox {
    private func crashFailCellWithBestPossibleError(failedMessagePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>, runPhase: MailboxRunPhase) {
        if let crashDetails = FaultHandling.getCrashDetails() {
            if let failedMessageRaw = failedMessagePtr.pointee {
                defer { failedMessageRaw.deallocate() }

                // appropriately render the message (recovering generic information thanks to the passed in type)
                let messageDescription = renderMessageDescription(runPhase: runPhase, failedMessageRaw: failedMessageRaw, userMessageType: Message.self)
                let failure = MessageProcessingFailure(messageDescription: messageDescription, backtrace: crashDetails.backtrace)
                self.cell.crashFail(error: failure)
            } else {
                let failure = MessageProcessingFailure(messageDescription: "UNKNOWN", backtrace: crashDetails.backtrace)
                self.cell.crashFail(error: failure)
            }
        } else {
            let failure: MessageProcessingFailure = MessageProcessingFailure(messageDescription: "Error received, but no details set. Supervision omitted.", backtrace: [])
            self.cell.crashFail(error: failure)
        }
    }
}

internal struct MessageProcessingFailure: Error {
    let messageDescription: String
    let backtrace: [String]
}

extension MessageProcessingFailure: CustomStringConvertible {
    var description: String {
        let backtraceStr = backtrace.joined(separator: "\n")
        return "Actor faulted while processing message '\(messageDescription)':\n\(backtraceStr)"
    }
}

// MARK: Closure contexts for interop with C-mailbox

/// Wraps context for use in closures passed to C
private struct InterpretMessageClosureContext {
    private let _exec: (UnsafeMutableRawPointer) throws -> Bool
    private let _fail: (Error) -> ()

    init(exec: @escaping (UnsafeMutableRawPointer) throws -> Bool,
         fail: @escaping (Error) -> ()) {
        self._exec = exec
        self._fail = fail
    }

    @inlinable
    func exec(with ptr: UnsafeMutableRawPointer) throws -> Bool {
        return try self._exec(ptr)
    }

    @inlinable
    func fail(error: Error) -> Bool {
        _fail(error) // mutates ActorCell to become failed
        return false // TODO: cell to decide if to continue later on (supervision)
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
    private let _handleMessageFailureBecauseC: (Supervision.Failure, MailboxRunPhase) throws -> CMailboxRunResult

    // Since we cannot close over generic context here, we invoke the generic requiring rendering inside this
    private let _describeMessage: (UnsafeMutableRawPointer) -> String

    /// The cell's logger may be used to log information about the supervision handling.
    /// We assume that since we run supervision only for "not fatal faults" the logger should still be in an usable state
    /// as we run the supervision handling. The good thing is that all metadata of the cells logger will be included in
    /// crash logs then. It may we worth reconsidering if we need to be even more defensive here, e.g.
    /// take a logger without potential user changes made to it etc.
    private let _log: Logger

    init(logger: Logger, handleMessageFailure: @escaping (Supervision.Failure, MailboxRunPhase) throws -> CMailboxRunResult,
         describeMessage: @escaping (UnsafeMutableRawPointer) -> String) {
        self._log = logger
        self._handleMessageFailureBecauseC = handleMessageFailure
        self._describeMessage = describeMessage
    }

    @inlinable
    func handleMessageFailure(_ failure: Supervision.Failure, whileProcessing msgType: MailboxRunPhase) throws -> CMailboxRunResult {
        return try self._handleMessageFailureBecauseC(failure, msgType)
    }

    // hides the generic Message and provides same capabilities of rendering messages as the free function of the same name
    @inlinable
    func renderMessageDescription(runPhase: MailboxRunPhase, failedMessageRaw: UnsafeMutableRawPointer) -> String {
        if runPhase == ProcessingSystemMessages {
            // we can invoke it directly since it is not generic
            return renderSystemMessageDescription(failedMessageRaw)
        } else {
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
    if runPhase == ProcessingSystemMessages {
        return renderSystemMessageDescription(failedMessageRaw)
    } else {
        return renderUserMessageDescription(failedMessageRaw, type: Message.self)
    }
}

// Extracted like this since we need to use it directly, as well as from contexts which may not carry generic information
// such as the InvokeSupervisionClosureContext where we invoke things via a function calling into this one to avoid the
// generics issue.
private func renderUserMessageDescription<Message>(_ ptr: UnsafeMutableRawPointer, type: Message.Type) -> String {
    let message = ptr.assumingMemoryBound(to: Message.self).move()
    return "[\(message)]:\(Message.self)"
}
private func renderSystemMessageDescription(_ ptr: UnsafeMutableRawPointer) -> String {
    let systemMessage = ptr.assumingMemoryBound(to: SystemMessage.self).move()
    return "[\(systemMessage)]:\(SystemMessage.self)"
}

/// Helper for rendering the C defined `CMailboxRunResult` enum in human readable format
enum MailboxRunResult {
    static func description(_ v: CMailboxRunResult) -> String {
        if v == Close {
            return "CMailboxRunResult(Close)"
        } else if v == Done {
            return "CMailboxRunResult(Done)"
        } else if v == Reschedule {
            return "CMailboxRunResult(Reschedule)"
        } else if v == Reschedule {
            return "CMailboxRunResult(Reschedule)"
        } else if v == Failure {
            return "CMailboxRunResult(Failure)"
        } else if v == FailureRestart {
            return "CMailboxRunResult(FailureRestart)"
        } else {
            fatalError("This is a bug. Unexpected \(v)")
        }
    }
}
