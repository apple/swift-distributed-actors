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

import CQueue
import NIOConcurrencyHelpers
import Foundation // TODO remove

/// INTERNAL API
public struct Envelope {
  let payload: Any // TODO we may want to type the Envelope properly to <M>

  // Note that we can pass around senders however we can not automatically get the type of them right.
  // We may want to carry around the sender path for debugging purposes though "[pathA] crashed because message [Y] from [pathZ]"
  // TODO explain this more
  #if SACTANA_DEBUG
  let senderPath: String
  #endif

  init(_ payload: Any /* context metadata */) {
    self.payload = payload
  }

  // Implementation notes:
  // Envelopes are also used to enable tracing, both within an local actor system as well as across systems
  // the beauty here is that we basically have the "right place" to put the trace metadata - the envelope
  // and don't need to do any magic around it
}

/// A Mailbox represents an (typically) FIFO queue of messages that an actor has to handle.
/// Multiple actors may concurrently attempt to enqueue messages while the receiving actor is processing them/
///
/// Mailboxes should be implemented as non blocking as possible, utilising lock-free or wait-free programming whenever possible.
///
/// To "run" a mailbox means to process a given amount of
public protocol Mailbox { // TODO possibly remove the protocol for perf reasons?

  func sendMessage(envelope: Envelope) -> ()
  //func dequeueMessage() -> Envelope?

  func sendSystemMessage(_ message: SystemMessage) -> ()
  //func dequeueSystemMessage() -> SystemMessage?

  // MARK: INTERNAL API
  // TODO hide those from outside users?

  // func setActor(cell: AnyActorCell)

  /// A mailbox run consists of processing pending system and user messages
  func run()
}

struct Context {
  let fn: (UnsafeMutableRawPointer) -> Void

  init(_ fn: @escaping (UnsafeMutableRawPointer) -> Void) {
    self.fn = fn
  }

  func exec(with ptr: UnsafeMutableRawPointer) -> Void {
    fn(ptr)
  }
}

final class NativeMailbox<Message> : Mailbox {
  private var mailbox: UnsafeMutablePointer<CMailbox>
  private var cell: ActorCell<Message>
  private var context: Context
  private var system_context: Context
  private let __run: RunMessageCallback

  init(cell: ActorCell<Message>, capacity: Int) {
    self.mailbox = cmailbox_create(Int64(capacity));
    self.cell = cell
    self.context = Context({ ptr in
      let envelopePtr = ptr.assumingMemoryBound(to: Envelope.self)
      let envelope = envelopePtr.move()
      let msg = envelope.payload as! Message
      cell.interpretMessage(message: msg)
    })

    self.system_context = Context({ ptr in
      let envelopePtr = ptr.assumingMemoryBound(to: SystemMessage.self)
      let msg = envelopePtr.move()
      cell.interpretSystemMessage(message: msg)
    })

    __run = { (ctxPtr, msg) in
      defer { msg?.deallocate() }
      let ctx = ctxPtr?.assumingMemoryBound(to: Context.self)
      ctx?.pointee.exec(with: msg!)
    }
  }

  deinit {
    cmailbox_destroy(mailbox)
  }

  func sendMessage(envelope: Envelope) -> Void {
    let ptr = UnsafeMutablePointer<Envelope>.allocate(capacity: 1)
    ptr.initialize(to: envelope)
    if (cmailbox_send_message(mailbox, ptr)) {
      cell.dispatcher.execute(self.run)
    }
  }

  func sendSystemMessage(_ systemMessage: SystemMessage) -> Void {
    let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
    ptr.initialize(to: systemMessage)
    if (cmailbox_send_system_message(mailbox, ptr)) {
      cell.dispatcher.execute(self.run)
    }
  }

  func run() -> Void {
    let requeue = cmailbox_run(mailbox, &context, &system_context, __run)

    if (requeue) {
      cell.dispatcher.execute(self.run)
    }
  }
}

// Implementation Note:
// It may seem tempting to allow total extensability of mailboxes by end users; in reality this has always been a bad idea in Akka
// since people attempt to solve their protocol and higher level issues by "we'll make a magical mailbox for it"
// Mailboxes must be Simple.
final class DefaultMailbox<Message> : Mailbox {

  private var log: ActorLogger {
    return ActorLogger(LoggingContext(name: cell.name, dispatcher: { () in "T#\(hackyThreadName())" }))
  }

