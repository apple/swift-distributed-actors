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
  #if SACTANA_DEBUG // TODO: AFAIK this does work yet right?
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
public protocol Mailbox: Runnable {

  func enqueue(envelope: Envelope) -> ()
  func dequeue() -> Envelope?

  func enqueueSystem(message: SystemMessage) -> ()
  func dequeueSystem() -> SystemMessage?

  /// Returns a definite answer if the mailbox nas messages to run
  func hasMessages() -> Bool

  // Note to self: DO NOT rely on this method to schedule execution of the mailbox; only the hasMessages should be used for that purpose AFAIR
  /// NOTE: Not all mailboxes are able to return an exact count and may estimate the size
  func count() -> Int
  func isCountExact() -> Bool

  // MARK: INTERNAL API
  // TODO hide those from outside users?

  // func setActor(cell: AnyActorCell)

  func run()
}

/// Represents the
// Implementation note:
// We implement the mailbox state in such sneaky way in order to be able to at the same time modify scheduled/idle
// and message count values; which are used to estimate the throughput to apply on this mailbox run. This is losely based
// on the dropped Typed Akka ActorSystem implementation by Roland Kuhn, from 2016 https://github.com/akka/akka/pull/21128/files#diff-92d9e38d1b6b284e38230047feea5fdcR36
private struct MailboxStatusMasks {
  static let InactiveBit = 0
  static let ActivatedOnlySystemMessagesBit = 1
  static let ActivatedBits = 0x11 // FIXME
  // static let ActivatedBits = (2 ... 29) // not really going to use this, mostly as documentation of the bit range
  static let TerminatingBit = 1 << 30
  static let TerminatedBit = 1 << 31
}

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
protocol MailboxStatusSnapshot {
  var isTerminating: Bool { get }
  var isTerminated: Bool { get }
  var isActive: Bool { get }
  var activations: Int { get }
}

/// Extends `MailboxStatusSnapshot` with the ability to update the states
// TODO want to expose this to dispatcher and let IT decide // this was never done but we wanted to in typed
protocol MailboxStatus: MailboxStatusSnapshot {
  /// Increments underlying counter by 1
  /// Returns a snapshot of the previous mailbox status; a snapshot can not be modified, only read.
  func incrementActivations() -> MailboxStatusSnapshot

  // TODO func rollbackActivationIncrement
}
// TODO make this to make it cleaner; can't update the snapshot; only the real current one
//struct MailboxStatusSnapshot {
//  let underlying: Int
//
//
//  var isTerminating: Bool {
//    return check
//  }
//  var isTerminated: Bool { get }
//  var isActive: Bool { get }
//  var activations: Int { get }
//}

extension Atomic: MailboxStatus, MailboxStatusSnapshot where T == Int {

  func checkStatus(bit: Int) -> Bool {
    return (self.load() & bit) != 0
  }

  var isTerminating: Bool {
    return checkStatus(bit: MailboxStatusMasks.TerminatingBit)
  }
  var isTerminated: Bool {
    return self.load() < 0 // since 32th bit used for marking sign
  }
  var isActive: Bool {
    return true // FIXME: self.load() ...
  }
  var activations: Int {
    return self.load() & MailboxStatusMasks.ActivatedBits
  }

  func incrementActivations() -> MailboxStatusSnapshot {
    return self.add(1)
  }
}

extension Int: MailboxStatusSnapshot {

  func checkStatus(bit: Int) -> Bool {
    return (self & bit) != 0
  }

  var isTerminating: Bool {
    return checkStatus(bit: MailboxStatusMasks.TerminatingBit)
  }
  var isTerminated: Bool {
    return self < 0 // since 32th bit used for marking sign
  }
  var isActive: Bool {
    return true // FIXME: self.load() ...
  }
  var activations: Int {
    return self & MailboxStatusMasks.ActivatedBits
  }
}

