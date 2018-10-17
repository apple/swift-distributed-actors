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
  func dequeueMessage() -> Envelope?

  func sendSystemMessage(_ message: SystemMessage) -> ()
  func dequeueSystemMessage() -> SystemMessage?

  // MARK: INTERNAL API
  // TODO hide those from outside users?

  // func setActor(cell: AnyActorCell)

  /// A mailbox run consists of processing pending system and user messages
  func run()
}

// Implementation Note:
// It may seem tempting to allow total extensability of mailboxes by end users; in reality this has always been a bad idea in Akka
// since people attempt to solve their protocol and higher level issues by "we'll make a magical mailbox for it"
// Mailboxes must be Simple.
final class DefaultMailbox<Message> : Mailbox {

  private let _status = Atomic<Int>(value: 0)
  private func status() -> MailboxStatus { return MailboxStatus(underlying: _status.load()) }

  private let runLock = Lock() // I'm sorry // TODO remove once we get acquire/release semantics access

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
    let old = incrementStatusActivations() // also takes care of setting it as active
    let oldActivations = old.messageCountNonSystem

    if (oldActivations > capacity) {
      // meaning: mailbox is over capacity
      decrementStatusActivations() // rollback the update to `old` state, since we're dropping the message

      // Implementation notes:
      // "Dropping" is specific wording used to signal that a message is dropped due to mailbox etc over-capacity
      // It is different than "dead letter" which means a message arrived at terminated actor.
      // The two seem similar, but point at different programming errors:
      //   - dropping is flow control issues
      //   - dead letters may be lifecycle issues or races
      pprint("DROPPED: Mailbox overflow (capacity: \(capacity), dropping: \(type(of: envelope.payload)), in \(self.cell.myself)") // TODO: log this properly
    } else if (old.isTerminating) {
      // meaning: we enqueued a message to an actor which is in the process of terminating, but not terminated yet
      decrementStatusActivations()

      pprint("DEAD LETTER: \(self.cell.myself) is terminating, thus message \(type(of: envelope.payload)) is a dead letter")
    } else if (oldActivations == 0) {
      // no activations yet, which means we are responsible for scheduling the actor for execution
      // TODO this is where "smart batching" could come into play; to schedule later than immediately
      queue.enqueue(envelope)

      scheduleForExecution(hasMessageHint: true, hasSystemMessageHint: false)
    }
  }

  func dequeueMessage() -> Envelope? {
    return queue.dequeue()
  }

  func sendSystemMessage(_ message: SystemMessage) {
    // todo handle errors

    pprint("sendSystemMessage: \(message) @ old: \(self.status().debugDescription)")
    let old = incrementStatusActivations()

    if (old.isTerminated) {
      pprint("\(self) is terminated, NOT enqueueing system message \(message). Terminating.")
      decrementStatusActivations()
    } else {
      // which means we are allowed to enqueue
      self.systemQueue.enqueue(message)

      // we need to decide though if we need to schedule execution,
      // or if we already were scheduled (by some other send triggering it:
      if (old.messageCountNonSystem == 0) {
        // no messages were enqueued before we performed the increment
        // we are responsible of activating the actor
        pprint("\(self) enqueued signal \(message): activating")
        scheduleForExecution(hasMessageHint: false, hasSystemMessageHint: true) // hint that we are certain that we should execute
      } else {
        // the mailbox was already scheduled (since message count was > 0, which means first to send message performed the scheduling)
        pprint("\(self) enqueued signal \(message): already active (scheduled)")
      }
    }

    // TODO more logic here to avoid scheduling many times
    scheduleForExecution(hasMessageHint: false, hasSystemMessageHint: true)
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
  private func incrementStatusActivations() -> MailboxStatus {
    let old: Int = self._status.add(1)
    return MailboxStatus(underlying: old)
  }
  /// Increments underlying status by -1
  /// Used to "revert" an increment that was made too eagerly while entering a send*
  private func decrementStatusActivations() -> Void {
    let old = self._status.add(-1)
    assertWithDetails(MailboxStatus(underlying: old).messageCountNonSystem > 0, self, "Decremented below 0 activations, this must never happen and is a bug!")
  }

  // MARK: Running the mailbox

  // FIXME: In order to be able to remove the lock (we really really need to remove it) we'll need acquire/release semantics on the mailbox status field
  func run() { // TODO pass in "RunAllowance" or "RunDirectives" which the mailbox should respect (e.g. capping max run length)
    runLock.withLockVoid {
      let status: MailboxStatus = self.status()
      pprint("status = \(status)")

      guard status.isActive else { return } // dead actors don't run
      pprint("[Mailbox] Entering run \(self): Status: \(status.debugDescription)")

      // TODO failure handling in case those crash

      // TODO run only if has system messages?
      runSystemMessages()
      runUserMessages(activations: status.messageCountNonSystem, runLimit: 100) // FIXME take from run directive from cell/dispatcher which passes in here

      // TODO once lock is gone, we need more actions here, to check again if we received any messages etc

      // keep running iff there are more pending messages remaining
      scheduleForExecution(hasMessageHint: false, hasSystemMessageHint: false)

      pprint("[Mailbox] Exiting run \(self): Status: \(status.debugDescription)")
    }
  }

  // RUN ONLY WHILE PROTECTED BY `runLock`
  private func runSystemMessages() {
    while let sys = dequeueSystemMessage() {
      cell.invokeSystem(message: sys)
    }
    // TODO implement system messages; we always run the entire system queue here
  }

  // RUN ONLY WHILE PROTECTED BY `runLock`
  private func runUserMessages(activations: Int, runLimit: Int) {
    guard activations > 0 else {
      return
    } // no reason to run when no activations

    var remainingRun = min(activations, runLimit) // TODO apply throughput limit; this is what dispatcher can use to apply fairness

    // FIXME this has to take into account the runLength
    while let e = dequeueMessage() { // FIXME look at run len

      // mutates the cell
      cell.interpretMessage(message: e.payload as! Message) // FIXME make the envelope typed as well
      remainingRun -= 1 // TODO actually use it
    }
  }

  // RUN ONLY WHILE PROTECTED BY `runLock`
  private func scheduleForExecution(hasMessageHint: Bool, hasSystemMessageHint: Bool) {
    // if can be scheduled for execution
    cell.dispatcher.registerForExecution(self, status: self.status(), hasMessageHint: hasMessageHint, hasSystemMessageHint: hasSystemMessageHint)
  }
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
    case activatedOnlySystemMessages = 0b00000000_00000000_00000000_00000010 // 1 bit
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
  /// Count of user messages contained in mailbox (plus, potentially any system messages)
  /// Could be 0 but still be ready to run, since mailbox can contain only system messages
  var messageCountNonSystem: Int {
    return max(0, (self.value & Masks.activations.rawValue) - 1)
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
    return "\(type(of: self))(\(String(value, radix: 2)))"
  }

  public var debugDescription: String {
    return "\(type(of: self))(0b\(String(value, radix: 2)): Act:\(self.isActive ? "y" : "n"),A:\(self.messageCountNonSystem),Ti:\(self.isTerminating ? "y" : "n"),Td:\(self.isTerminated ? "y" : "n"))"
  }
}