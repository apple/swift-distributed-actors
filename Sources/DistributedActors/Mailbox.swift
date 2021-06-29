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

internal enum MailboxBitMasks {
    static let activations: UInt64 = 0b0000_0000_0000_0000_0000_0000_0000_0111_1111_1111_1111_1111_1111_1111_1111_1111

    static let hasSystemMessages: UInt64 = 0b0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0001
    static let processingSystemMessages: UInt64 = 0b0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0010

    // Implementation notes about Termination:
    // Termination MUST first set TERMINATING and only after add the "final" CLOSED state.
    // In other words, the only legal bit states a mailbox should observe are:
    //  -> 0b000... alive,
    //  -> 0b001... suspended (actor is waiting for completion of AsyncResult and will only process system messages until then),
    //  -> 0b010... terminating,
    //  -> 0b110... closed (also known as: "terminated", "dead")
    //
    // Meaning that `0b100...` is NOT legal.
    static let suspended: UInt64 = 0b0010_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000
    static let terminating: UInt64 = 0b0100_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000
    static let closed: UInt64 = 0b1000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000

    // user message count is stored in bits 2-61, so when incrementing or
    // decrementing the message count, we need to add starting at bit 2
    static let singleUserMessage: UInt64 = 0b0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0100

    // Mask to use with XOR on the status to unset the 'has system messages' bit
    // and set the 'is processing system messages' bit in a single atomic operation
    static let becomeSysMsgProcessingXor: UInt64 = 0b0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0011

    // used to unset the SUSPENDED bit by ANDing with status
    //
    // assume we are suspended and have some system messages and 7 user messages enqueued:
    //      CURRENT STATUS         0b0010_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0001_1101
    //      (operation)          &
    static let unsuspend: UInt64 = 0b1101_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111
    //                             --------------------------------------------------------------------
    //                           = 0b0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0001_1101
}

internal final class Mailbox<Message: ActorMessage> {
    weak var shell: ActorShell<Message>?
    let _status: Atomic<UInt64> = Atomic(value: 0)
    let userMessages: MPSCLinkedQueue<Payload>
    let systemMessages: MPSCLinkedQueue<_SystemMessage>
    let capacity: UInt32
    let maxRunLength: UInt32
    let deadLetters: ActorRef<DeadLetter>
    let address: ActorAddress
    let serializeAllMessages: Bool

    let measureMessages = true

    init(shell: ActorShell<Message>, capacity: UInt32, maxRunLength: UInt32 = 100) {
        #if SACT_TESTS_LEAKS
        if shell.address.segments.first?.value == "user" {
            _ = shell._system?.userMailboxInitCounter.add(1)
        }
        #endif
        self.shell = shell
        self.userMessages = MPSCLinkedQueue()
        self.systemMessages = MPSCLinkedQueue()
        self.capacity = capacity
        self.maxRunLength = maxRunLength
        self.deadLetters = shell.system.deadLetters
        self.address = shell._address

        // TODO: not entirely happy about the added weight, but I suppose avoiding going all the way "into" the settings on each send is even worse?
        self.serializeAllMessages = shell.system.settings.serialization.serializeLocalMessages
    }

    #if SACT_TESTS_LEAKS
    deinit {
        #if SACT_TESTS_LEAKS
        if self.address.segments.first?.value == "user" {
            _ = self.deadLetters._system?.userMailboxInitCounter.sub(1)
        }
        #endif
    }
    #endif

    /// **CAUTION**: For testing purposes only. Not safe to use for actually running actors.
    init(system: ActorSystem, capacity: UInt32, maxRunLength: UInt32 = 100) {
        self.shell = nil
        self.userMessages = MPSCLinkedQueue()
        self.systemMessages = MPSCLinkedQueue()
        self.capacity = capacity
        self.maxRunLength = maxRunLength
        self.deadLetters = system.deadLetters
        self.address = system.deadLetters.address

        // TODO: not entirely happy about the added weight, but I suppose avoiding going all the way "into" the settings on each send is even worse?
        self.serializeAllMessages = system.settings.serialization.serializeLocalMessages
    }

