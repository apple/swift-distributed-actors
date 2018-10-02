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

/// INTERNAL API
struct Envelope {
  let payload: Any

  // Note that we can pass around senders however we can not automatically get the type of them right.
  // We may want to carry around the sender path for debugging purposes though "[pathA] crashed because message [Y] from [pathZ]"
  // TODO explain this more
#if SACTANA_DEBUG
  let senderPath: String
#endif

  // Implementation notes:
  // Envelopes are also used to enable tracing, both within an local actor system as well as across systems
  // the beauty here is that we basically have the "right place" to put the trace metadata - the envelope
  // and don't need to do any magic around it
}

protocol Mailbox {
  // DONT BLOCK HERE
  func enqueue(envelope: Envelope) -> ()

  // DONT BLOCK HERE
  func dequeue() -> Envelope

  /// Returns a definite answer if the mailbox nas messages to run
  func hasMessages() -> Bool

  // Note to self: DO NOT rely on this method to schedule execution of the mailbox; only the hasMessages should be used for that purpose AFAIR
  /// NOTE: Not all mailboxes are able to return an exact count and may estimate the size
  func count() -> Int
  func isCountExact() -> Bool
}

// Implementation Note:
// It may seem tempting to allow total extensability of mailboxes by end users; in reality this has always been a bad idea in Akka
// since people attempt to solve their protocol and higher level issues by "we'll make a magical mailbox for it"
// Mailboxes must be Simple.

final class DefaultFIFOMailbox: Mailbox {
  func enqueue(envelope: Envelope) -> () {
    return undefined()
  }

  func dequeue() -> Envelope {
    return undefined()
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
}

final class SignalMailbox {
  // TODO make use of unsafe pointers
  var head: Any?
  var tail: Any?

  func enqueue(envelope: Envelope) -> () {
    return FIXME("Implement the simple linked queue")
  }

  func dequeue() -> Envelope {
    return FIXME("Implement the simple linked queue")
  }

  func hasMessages() -> Bool {
    return FIXME("Implement the simple linked queue")
  }

  func count() -> Int {
    if hasMessages() {
      return 0
    } else {
      return 1
    }
  }

  func isCountExact() -> Bool {
    return false
  }
}