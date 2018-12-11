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

import NIOConcurrencyHelpers
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

/// Wraps context for use in closures passed to C
private struct WrappedClosure {
    private let _exec: (UnsafeMutableRawPointer) throws -> Bool
    private let _fail: (Error) -> ()

    init(exec: @escaping (UnsafeMutableRawPointer) throws -> Bool,
         fail: @escaping (Error) -> ()) {
        self._exec = exec
        self._fail = fail
    }

    @inlinable
    func exec(with ptr: UnsafeMutableRawPointer) throws -> Bool {
        return try _exec(ptr)
    }

    @inlinable
    func fail(error: Error) -> Bool {
        _fail(error) // mutates ActorCell to become failed
        return false // TODO: cell to decide if to continue later on (supervision)
    }
}

/// Wraps context for use in closures passed to C
private struct WrappedDropClosure {
    private let _drop: (UnsafeMutableRawPointer) throws -> ()

    init(drop: @escaping (UnsafeMutableRawPointer) throws -> ()) {
        self._drop = drop
    }

    @inlinable
    func drop(with ptr: UnsafeMutableRawPointer) throws -> () {
        return try _drop(ptr)
    }

}

// TODO: we may have to make public to enable inlining? :-( https://github.com/apple/swift-distributed-actors/issues/69
final class Mailbox<Message> {
    private var mailbox: UnsafeMutablePointer<CMailbox>
    private var cell: ActorCell<Message>

    // Implementation note: WrappedClosures are used for C-interop
    private var messageCallbackContext: WrappedClosure
    private var systemMessageCallbackContext: WrappedClosure
    private var deadLetterMessageCallbackContext: WrappedDropClosure
    private var deadLetterSystemMessageCallbackContext: WrappedDropClosure

    private let interpretMessage: InterpretMessageCallback
    private let dropMessage: DropMessageCallback

    init(cell: ActorCell<Message>, capacity: Int, maxRunLength: Int = 100) {
        self.mailbox = cmailbox_create(Int64(capacity), Int64(maxRunLength));
        self.cell = cell

        // Implementation note:
        // contexts aim to capture self.cell, but can't since we are not done initializing
        // all self references so Swift does not allow us to write self.cell in them.

        self.messageCallbackContext = WrappedClosure(exec: { ptr in
            let envelopePtr = ptr.assumingMemoryBound(to: Envelope<Message>.self)
            let envelope = envelopePtr.move()
            let msg = envelope.payload
            traceLog_Mailbox("INVOKE MSG: \(msg)")
            return try cell.interpretMessage(message: msg)
        }, fail: { error in
            cell.fail(error: error)
        })

        self.systemMessageCallbackContext = WrappedClosure(exec: { ptr in
            let envelopePtr = ptr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            traceLog_Mailbox("INVOKE SYSTEM MSG: \(msg)")
            return try cell.interpretSystemMessage(message: msg)
        }, fail: { error in
            cell.fail(error: error)
        })

        self.deadLetterMessageCallbackContext = WrappedDropClosure(drop: { ptr in
            let envelopePtr = ptr.assumingMemoryBound(to: Envelope<Message>.self)
            let envelope = envelopePtr.move()
            let msg = envelope.payload
            traceLog_Mailbox("DEAD LETTER USER MESSAGE [\(msg)]:\(type(of: msg))") // TODO this is dead letters, not dropping
            cell.sendToDeadLetters(message: msg)
        })
        self.deadLetterSystemMessageCallbackContext = WrappedDropClosure(drop: { ptr in
            let envelopePtr = ptr.assumingMemoryBound(to: SystemMessage.self)
            let msg = envelopePtr.move()
            traceLog_Mailbox("DEAD SYSTEM LETTERING [\(msg)]:\(type(of: msg))") // TODO this is dead letters, not dropping
            cell.sendToDeadLetters(message: msg)
        })

        self.interpretMessage = { (ctxPtr, msgPtr) in
            defer { msgPtr?.deallocate() }
            let ctx = ctxPtr?.assumingMemoryBound(to: WrappedClosure.self)

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
            let ctx = ctxPtr?.assumingMemoryBound(to: WrappedDropClosure.self)
            do {
                try ctx?.pointee.drop(with: msgPtr!)
            } catch {
                traceLog_Mailbox("Error while dropping message! Was: \(error) TODO supervision decisions...")
            }
        }
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
        // Implementation notes: for every run we make
        FaultHandling.enableFailureHandling()
        defer { FaultHandling.disableFailureHandling() }

        // in case processing fails, this will be set to the message that caused the failure
        let failedMessagePtr = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
        defer { failedMessagePtr.deallocate() }

        let schedulingDecision: CMailboxRunResult = cmailbox_run(mailbox,
            &messageCallbackContext, &systemMessageCallbackContext,
            &deadLetterMessageCallbackContext, &deadLetterSystemMessageCallbackContext,
            interpretMessage, dropMessage, FaultHandling.getErrorJmpBuf(), failedMessagePtr)

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
            // termination has been set as mailbox status and we should send ourselfes the .tombstone
            // which serves as final system message after which termination will completely finish.
            // We do this since while the mailbox was running, more messages could have been enqueued,
            // and now we need to handle those that made it in, before the terminating status was set.
            self.sendSystemMessage(.tombstone) // Rest in Peace
        } else if schedulingDecision == Failure {
            if let crashDetails = FaultHandling.getCrashDetails() {
                if let failedMessage = failedMessagePtr.pointee?.assumingMemoryBound(to: Message.self) {
                    defer { failedMessage.deallocate() }
                    self.cell.crashFail(error: MessageProcessingFailure(messageStr: "\(failedMessage.move())", backtrace: crashDetails.backtrace))
                } else {
                    self.cell.crashFail(error: MessageProcessingFailure(messageStr: "UNKNOWN", backtrace: crashDetails.backtrace))
                }
            } else {
                self.cell.crashFail(error: NSError(domain: "Error received, but no details set", code: -1, userInfo: nil))
            }
        }
    }

    /// May only be invoked when crossing TERMINATING->CLOSED states, only by the ActorCell.
    func setClosed() {
        traceLog_Mailbox("<<< SET_CLOSED \(self.cell.path) >>>")
        cmailbox_set_closed(self.mailbox)
    }

    /// May only be invoked by the cell and puts the mailbox into TERMINATING state.
    func setFailed() {
        traceLog_Mailbox("<<< SET_FAILED \(self.cell.path) >>>")
        cmailbox_set_terminating(self.mailbox)
    }
}

internal struct MessageProcessingFailure: Error {
    let messageStr: String
    let backtrace: [String]
}

extension MessageProcessingFailure: CustomStringConvertible {
    var description: String {
        // TODO: add message that caused failure
        let backtraceStr = backtrace.joined(separator: "\n")
        return "Actor failed while processing message '\(messageStr)':\n\(backtraceStr)"
    }
}