    @inlinable
    func sendMessage(envelope: Payload, file: String, line: UInt) {
        if self.serializeAllMessages {
            var messageDescription = "[\(envelope.payload)]"
            do {
                if case .message(let message) = envelope.payload {
                    messageDescription = "[\(message)]:\(type(of: message))"
                    try self.shell?.system.serialization.verifySerializable(message: message as! Message)
                }
            } catch {
                fatalError("Serialization check failed for message \(messageDescription) sent at \(file):\(line). " +
                    "Make sure this type has either a serializer registered OR is marked as `NonTransportableActorMessage`. " +
                    "This check was performed since `settings.serialization.serializeLocalMessages` was enabled.")
            }
        }

        func sendAndDropAsDeadLetter() {
            self.deadLetters.tell(DeadLetter(envelope.payload, recipient: self.address, sentAtFile: file, sentAtLine: line))
        }

        switch self.enqueueUserMessage(envelope) {
        case .needsScheduling:
            traceLog_Mailbox(self.address.path, "Enqueued message \(envelope.payload), scheduling for execution")
            guard let shell = self.shell else {
                traceLog_Mailbox(self.address.path, "ActorShell was released! Unable to complete sendMessage, dropping: \(envelope)")
                self.deadLetters.tell(DeadLetter(envelope.payload, recipient: self.address, sentAtFile: file, sentAtLine: line))
                break
            }
            shell._dispatcher.execute(self.run)

        case .alreadyScheduled:
            traceLog_Mailbox(self.address.path, "Enqueued message \(envelope.payload), someone scheduled already")

        case .mailboxTerminating:
            // TODO: soundness check; we can't immediately send it to dead letters just yet since first all user messages
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
    func enqueueUserMessage(_ envelope: Payload) -> EnqueueDirective {
        let oldStatus = self.incrementMessageCount()
        guard oldStatus.messageCount < self.capacity else {
            // If we passed the maximum capacity of the user queue, we can't enqueue more
            // items and have to decrement the activations count again. This is not racy,
            // because we only process messages if the queue actually contains them (does
            // not return NULL), so even if messages get processed concurrently, it's safe
            // to decrement here.
            _ = self.decrementMessageCount()
            // metrics: do not update metrics, whoever got the message count to capacity would have already reported the count
            return .mailboxFull
        }

        guard !oldStatus.isTerminating else {
            _ = self.decrementMessageCount()
            // metrics: do not update metrics, whoever caused termination would have already reported the mailbox count then
            return .mailboxTerminating
        }

        guard !oldStatus.isClosed else {
            _ = self.decrementMessageCount()
            // metrics: do not update metrics, closed only happens on a final run, so the message count would have been updated there
            return .mailboxClosed
        }

        // If the mailbox is not full, we insert it into the queue and return,
        // whether this was the first activation, to signal the need to enqueue
        // this mailbox.
        self.userMessages.enqueue(envelope)
        self.shell?.metrics[gauge: .mailboxCount]?.record(oldStatus.messageCount + 1)

        if oldStatus.activations == 0, !oldStatus.isSuspended {
            return .needsScheduling
        } else {
            return .alreadyScheduled
        }
    }

    /// Enqueues `.start` but does NOT activate the actor. Used for LazyStart and MUST be called as
    /// the first thing before the ref is exposed, thus the status MUST be 0, as noone else should have had
    /// any chance to interact with this mailbox yet
    @inlinable
    func enqueueStart() {
        let oldStatus = self.setHasSystemMessages()
        guard oldStatus.activations == 0 else {
            fatalError("!!! BUG !!! Status was \(oldStatus), expected 0.")
        }
        self.systemMessages.enqueue(.start)
    }

    @inlinable
    func schedule() {
        guard let shell = self.shell else {
            traceLog_Mailbox(self.address.path, "has already released the actor cell, ignoring scheduling attempt")
            return
        }
        shell._dispatcher.execute(self.run)
    }

    @inlinable
    func sendSystemMessage(_ systemMessage: _SystemMessage, file: String, line: UInt) {
        func sendAndDropAsDeadLetter() {
            // TODO: should deadLetters be special, since watching it is nonsense?
            self.deadLetters.tell(DeadLetter(systemMessage, recipient: self.address, sentAtFile: file, sentAtLine: line), file: file, line: line)
        }

        switch self.enqueueSystemMessage(systemMessage) {
        case .needsScheduling:
            traceLog_Mailbox(self.address.path, "Enqueued system message \(systemMessage), scheduling for execution")
            guard let shell = self.shell else {
                self.deadLetters.tell(DeadLetter(systemMessage, recipient: nil))
                traceLog_Mailbox(self.address.path, "has already released the actor cell, dropping system message \(systemMessage)")
                break
            }
            shell._dispatcher.execute(self.run)

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

    private func enqueueSystemMessage(_ systemMessage: _SystemMessage) -> EnqueueDirective {
        // The ordering of enqueue/activate calls is tremendously important here and MUST NOT be inversed.
        //
        // Unlike user messages, where the message count is stored, here we first enqueue and then activate.
        // This MAY result in an enqueue into a terminating or even closed mailbox.
        // This is only during the period of time between terminating->closed->cell-released however.
        //
        // We can enqueue "too much", and elements remain in the queue until we get deallocated.
        //
        // Note: The problem with `activate then enqueue` is that it allows for the following race condition to happen:
        //   A0: is processing messages; before ending a run we see if any more system messages are to be processed
        //   (A1 attempts sending message to A0)
        //   A1: send_system_message, try_activate succeeds
        //   A0: notices, that there's more system messages to run, so attempts to do so
        //   !!: A1 did not yet enqueue the system message
        //   A0: falls of a cliff, does not process the system message
        //   A1: enqueues the system message and
        //
        // TODO: If we used some bits for system message queue count, we could avoid this issue... Consider this at some point perhaps
        //
        // TODO: Alternatively locking on system message things could be a solution... Though heavy one.

        // TODO: This is not a full solution, however lessens the amount of instances in which we may enqueue to a terminating actor
        // This additional atomic read on every system send helps to avoid enqueueing indefinitely to terminating/closed mailbox
        // however is not strong enough guarantee to disallow that no such enqueue ever happens (status could be changed just
        // after we check it and decide to enqueue, though then the try_activate will yield the right status so we will dead letter
        // the message in any case -- although having enqueued the message already. Where it MAY remain until cell is deallocated,
        // if the enqueue happened after terminated is set, but tombstone is enqueued.
        self.systemMessages.enqueue(systemMessage)

        let oldStatus = self.setHasSystemMessages()

        if oldStatus.isTerminating {
            return .mailboxTerminating
        } else if oldStatus.isClosed {
            return .mailboxClosed
        } else if oldStatus.activations == 0 {
            return .needsScheduling
        } else if !oldStatus.hasSystemMessages, !oldStatus.isProcessingSystemMessages, oldStatus.isSuspended {
            return .needsScheduling
        } else {
            return .alreadyScheduled
        }
    }

    /// DANGER: Must ONLY be invoked synchronously from an aborted or closed run state.
    /// No other messages may be enqueued concurrently; in other words the mailbox MUST be in terminating stare to enqueue the tombstone.
    private func sendSystemTombstone() {
        traceLog_Mailbox(self.address.path, "SEND SYSTEM TOMBSTONE")

        guard let shell = self.shell else {
            traceLog_Mailbox(self.address.path, "has already released the actor cell, dropping system tombstone")
            return
        }

        let oldStatus = self.setHasSystemMessages()

        guard oldStatus.isTerminating else {
            fatalError("!!! BUG !!! Tombstone was attempted to be enqueued at not terminating actor \(self.address). THIS IS A BUG.")
        }

        self.systemMessages.enqueue(.tombstone)

        // Good. After all this function must only be called exactly once, exactly during the run causing the termination.
        shell._dispatcher.execute(self.run)
    }

    func run() {
        guard let shell = self.shell else {
            traceLog_Mailbox(self.address.path, "has already stopped, ignoring run")
            return
        }

        // Prepare failure context pointers:
        // In case processing of a message fails, this pointer will point to the message that caused the failure
        let failedMessagePtr = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
        failedMessagePtr.initialize(to: nil)
        defer { failedMessagePtr.deallocate() }

        let mailboxRunResult = self.mailboxRun(shell)

        // TODO: not in love that we have to do logic like this here... with a plain book to continue running or not it is easier
        // but we have to signal the .tombstone AFTER the mailbox has set status to terminating, so we have to do it here... and can't do inside interpretMessage
        // we could offer even more callbacks to C but that is also not quite nice...

        switch mailboxRunResult {
        case .reschedule:
            // pending messages, and we are the one who should should reschedule
            shell._dispatcher.execute(self.run)

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
            traceLog_Mailbox(self.address.path, "finishTerminating has completed, and the final run has completed. We are CLOSED.")
        }
    }

    private func mailboxRun(_ shell: ActorShell<Message>) -> MailboxRunResult {
        let status = self.setProcessingSystemMessages()
        shell.metrics[gauge: .mailboxCount]?.record(status.messageCount)

        guard !status.isClosed else {
            shell.log.warning("!!! BUG !!! Run was scheduled on already closed mailbox.")
            return .closed
        }

        var processedActivations = status.hasSystemMessages ? MailboxBitMasks.processingSystemMessages : 0
        // User message count is shifted by two, so we need to shift this as well to make the check easier
        // we also need to add the `processedActivations` in case we are processing system messages, because
        // that is encoded in this value as well.
        let runLength = (min(status.messageCount, UInt64(self.maxRunLength)) << 2) + processedActivations

        // Initial state has to be `.continueRunning`, so messages are being processed. Anything else would
        // mean we are not supposed to run.
        // TODO: rename ActorRunResult -- the mailbox run is "the run", this is more like the actors per reduction directive... need to not overload the name "run"
        var runResult = ActorRunResult.continueRunning // TODO: hijack the run_length, and reformulate it as "fuel", and set it to zero when we need to stop
        if status.isSuspended {
            runResult = .shouldSuspend
        }

        // system messages run -----------------------------------------------------------------------------------------

        if status.hasSystemMessages {
            while runResult != .shouldStop, runResult != .closed, let message = self.systemMessages.dequeue() {
                do {
                    try runResult = shell.interpretSystemMessage(message: message)
                } catch {
                    shell.fail(error)
                    runResult = .shouldStop
                }
            }

            // was our run interrupted by a system message initiating a stop?
            if runResult == .shouldStop || runResult == .closed {
                if !status.isTerminating {
                    // avoid unnecessarily setting the terminating bit again
                    self.setTerminating()
                }

                // Since we are terminating, and bailed out from a system run, there may be
                // pending system messages in the queue still; we want to finish this run till they are drained.
                //
                // Never run user messages before draining system messages, system messages must be processed with priority,
                // since they include setting up watch/unwatch as well as the tombstone which should be the last thing we process.
                while let message = self.systemMessages.dequeue() {
                    traceLog_Mailbox(shell.path, "CLOSED, yet pending system messages still made it in... draining...")
                    // drain all messages to dead letters
                    // this is very important since dead letters will handle any posthumous watches for us
                    self.deadLetters.tell(DeadLetter(message, recipient: self.address))
                }
            }
        }

        // end of system messages run ----------------------------------------------------------------------------------

        // suspension logic --------------------------------------------------------------------------------------------
        if status.isSuspended && runResult != .shouldSuspend {
            self.resetStatusSuspended()
        } else if !status.isSuspended && runResult == .shouldSuspend {
            self.setStatusSuspended()
            traceLog_Mailbox(shell.path, "MARKED SUSPENDED")
        }

        // run user messages -------------------------------------------------------------------------------------------

        if runResult == .continueRunning {
            while processedActivations < runLength, runResult == .continueRunning, let message = self.userMessages.dequeue() {
                do {
                    processedActivations += MailboxBitMasks.singleUserMessage
                    switch message.payload {
                    case .message(let _message):
                        traceLog_Mailbox(self.address.path, "INVOKE MSG: \(message)")
                        guard let message = _message as? Message else {
                            fatalError("Received message [\(_message)]:\(type(of: _message)), expected \(Message.self)")
                        }

                        runResult = try shell.interpretMessage(message: message)
                    case .closure(let carry):
                        traceLog_Mailbox(self.address.path, "INVOKE CLOSURE: \(String(describing: carry.function)) defined at \(carry.file):\(carry.line)")
                        runResult = try shell.interpretClosure(carry)
                    case .adaptedMessage(let carry):
                        traceLog_Mailbox(self.address.path, "INVOKE ADAPTED MESSAGE: \(carry.message)")
                        runResult = try shell.interpretAdaptedMessage(carry)
                    case .subMessage(let carry):
                        traceLog_Mailbox(self.address.path, "INVOKE SUBMSG: \(carry.message) with identifier \(carry.identifier)")
                        runResult = try shell.interpretSubMessage(carry)
                    }
                } catch {
                    shell.fail(error)
                    runResult = .shouldStop
                }

                if runResult == .shouldStop, !status.isTerminating {
                    self.setTerminating()
                    traceLog_Mailbox(shell.path, "MARKED TERMINATING")
                    break
                } else if runResult == .shouldSuspend {
                    self.setStatusSuspended()
                    traceLog_Mailbox(shell.path, "MARKED SUSPENDED")
                    break
                } else if processedActivations >= runLength {
                    break
                }
            }
        } else if runResult == .shouldSuspend {
            traceLog_Mailbox(shell.path, "MAILBOX SUSPENDED, SKIPPING USER MESSAGE PROCESSING")
        } else { /* we are terminating and need to drain messages */
            while let message = self.userMessages.dequeue() {
                self.deadLetters.tell(DeadLetter(message, recipient: self.address))
                processedActivations += MailboxBitMasks.singleUserMessage
            }
        }

        // end of run user messages ------------------------------------------------------------------------------------

        let oldStatus = self.decrementActivations(by: processedActivations)
        let oldActivations = oldStatus.activations

        traceLog_Mailbox(shell.path, "Run complete...")

        // issue directives to mailbox ---------------------------------------------------------------------------------
        if runResult == .shouldStop {
            // MUST be the first check, as we may want to stop immediately (e.g. reacting to system .start a with .stop),
            // as other conditions may hold, yet we really are ready to terminate immediately.
            traceLog_Mailbox(shell.path, "Terminating...")
            let processedActivationsCount = Status(processedActivations).messageCount
            if status.messageCount >= processedActivationsCount {
                shell.metrics[gauge: .mailboxCount]?.record(status.messageCount - processedActivationsCount)
            } else {
                // TODO: Figure out why this can ever happen
                shell.log.warning(
                    "Mailbox closed with more processed activations (\(processedActivationsCount)) than messages (\(status.messageCount))",
                    metadata: [
                        "status": "\(status)",
                        "processedActivations": "\(processedActivations)",
                    ]
                )
            }
            return .close
        } else if runResult == .closed {
            traceLog_Mailbox(shell.path, "Terminating, completely closed now...")
            shell.metrics[gauge: .mailboxCount]?.record(0)
            return .closed
        } else if (oldActivations > processedActivations && !oldStatus.isSuspended) || oldStatus.hasSystemMessages {
            traceLog_Mailbox(shell.path, "Rescheduling... \(oldActivations) :: \(processedActivations)")
            // if we received new system messages during user message processing, or we could not process
            // all user messages in this run, because we had more messages queued up than the maximum run
            // length, return `Reschedule` to signal the queue should be re-scheduled
            //
            // Metrics: don't update the metric count here, it would have been updated by ongoing enqueues,
            // and we'll update it as well when the run begins.
            return .reschedule
        } else {
            traceLog_Mailbox(shell.path, "Run complete, shouldReschedule:false")
            shell.metrics[gauge: .mailboxCount]?.record(0)
            return .done
        }
    }

    private enum MailboxRunResult {
        case close
        case closed
        case done
        case reschedule
    }

    internal enum EnqueueDirective {
        case needsScheduling
        case alreadyScheduled
        case mailboxTerminating
        case mailboxClosed
        case mailboxFull
    }

    internal struct Status {
        // Implementation notes:
        // State should be operated on bitwise; where the specific bits signify states like the following:
        //      0 - has system messages
        //      1 - currently processing system messages
        //   2-33 - user message count
        //     34 - message count overflow (important because we increment the counter first and then check if the mailbox was already full)
        //  35-60 - reserved
        //     61 - mailbox is suspended and will not process any user messages
        //     62 - terminating (or closed)
        //     63 - closed, terminated (for sure)
        // Activation count is special in the sense that we use it as follows, it's value being:
        // 0 - inactive, not scheduled and no messages to process
        // 1 - active without(!) normal messages, only system messages are to be processed
        // n - there are (n >> 1) messages to process + system messages if LSB is set
        //
        // Note that this implementation allows, using one load, to know:
        // - if the actor is running right now (so the mailbox size will be decremented shortly),
        // - current mailbox size (nr. of enqueued messages, which can be used for scheduling and/or metrics)
        // - if we need to schedule it or not since it was scheduled already etc.
        private let _status: UInt64

        init(_ status: UInt64) {
            self._status = status
        }

        var messageCount: UInt64 {
            self.activations >> 2
        }

        var hasSystemMessages: Bool {
            (self._status & MailboxBitMasks.hasSystemMessages) != 0
        }

        var isProcessingSystemMessages: Bool {
            (self._status & MailboxBitMasks.processingSystemMessages) != 0
        }

        var activations: UInt64 {
            (self._status & MailboxBitMasks.activations)
        }

        var isSuspended: Bool {
            (self._status & MailboxBitMasks.suspended) != 0
        }

        var isTerminating: Bool {
            (self._status & MailboxBitMasks.terminating) != 0
        }

        var isClosed: Bool {
            (self._status & MailboxBitMasks.closed) != 0
        }
    }

    func incrementMessageCount() -> Status {
        Status(self._status.add(MailboxBitMasks.singleUserMessage))
    }

    func decrementMessageCount() -> Status {
        Status(self._status.sub(MailboxBitMasks.singleUserMessage))
    }

    func decrementActivations(by count: UInt64) -> Status {
        Status(self._status.sub(count))
    }

    var status: Status {
        Status(self._status.load())
    }

    func setHasSystemMessages() -> Status {
        Status(self._status.or(MailboxBitMasks.hasSystemMessages))
    }

    // Checks if the 'has system messages' bit is set and if it is, unsets it and
    // sets the 'is processing system messages' bit in one atomic operation. This is
    // necessary to not race between unsetting the bit at the end of a run while
    // another thread is enqueueing a new system message.
    func setProcessingSystemMessages() -> Status {
        let status = self.status
        if status.hasSystemMessages {
            return Status(self._status.xor(MailboxBitMasks.becomeSysMsgProcessingXor, order: .acq_rel))
        }

        return status
    }

    @discardableResult
    func setTerminating() -> Status {
        Status(self._status.or(MailboxBitMasks.terminating))
    }

    @discardableResult
    func setFailed() -> Status {
        self.setTerminating()
    }

    @discardableResult
    func setClosed() -> Status {
        Status(self._status.or(MailboxBitMasks.closed))
    }

    @discardableResult
    func setStatusSuspended() -> Status {
        Status(self._status.or(MailboxBitMasks.suspended))
    }

    @discardableResult
    func resetStatusSuspended() -> Status {
        Status(self._status.and(MailboxBitMasks.unsuspend))
    }
}

// This used to be typed according to the actor message type, but we found
// that it added some runtime overhead when retrieving the messages from the
// queue, because additional metatype information was retrieved, therefore
// we removed it
internal enum WrappedMessage: NonTransportableActorMessage {
    case message(Any)
    case closure(ActorClosureCarry)
    case adaptedMessage(AdaptedMessageCarry)
    case subMessage(SubMessageCarry)
}

/// Envelopes are used to carry messages with metadata, and are what is enqueued into actor mailboxes.
internal struct Payload {
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
internal struct ActorClosureCarry: CustomStringConvertible {
    @usableFromInline
    internal class _Storage {
        @usableFromInline
        let function: () throws -> Void

        @usableFromInline
        let file: String
        @usableFromInline
        let line: UInt

        @usableFromInline
        init(function: @escaping () throws -> Void, file: String, line: UInt) {
            self.function = function
            self.file = file
            self.line = line
        }
    }

    let _storage: _Storage

    @usableFromInline
    init(function: @escaping () throws -> Void, file: String, line: UInt) {
        self._storage = .init(function: function, file: file, line: line)
    }

    @usableFromInline
    var function: () throws -> Void {
        self._storage.function
    }

    @usableFromInline
    var file: String {
        self._storage.file
    }

    @usableFromInline
    var line: UInt {
        self._storage.line
    }

    @usableFromInline
    var description: String {
        "ActorClosureCarry(<closure> defined at \(self._storage.file):\(self._storage.line))"
    }
}

@usableFromInline
internal struct SubMessageCarry: CustomStringConvertible {
    @usableFromInline
    class _Storage {
        @usableFromInline
        let identifier: AnySubReceiveId
        @usableFromInline
        let message: Any
        @usableFromInline
        let subReceiveAddress: ActorAddress

        @usableFromInline
        init(identifier: AnySubReceiveId, message: Any, subReceiveAddress: ActorAddress) {
            self.identifier = identifier
            self.message = message
            self.subReceiveAddress = subReceiveAddress
        }
    }

    let _storage: _Storage

    @usableFromInline
    init(identifier: AnySubReceiveId, message: Any, subReceiveAddress: ActorAddress) {
        self._storage = .init(identifier: identifier, message: message, subReceiveAddress: subReceiveAddress)
    }

    @usableFromInline
    var identifier: AnySubReceiveId {
        self._storage.identifier
    }

    @usableFromInline
    var message: Any {
        self._storage.message
    }

    @usableFromInline
    var subReceiveAddress: ActorAddress {
        self._storage.subReceiveAddress
    }

    @usableFromInline
    var description: String {
        "SubMessageCarry(\(self.message), subReceive identifier: \(self.identifier.underlying), address: \(self.subReceiveAddress))"
    }
}

@usableFromInline
internal struct AdaptedMessageCarry {
    @usableFromInline
    let message: Any
}

@usableFromInline
internal enum ActorRunResult {
    case continueRunning
    case shouldSuspend
    case shouldStop
    case closed
}

/// :nodoc: INTERNAL API
public struct MessageProcessingFailure: Error {
    let messageDescription: String
    let backtrace: [String] // TODO: Could be worth it to carry it as struct rather than the raw string?
}

extension MessageProcessingFailure: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Actor faulted while processing message '\(self.messageDescription)', with backtrace"
    }

    public var debugDescription: String {
        let backtraceStr = self.backtrace.joined(separator: "\n")
        return "Actor faulted while processing message '\(self.messageDescription)':\n\(backtraceStr)"
    }
}