  private let _status = Atomic<Int>(value: 0)
  private func loadStatus() -> MailboxStatus { return MailboxStatus(underlying: _status.load()) }

  private let mailLock = Lock() // I'm sorry // TODO remove once we get acquire/release semantics access

  // updates to these MUST be atomic
  private var cell: ActorCell<Message>

  private var queue = MPSCLinkedQueue<Envelope>() // TODO configurable (bounded / unbounded etc); default to be array backed
  private var systemQueue = MPSCLinkedQueue<SystemMessage>() // TODO specialize the queue, make it light and linked; the queue for normal messages should be optimized, likely array backed

  // since we want to allow implementing bounded queues
  private let capacity: Int

  init(cell: ActorCell<Message>, capacity: Int ) {
    self.cell = cell
    self.capacity = capacity
  }

  func sendMessage(envelope: Envelope) -> Void {
    // TODO remove lock; mailbox structure is ready to be wait-free
    mailLock.lock()
    defer { mailLock.unlock() }

    let old = incrementStatusActivations() // also takes care of setting it as active
    let oldActivations = old.activations

    log.info("INSIDE sendMessage: [\(envelope.payload)]:\(type(of: envelope.payload)), old status: \(old)")

    // number of messages is `activations - 1`, so the following is correct:
    if oldActivations > capacity {
      // meaning: mailbox is over capacity
      decrementStatusActivations() // rollback the update to `old` state, since we're dropping the message

      // Implementation notes:
      // "Dropping" is specific wording used to signal that a message is dropped due to mailbox etc over-capacity
      // It is different than "dead letter" which means a message arrived at terminated actor.
      // The two seem similar, but point at different programming errors:
      //   - dropping is flow control issues
      //   - dead letters may be lifecycle issues or races
      log.info("INSIDE sendMessage: DROPPED: Mailbox overflow (capacity: \(capacity), dropping: \(type(of: envelope.payload)), in \(self.cell.myself)") // TODO: log this properly
    } else if old.isTerminating {
      // meaning: we enqueued a message to an actor which is in the process of terminating, but not terminated yet
      decrementStatusActivations()

      log.info("INSIDE sendMessage: DEAD LETTER: \(self.cell.myself) is terminating, thus message \(type(of: envelope.payload)) is a dead letter")
    } else {
      log.info("INSIDE sendMessage: enqueue: \(envelope.payload)")
      // the actor definitely will be scheduled, and we are allowed to enqueue the message to the mailbox
      queue.enqueue(envelope)

      // we check if we happen to be the first activation (among potentially many concurrently happening ones)
      if oldActivations == 0 {
        // we are the first activation, and thus the first increment only updated our status to activated,
        // however none of the other threads are responsible for triggering the scheduling – we are, so let's do it:
        //
        // Implementation note:
        //   this avoids having to check in other places if we should schedule, it all is in the single counter
        //   notice also that this also handles system messages (i.e. no system message was present, thus we perform the schedule)
        let status = incrementStatusActivations() // status is at-least "active, 1 user message" (could be more though)

        cell.dispatcher.execute(self)
//        let activated = scheduleForExecution(status: status, hasMessageHint: true, hasSystemMessageHint: false)
       // log.info("sendMessage: ACTIVATED!")
      }
    }
  }

  func sendSystemMessage(_ message: SystemMessage) {
    // TODO remove lock; mailbox structure is ready to be wait-free
    mailLock.lock()
    defer { mailLock.unlock() }

    let old = incrementStatusActivations()
    log.info("INSIDE sendSystemMessage: \(message) @ old: \(old.debugDescription)")
    log.info("INSIDE sendSystemMessage: \(message) @ current: \(self.loadStatus().debugDescription)")

    if old.isTerminated {
      // terminated actors MUST NOT handle any more messages
      log.info("Self is terminated, NOT enqueueing system message \(message). Terminating.")
      decrementStatusActivations() // revert our update
    } else {
      // which means we are allowed to enqueue
      self.systemQueue.enqueue(message)

      // we need to decide though if we need to schedule execution,
      // or if we already were scheduled (by some other send triggering it:
      if old.activations == 0 {
        // we are responsible of activating the actor
        log.info("Previously zero activations; enqueued signal [\(message)]: ACTIVATING")
        cell.dispatcher.execute(self)
        // scheduleForExecution(status: loadStatus(), hasMessageHint: false, hasSystemMessageHint: true) // hint that we are certain that we should execute
      } else {
        // already activated, so we should not meddle with this, and undo our update
        // In essence what we did here is race with some other thread for who should schedule the actor, and... we lost :-)
        log.info("Enqueued signal [\(message)]: already active (scheduled)")
        decrementStatusActivations() // roll back our attempt to schedule, someone else already did
      }
    }
  }

