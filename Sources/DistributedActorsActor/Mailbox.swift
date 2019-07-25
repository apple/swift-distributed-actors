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

// this used to be typed according to the actor message type, but we found
// that it added some runtime overhead when retrieving the messages from the
// queue, because additional metatype information was retrieved, therefore
// we removed it
internal enum WrappedMessage {
    case userMessage(Any)
    case closure(() throws -> Void)
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

internal final class Mailbox<Message> {
    private var mailbox: UnsafeMutablePointer<CSActMailbox>
    // we keep the path, rather than the entire address since we know it is "us" so it has to be local
    private let address: ActorAddress
    private weak var shell: ActorShell<Message>?
    private let deadLetters: ActorRef<DeadLetter>

    // Implementation note: context for closure callbacks used for C-interop
    // They are never mutated, yet have to be `var` since passed to C (need inout semantics)
    private var messageClosureContext: InterpretMessageClosureContext!
    private var systemMessageClosureContext: InterpretMessageClosureContext!
    private var deadLetterMessageClosureContext: DropMessageClosureContext!
    private var deadLetterSystemMessageClosureContext: DropMessageClosureContext!
    private var invokeSupervisionClosureContext: InvokeSupervisionClosureContext!

    // Implementation note: closure callbacks passed to C-mailbox
    private let interpretMessage: SActInterpretMessageCallback
    private let dropMessage: SActDropMessageCallback
    // Enables supervision to work for faults (and not only errors).
    // If the currently run behavior is wrapped using a supervision interceptor,
    // we store a reference to its Supervisor handler, that we invoke
    private let invokeSupervision: SActInvokeSupervisionCallback

    /// If `true`, all messages should be attempted to be serialized before sending
    private let serializeAllMessages: Bool
    private let handleCrashes: Bool
    private var _run: () -> Void = {}