// Implementation Note:
// It may seem tempting to allow total extensability of mailboxes by end users; in reality this has always been a bad idea in Akka
// since people attempt to solve their protocol and higher level issues by "we'll make a magical mailbox for it"
// Mailboxes must be Simple.
final class DefaultMailbox<Message>: Mailbox {

  let state: MailboxStatus = Atomic<Int>(value: 0)

  // FIXME we want to remove this and replace with acquire/release access to the mailbox status
  private let runLock = Lock() // I'm sorry

  // updates to these MUST be atomic
  private var cell: ActorCell<Message>

  private var queue = MPSCLinkedQueue<Envelope>() // TODO configurable (bounded / unbounded etc); default to be array backed
  private var systemQueue = MPSCLinkedQueue<SystemMessage>() // TODO specialize the queue, make it light and linked; the queue for normal messages should be optimized, likely array backed

  init(cell: ActorCell<Message>) {
    self.cell = cell
  }

  func enqueue(envelope: Envelope) -> () {
    let old = state.incrementActivations()
    let oldActivations = old.activations

    // FIXME implement ptoperly counting if we need to activate

    if (oldActivations == 0) {
      // so no one activated and we have to do so
      scheduleForExecution()
    } else {
      // TODO what then; undo the activation increment?
    }
  }
  func dequeue() -> Envelope? {
    return queue.dequeue()
  }

  func enqueueSystem(message: SystemMessage) {
    print("self.systemQueue.enqueue(message) = \(message)")
    self.systemQueue.enqueue(message)
    scheduleForExecution() // TODO logic for when to schedule
  }

  func dequeueSystem() -> SystemMessage? {
    return systemQueue.dequeue()
  }

  func hasMessages() -> Bool {
    return undefined()
  }

  func count() -> Int {
    return undefined()
  }

  func isCountExact() -> Bool {
    return undefined()
  }

  internal func setActor(cell: ActorCell<Message>) {
    self.cell = cell
  }

  //
  // FIXME: In order to be able to remove the lock (we really really need to remove it) we'll need acquire/release semantics on the mailbox status field
  func run() {
    runLock.withLockVoid {
      // TODO failure handling in case those crash
      runSystemMessages()
      runUserMessages()

      // keep running iff there are more pending messages remaining
      scheduleForExecution()
    }
  }

  // RUN ONLY WHILE PROTECTED BY `runLock`
  private func runSystemMessages() {
    while let sys = dequeueSystem() {
      cell.invokeSystem(message: sys)
    }
    // TODO implement system messages; we always run the entire system queue here
  }

  // RUN ONLY WHILE PROTECTED BY `runLock`
  private func runUserMessages() {
    // FIXME first process system messages; then use throughput to process N messages of mailbox
    let MaxRunLength = 1024
    var remainingRun = min(count(), MaxRunLength) // TODO apply throughput limit; this is what dispatcher can use to apply fairness

    // FIXME this has to take into account the runLength
    while let e = dequeue() { // FIXME look at run len
      let next = cell.invokeMessage(message: e.payload as! Message) // FIXME make the envelope typed as well
      cell.nextBehavior(next)
      remainingRun -= 1 // TODO actually use it
    }
  }

  // RUN ONLY WHILE PROTECTED BY `runLock`
  private func scheduleForExecution() {
    print("scheduleForExecution = \(self)")
    cell._dispatcher.execute(self)
  }

}

//final class SignalMailbox {
//  // TODO make use of unsafe pointers
//  var head: Any?
//  var tail: Any?
//
//  func enqueue(envelope: Envelope) -> () {
//    return FIXME("Implement the simple linked queue")
//  }
//
//  func dequeue() -> Envelope {
//    return FIXME("Implement the simple linked queue")
//  }
//
//  func hasMessages() -> Bool {
//    return FIXME("Implement the simple linked queue")
//  }
//
//  func count() -> Int {
//    if hasMessages() {
//      return 0
//    } else {
//      return 1
//    }
//  }
//
//  func isCountExact() -> Bool {
//    return false
//  }
//
////  internal func setActor(cell: AnyActorCell) {
////
////  }
//
//}