  func dequeueMessage() -> Envelope? {
    return queue.dequeue()
  }

  func dequeueSystemMessage() -> SystemMessage? {
    return systemQueue.dequeue()
  }

  internal func setActor(cell: ActorCell<Message>) {
    self.cell = cell
  }

  // MARK: Mailbox status management


  /// Increments underlying status counter by 1
  /// - Returns: a snapshot of the previous mailbox status.
  private func incrementStatusActivations(file: StaticString = #file, line: UInt = #line) -> MailboxStatus {
    let old: Int = self._status.add(1)
    let status = MailboxStatus(underlying: old)
    log.info("INCREMENT STATUS [FROM:\(file):\(line)], OLD: \(status)")
    log.info("INCREMENT STATUS [FROM:\(file):\(line)], NOW: \(loadStatus())")
    return status
  }
  /// Increments underlying status by -1
  /// Used to "revert" an increment that was made too eagerly while entering a send*
  @discardableResult
  private func decrementStatusActivations(by n: Int = 1, file: StaticString = #file, line: UInt = #line) -> MailboxStatus {
    let old = self._status.add(-n)

    // #if SACT_DEBUG
    let status = loadStatus()
    assertWithDetails(status.messageCountNonSystem >= 0, self, "Decremented below 0 activations, this must never happen and is a bug!")
    // #endif

    log.info("DECREMENT [FROM:\(file):\(line)] STATUS BY \(n), OLD: \(MailboxStatus(underlying: old))")
    log.info("DECREMENT [FROM:\(file):\(line)] STATUS BY \(n), NOW: \(loadStatus())")

    return status
  }

  // MARK: Running the mailbox

  // FIXME: In order to be able to remove the lock (we really really need to remove it) we'll need acquire/release semantics on the mailbox status field
  func run() { // TODO pass in "RunAllowance" or "RunDirectives" which the mailbox should respect (e.g. capping max run length)
    mailLock.withLockVoid {
      let status: MailboxStatus = self.loadStatus()
      guard status.isActive else { return } // dead actors don't run
      log.info("RUN: Entering run: Status: \(status.debugDescription)")

      // TODO failure handling in case those crash


      // TODO run only if has system messages?
      let runProgress = self.runSystemMessages()
      log.info("RUN: running... Status after system messages: \(runProgress), old: \(status)")

      var processed: Int = 0
      if runProgress.continue {
        processed += self.runUserMessages(activations: status.messageCountNonSystem, runLimit: 100) // FIXME take from run directive from cell/dispatcher which passes in here
        log.info("RUN: running... Status after user messages: processed: \(processed), old: \(status)")
      }

      // We always clear the "activation bit", regardless of how many messages we will end up processing.
      // In other words, by the end of the run we need to decrement the activations by N, where N is the
      // number of messages (both system, and user) which we processed... however, since observing `activations == 0`
      // is the triggering condition for a thread to decide to perform an actor wake-up, we also always need to decrement
      // by the "activation token", which as we know (see MailboxStatus) is the lowest bit of the status (thus, exactly 1).
      processed += 1 // clear generic activation token

      let prevStatus = decrementStatusActivations(by: processed) // this would be our RELEASE write

      // ---- finally ----
      // finally we need to figure out if we have some actions to do before we let go:
      // let now = MailboxStatus(underlying: prevStatus.value - processed) // was in akka
      let now = MailboxStatus(underlying: prevStatus.value - processed)
      log.info("NOW ::::: PREV:\(prevStatus) - [processed:\(processed)] >>>> NOW:\(now)")

      if now.isTerminated {
        // we're done here, forever
        log.info("RUN: Exiting run: Terminated. Status : \(now)")
      } else if now.activations > 0 {
        // we were too eager in deactivating (the processed += 1), and need to revert this,
        // as there actually still are messages pending to be processed, and since we were
        // "activated" while running, other threads that issued send(System)Message's would not cause an activation.
        // In fact, it is only correct that they did not issue activations, since otherwise this actor may be scheduled to run
        // _while_ this current run was still executing - which would break the actor guarantees (!).
        //
        // In other words, if messages were sent to this actor while it was running, others would see the activation flag,
        // and not cause an activation (they would not schedule this actor, since it could cause concurrent execution of it),
        // yet they still did perform the +1 updates for their writes; This means that if we decrement status by
        // the (run-length + 1(activation token)), yet we still see activations, it means that others tried to send us messages,
        // but did not schedule -- they relied on us, the run()-ing thread to pick up the scheduling.
        let _ = incrementStatusActivations() // revert the removal of the activation token
        // ... and reschedule
        cell.dispatcher.execute(self)
      } else if systemQueue.nonEmpty() {
        // A system message enqueue has happened during our run, and it MAY have happened
        // before we wrote our deactivation (decrement status by processed) above, and thus
        // not scheduled. This is because the other thread would have seen a non-0 status, and left it up to us to do the wake-up.
        //
        // Compensating action:
        // We need to race against the thread which performed system enqueue, to see who should schedule the actor -- there can be only one!
        // If we win (and observe a `0`, we reschedule), if we lose, it means the other thread won and has scheduled this actor.
        let again = incrementStatusActivations()
        if again.activations == 0 {
          // we won the race, and have to activate this actor in order to not leave the system message "hanging in limbo"
          cell.dispatcher.execute(self)
        } else {
          // we lost the race, so now the status has both our +1 activation (which will not happen),
          // and the winning threads +1 activation token.
          decrementStatusActivations() // retract our activation token, we lost the race
        }
      }

      // --- debugging ---
//      // iff the status after run indicates we still have things to process, schedule another run:
//      let loadedAfter: MailboxStatus = self.loadStatus()
      log.info("RUN: Exiting run: Status on run start: \(status.debugDescription)")
      log.info("RUN: Exiting run:      Status on Load: \(now.debugDescription)")
    }
  }