    init(shell: ActorShell<Message>, capacity: UInt32, maxRunLength: UInt32 = 100) {
        self.mailbox = cmailbox_create(capacity, maxRunLength)
        self.shell = shell
        self.address = shell.address
        self.deadLetters = shell.system.deadLetters

        // TODO not entirely happy about the added weight, but I suppose avoiding going all the way "into" the settings on each send is even worse?
        self.serializeAllMessages = shell.system.settings.serialization.allMessages
        self.handleCrashes = shell.system.settings.faultSupervisionMode.isEnabled

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
            case .userMessage(let message): 
                traceLog_Mailbox(self.address.path, "INVOKE MSG: \(message)")
                return try shell.interpretMessage(message: message as! Message)
            case .closure(let f):
                traceLog_Mailbox(self.address.path, "INVOKE CLOSURE: \(String(describing: f))")
                return try shell.interpretClosure(f)
            }
        }, fail: { [weak _shell = shell, path = self.address.path] error in
            traceLog_Mailbox(_shell?.path, "FAIL THE MAILBOX")
            switch _shell {
            case .some(let cell): cell.fail(error)
            case .none:           pprint("Mailbox(\(path)) TRIED TO FAIL ON AN ALREADY DEAD CELL")
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
            case .userMessage(let userMessage):
                deadLetters.tell(DeadLetter(userMessage, recipient: address))
            case .closure(let f):
                deadLetters.tell(DeadLetter("[\(String(describing: f))]:closure", recipient: address))
            }
        })
        self.deadLetterSystemMessageClosureContext = DropMessageClosureContext(drop: {
                [deadLetters = self.deadLetters, address = self.address] sysMsgPtr in
            let envelopePtr = sysMsgPtr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            deadLetters.tell(DeadLetter(msg, recipient: address))
        })

        // This closure acts similar to a "catch" block, however it is invoked when a fault is captured.
        // It has to implement the equivalent of `Supervisor.interpretSupervised`, for the fault handling path.
        self.invokeSupervisionClosureContext = InvokeSupervisionClosureContext(
            handleMessageFailure: { [weak _shell = shell] supervisionFailure, runPhase in
                guard let shell = _shell else {
                    /// if we cannot unwrap the cell it means it was closed and deallocated
                    return .close
                }

                traceLog_Mailbox(self.address.path, "INVOKE SUPERVISION !!! FAILURE: \(supervisionFailure)")

                // TODO improve logging, should include what decision was taken; same for THROWN
                shell.log.warning("Supervision: Actor has FAULTED while \("\(runPhase)".split(separator: ".").dropFirst().first!), handling with \(shell.supervisor); Failure details: \(String(reflecting: supervisionFailure))")

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
                    // decision is to stop which is terminal, thus: Let it Crash!
                    return .failureTerminate

                case .escalate:
                    // failure escalated "all the way", so decision is to fail, Let it Crash!
                    // TODO escalate to parent via terminated with the error?
                    // TODO do we need to crash children explicitly here?
                    return .failureTerminate

                case .restartImmediately(let nextBehavior):
                    do {
                        // received new behavior, restarting immediately
                        try shell._restartPrepare()
                        _ = try shell._restartComplete(with: nextBehavior)
                        return .failureRestart
                    } catch {
                        fatalError("Double fault while restarting actor \(shell.path). Terminating.")
                    }

                case .restartDelayed(let delay, let nextBehavior):
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
                return renderUserMessageDescription(failedMessageRawPtr, type: Message.self)
            })

        self._run = self.run
    }

    deinit {
        // TODO: maybe we can free the queues themselfes earlier, and only keep the status marker somehow?
        // TODO: if Closed we know we'll never allow an enqueue ever again after all // FIXME: hard to pull off with the CMailbox...
        
        // TODO: assert that no system messages in queue
        
        traceLog_Mailbox(self.address.path, "Mailbox deinit")
        cmailbox_destroy(mailbox)
    }

    @inlinable
    func sendMessage(envelope: Envelope, file: String, line: UInt) {
        if self.serializeAllMessages {
            var messageDescription = "[\(envelope.payload)]"
            do {
                if case .userMessage(let message) = envelope.payload {
                    messageDescription = "[\(message)]:\(type(of: message))"
                    try shell?.system.serialization.verifySerializable(message: message as! Message)
                }
            } catch {
                fatalError("Serialization check failed for message \(messageDescription) sent at \(file):\(line). " + 
                    "Make sure this type has either a serializer registered OR is marked as `NoSerializationVerification`. " + 
                    "This check was performed since `settings.serialization.allMessages` was enabled.")
            }
        }

        let ptr = UnsafeMutablePointer<Envelope>.allocate(capacity: 1)
        ptr.initialize(to: envelope)

        func sendAndDropAsDeadLetter(shell: ActorShell<Message>?) {
            if let shell = shell {
                self.deadLetters.tell(DeadLetter(envelope.payload, recipient: shell.address,  sentAtFile: file, sentAtLine: line))
            }
            _ = ptr.move()
            ptr.deallocate()
        }

        switch cmailbox_send_message(mailbox, ptr) {
        case .needsScheduling:
            guard let cell = self.shell else {
                traceLog_Mailbox(self.address.path, "has already stopped, dropping message \(envelope)")
                return // TODO: drop messages (if we see Closed (terminated, terminating) it means the mailbox has been freed already) -> can't enqueue
            }
            traceLog_Mailbox(self.address.path, "Enqueued message \(envelope.payload), scheduling for execution")
            cell.dispatcher.execute(self._run)
        case .alreadyScheduled:
            traceLog_Mailbox(self.address.path, "Enqueued message \(envelope.payload), someone scheduled already")

        case .mailboxTerminating:
            // TODO: Sanity check; we can't immediately send it to dead letters just yet since first all user messages
            //       already enqueued must be dropped. This is done by the "tombstone run". After it mailbox becomes closed 
            //       and we can immediately send things to dead letters then. 
            sendAndDropAsDeadLetter(shell: self.shell)
        case .mailboxClosed:
            traceLog_Mailbox(self.address.path, "is CLOSED, dropping message \(envelope)")
            sendAndDropAsDeadLetter(shell: self.shell)
        case .mailboxFull:
            traceLog_Mailbox(self.address.path, "is full, dropping message \(envelope)")
            sendAndDropAsDeadLetter(shell: self.shell) // TODO "Drop" rather than DeadLetter
        }
    }

    @inlinable
    func sendSystemMessage(_ systemMessage: SystemMessage, file: String, line: UInt) {
        guard let cell = self.shell else {
            self.deadLetters.tell(DeadLetter(systemMessage, recipient: nil))
            traceLog_Mailbox(self.address.path, "has already released the actor cell, dropping system message \(systemMessage)")
            return
        }

        let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
        ptr.initialize(to: systemMessage)

        func sendAndDropAsDeadLetter() {
            // TODO should deadLetters be special, since watching it is nonsense?
            self.deadLetters.tell(DeadLetter(systemMessage, recipient: cell.address, sentAtFile: file, sentAtLine: line), file: file, line: line)
        }

        switch cmailbox_send_system_message(mailbox, ptr) {
        case .needsScheduling:
            traceLog_Mailbox(self.address.path, "Enqueued system message \(systemMessage), scheduling for execution")
            cell.dispatcher.execute(self._run)
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

        switch cmailbox_send_system_tombstone(mailbox, ptr) {
        case .mailboxTerminating:
            // Good. After all this function must only be called exactly once, exactly during the run causing the termination.
            cell.dispatcher.execute(self._run)
        default:
            fatalError("!!! BUG !!! Tombstone was attempted to be enqueued at not terminating actor \(self.address). THIS IS A BUG.")
        }

    }

    @inlinable
    func run() {
        if self.handleCrashes {
            // For every run we make we mark "we are inside of an mailbox run now" and remove the marker once the run completes.
            // This is because fault handling MUST ONLY be triggered for mailbox runs, we do not want to handle arbitrary failures on this thread.
            FaultHandling.enableFaultHandling()
        }
        defer { FaultHandling.disableFaultHandling() }

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
            &cell, self.handleCrashes,
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
            cell.dispatcher.execute(self._run)
        case .done:
            // No more messages to run, we are done here
            return

        case .failureRestart:
            // in case of a failure, we need to deinitialize the message here,
            // because usually it would be deinitialized after processing,
            // but in case of a failure that code can not be executed
            failedMessagePtr.deinitialize(count: 1)
            // FIXME: !!! we must know if we should schedule or not after a restart...
            traceLog_Supervision("Supervision: Mailbox run complete, restart decision! RESCHEDULING (TODO FIXME IF WE SHOULD OR NOT)") // FIXME
            cell.dispatcher.execute(self._run)

        case .failureTerminate:
            // in case of a failure, we need to deinitialize the message here,
            // because usually it would be deinitialized after processing,
            // but in case of a failure that code can not be executed
            failedMessagePtr.deinitialize(count: 1)

            // We are now terminating. The run has been aborted and other threads were not yet allowed to activate this
            // actor (since it was in the middle of processing). We MUST therefore activate right now, and at the same time
            // force the enqueue of the tombstone system message, as the actor now will NOT accept any more messages
            // and will dead letter them. We need to process all existing system messages though all the way to the tombstone,
            // before we become CLOSED.

            // Meaning supervision was either applied and decided to fail, or not applied and we should fail anyway.
            // We have to guarantee the processing of any outstanding system messages, and use a tombstone marker to notice this.
            let failedRunPhase = runPhase
            self.reportCrashFailCellWithBestPossibleError(shell: cell, failedMessagePtr: failedMessagePtr, runPhase: failedRunPhase)

            // since we may have faulted while processing user messages, while system messages were being enqueued,
            // we have to perform one last run to potentially drain any remaining system messages to dead letters for
            // death watch correctness.
            traceLog_Mailbox(self.address.path, "interpret failureTerminate")
            self.sendSystemTombstone() // Rest in Peace
        case .close:
            // termination has been set as mailbox status and we should send ourselves the .tombstone
            // which serves as final system message after which termination will completely finish.
            // We do this since while the mailbox was running, more messages could have been enqueued,
            // and now we need to handle those that made it in, before the terminating status was set.
            traceLog_Mailbox(self.address.path, "interpret CLOSE")
            self.sendSystemTombstone() // Rest in Peace
        case .closed:
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
}

// MARK: Crash handling functions for Mailbox

extension Mailbox {
    
    // TODO rename to "log crash error"?
    private func reportCrashFailCellWithBestPossibleError(shell: ActorShell<Message>, failedMessagePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>, runPhase: SActMailboxRunPhase) {
        
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

        shell.reportCrashFail(cause: failure)
    }
}

// TODO: separate metadata things from the mailbox, perhaps rather we should do it inside the run (pain to do due to C interop a bit?)
extension Mailbox {
    // TODO: enable again once https://github.com/apple/swift-log/issues/37 is resolved
//    internal static func populateLoggerMetadata(_ shell:  ActorShell<Message>, from envelope: Envelope<Message>) -> Logger.Metadata {
//        let old = shell.log.metadata
//        #if SACT_DEBUG
//        shell.log[metadataKey: "actorSenderPath"] = .lazy({ .string(envelope.senderPath.description) })
//        #endif
//        return old
//    }
//    internal static func resetLoggerMetadata(_ shell:  ActorShell<Message>, to metadata: Logger.Metadata) {
//        cell.log.metadata = metadata
//    }
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
    private let _exec: (UnsafeMutableRawPointer, UnsafeMutableRawPointer, SActMailboxRunPhase) throws -> SActActorRunResult
    private let _fail: (Error) -> ()

    init(exec: @escaping (UnsafeMutableRawPointer, UnsafeMutableRawPointer, SActMailboxRunPhase) throws -> SActActorRunResult,
         fail: @escaping (Error) -> ()) {
        self._exec = exec
        self._fail = fail
    }

    @inlinable
    func exec(cellPtr: UnsafeMutableRawPointer, messagePtr: UnsafeMutableRawPointer, runPhase: SActMailboxRunPhase) throws -> SActActorRunResult {
        return try self._exec(cellPtr, messagePtr, runPhase)
    }

    @inlinable
    func fail(error: Error) -> SActActorRunResult {
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
    private let _handleMessageFailureBecauseC: (Supervision.Failure, SActMailboxRunPhase) throws -> SActMailboxRunResult

    // Since we cannot close over generic context here, we invoke the generic requiring rendering inside this
    private let _describeMessage: (UnsafeMutableRawPointer) -> String

    init(handleMessageFailure: @escaping (Supervision.Failure, SActMailboxRunPhase) throws -> SActMailboxRunResult,
         describeMessage: @escaping (UnsafeMutableRawPointer) -> String) {
        self._handleMessageFailureBecauseC = handleMessageFailure
        self._describeMessage = describeMessage
    }

    @inlinable
    func handleMessageFailure(_ failure: Supervision.Failure, whileProcessing runPhase: SActMailboxRunPhase) throws -> SActMailboxRunResult {
        return try self._handleMessageFailureBecauseC(failure, runPhase)
    }

    // hides the generic Message and provides same capabilities of rendering messages as the free function of the same name
    @inlinable
    func renderMessageDescription(runPhase: SActMailboxRunPhase, failedMessageRaw: UnsafeMutableRawPointer) -> String {
        switch runPhase {
        case .processingSystemMessages:
            // we can invoke it directly since it is not generic
            return renderSystemMessageDescription(failedMessageRaw)

        case .processingUserMessages:
            // since Message is generic, we need to hop over the provided function which was allowed to close over the generic state
            return self._describeMessage(failedMessageRaw)
        }
    }
}

/// Renders a `SystemMessage` or user `Message` appropriately given a raw pointer to such message.
/// Only really needed due to the c-interop of failure handling where we need to recover the lost generic information this way.
private func renderMessageDescription<Message>(runPhase: SActMailboxRunPhase, failedMessageRaw: UnsafeMutableRawPointer, userMessageType: Message.Type) -> String {
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
    let envelope = ptr.assumingMemoryBound(to: Envelope.self).pointee
    switch envelope.payload {
    case .closure: return "closure"
    case .userMessage(let message): return "[\(message)]:\(Message.self)"
    }
}
private func renderSystemMessageDescription(_ ptr: UnsafeMutableRawPointer) -> String {
    let systemMessage = ptr.assumingMemoryBound(to: SystemMessage.self).pointee
    return "[\(systemMessage)]:\(SystemMessage.self)"
}

// MARK: Custom string representations of C-defined enumerations

/// Helper for rendering the C defined `MailboxRunResult` enum in human readable format
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
        case .failureTerminate:
            return "MailboxRunResult.failureTerminate"
        case .failureRestart:
            return "MailboxRunResult.failureRestart"
        }
    }
}

/// Helper for rendering the C defined `MailboxRunResult` enum in human readable format
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