  /// Run through and interpret all system messages.
  /// In case a final signal such as Terminated (TODO check wording)
  /// is processed, the remaining messages are drained to deadLetters.
  ///
  /// Unlike user messages, we do not track the specific number of system messages we processed;
  /// This is because no run limit applies to system messages, and we always run all of them.
  ///
  /// - Returns: `true` if the mailbox should continue processing user messages (no terminal system message was encountered)
  // Implementation notes:
  // RUN ONLY WHILE PROTECTED BY `runLock`
  @inline(__always)
  private func runSystemMessages() -> MailboxRunProgress {
    var continueProcessingUserMessages = true

    while let message = dequeueSystemMessage() {
      log.info("RUN: interpret system message: \(message)")
      cell.interpretSystemMessage(message: message) // TODO optimize for aborting a run if we hit a terminate final message
      // TODO what if it was Terminated -> drain all to dead letters
      // if terminated { continueProcessingUserMessages = false }
    }

    return MailboxRunProgress(continue: continueProcessingUserMessages)
  }
  // TODO optimize the system message run, inline it directly?
  private struct MailboxRunProgress {
    /// Continue processing user messages (i.e. the system message run has not encountered a Terminate signal)
    let `continue`: Bool
//    let processed: Int
  }

  // RUN ONLY WHILE PROTECTED BY `runLock`
  private func runUserMessages(activations: Int, runLimit: Int) -> Int {
    guard activations > 0 else {
     // log.info("RUN: No user messages to run...")
      return 0 
    } // no reason to run when no activations

    var processed = 0

    // FIXME this has to take into account the runLength
    mailboxRun: while let e = dequeueMessage() { // FIXME look at run len

      // mutates the cell
      cell.interpretMessage(message: e.payload as! Message) // FIXME make the envelope typed as well

      processed += 1
      if processed == runLimit { break mailboxRun }
    }

    return processed
  }
/*
  // RUN ONLY WHILE PROTECTED BY `runLock`
  @inline(__always)
  @discardableResult
  private func scheduleForExecution(status: MailboxStatus, hasMessageHint: Bool, hasSystemMessageHint: Bool) -> Bool {
    // if can be scheduled for execution
    return cell.dispatcher.registerForExecution(self, status: status, hasMessageHint: hasMessageHint, hasSystemMessageHint: hasSystemMessageHint)
  }
 */
}

extension DefaultMailbox: CustomStringConvertible {
  public var description: String {
    return "\(type(of: self))(\(self.cell.path))"
  }
}


// MARK: MailboxState

// Implementation notes:
// State should be operated on bitwise; where the specific bits signify states like the following:
// 0 - 29 - activation count
//     30 - terminating (or terminated)
//     31 - terminated (for sure)
// Activation count is special in the sense that we use it as follows, it's value being:
// 0 - inactive, not scheduled and no messages to process
// 1 - active without(!) normal messages, only system messages are to be processed
// n - there are (n-1) messages to process
//
// Note that this implementation allows, using one load, to know: if the actor is running right now (so
// the mailbox size will be decremented shortly), if we need to schedule it or not since it was scheduled already etc.
//protocol MailboxStatusSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
//  var isTerminating: Bool { get }
//  var isTerminated: Bool { get }
//  var isRunnable: Bool { get }
//  var activations: Int { get }
//
//  // MARK: Internal, in order to share impl across snapshot/real
//  func _load() -> Int
//}


/// Extends `MailboxStatusSnapshot` with the ability to update the states
///
/// WARNING: This struct INTERNALLY MUTATES its `_status` via atomic operations, yet we keep it a struct to get the low overhead of it
// TODO how terrible is it that I actually do mutate this internally via the Atomic? (IMHO ok, since i avoid copying things and uphold the atomicity, and dont want this to be a class... but good to ask I suppose)
//
// TODO In future want to expose this to dispatcher and let IT decide // this was never done but we wanted to in typed
public struct MailboxStatus {

  /// Represents the masks used to pull out status flags and counters contained in the _status of a mailbox.
  // Implementation notes:
  // We implement the mailbox state in such sneaky way in order to be able to at the same time modify scheduled/idle
  // and message count values; which are used to estimate the throughput to apply on this mailbox run. This is loosely based
  // on the dropped Typed Akka ActorSystem implementation by Roland Kuhn, from 2016 https://github.com/akka/akka/pull/21128/files#diff-92d9e38d1b6b284e38230047feea5fdcR36
  fileprivate enum Masks: Int {
    //@formatter:off
    // case activatedOnlySystemMessages = 0b00000000_00000000_00000000_00000010 // 1 bit
    case activations                 = 0b00111111_11111111_11111111_11111111 // 0 – 29 bits (28 bits total), value of N means N-1 activations
    case terminating                 = 0b01000000_00000000_00000000_00000000 // 30 bit
    case terminated                  = 0b10000000_00000000_00000000_00000000 // 31 bit, also `sign` bit, which we utilize
  }
  static let singleActivation   = 0b00000000_00000000_00000000_00000100 // 2 bit, means "1 activation"
  //@formatter:on

  let value: Int

  public init(underlying value: Int) {
    self.value = value
  }

  /// - Returns: true if mailbox is able to run (is not terminating or terminated), regardless of message count
  var isActive: Bool {
    return self.value & Masks.activations.rawValue != 0
  }
  /// - Returns: true if mailbox has any messages pending (either system or normal messages)
  var hasAnyMessages: Bool {
    return self.value & Masks.activations.rawValue > 0
  }
  /// Activations are used to coordinate scheduling of actors, and at the same time serve as user message counter.
  /// Activation count is optimized for how and when the mailbox should execute, and should be interpreted as:
  ///   - `0` means inactive
  ///   - `1` means active without normal messages (i.e. only system messages)
  ///   - `N` means active with N-1 normal messages (plus possibly system messages)
  ///
  /// This also implies that a "first" activation from inactive status by an user message shall increment to `2`,
  /// in two steps, meaning that only a single concurrent thread will actually perform the scheduling for execution
  /// (i.e. the thread who has observed the 0 value, when performing the LOCK XADD on the status field).
  var activations: Int {
    return self.value & Masks.activations.rawValue
  }
  /// Count of user messages contained in mailbox (plus, potentially any system messages)
  /// Could be 0 but still be ready to run, since mailbox can contain only system messages
  var messageCountNonSystem: Int {
    return max(0, activations - 1)
  }
  var isTerminating: Bool {
    return (self.value & Masks.terminating.rawValue) != 0
  }
  var isTerminated: Bool {
    return self.value < 0 // since leading bit is used for sign, and Terminated is the Int's leading bit
  }
}

extension MailboxStatus: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    return self.debugDescription // "\(type(of: self))(0b\(String(value, radix: 2)))"
  }

  public var debugDescription: String {
    return "\(type(of: self))(0b\(String(value, radix: 2)):\(value == 0 ? "IDLE" : "") Act:\(self.activations):\(self.isActive ? "y" : "n"),Mc:\(self.messageCountNonSystem),Ti:\(self.isTerminating ? "y" : "n"),Td:\(self.isTerminated ? "y" : "n"))"
  }
}
