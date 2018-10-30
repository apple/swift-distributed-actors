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
struct Envelope<Message> {
  let payload: Message

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

struct WrappedClosure {
  let fn: (UnsafeMutableRawPointer) -> Void

  init(_ fn: @escaping (UnsafeMutableRawPointer) -> Void) {
    self.fn = fn
  }

  @inlinable
  func exec(with ptr: UnsafeMutableRawPointer) -> Void {
    fn(ptr)
  }
}

final class NativeMailbox<Message> {
  var mailbox: UnsafeMutablePointer<CMailbox>
  var cell: ActorCell<Message>
  var context: WrappedClosure
  var systemContext: WrappedClosure
  let interpretMessage: InterpretMessageCallback

  init(cell: ActorCell<Message>, capacity: Int) {
    self.mailbox = cmailbox_create(Int64(capacity));
    self.cell = cell
    self.context = WrappedClosure({ ptr in
      let envelopePtr = ptr.assumingMemoryBound(to: Envelope<Message>.self)
      let envelope = envelopePtr.move()
      let msg = envelope.payload
      cell.interpretMessage(message: msg)
    })

    self.systemContext = WrappedClosure({ ptr in
      let envelopePtr = ptr.assumingMemoryBound(to: SystemMessage.self)
      let msg = envelopePtr.move()
      cell.interpretSystemMessage(message: msg)
    })

    interpretMessage = { (ctxPtr, msg) in
      defer { msg?.deallocate() }
      let ctx = ctxPtr?.assumingMemoryBound(to: WrappedClosure.self)
      ctx?.pointee.exec(with: msg!)
    }
  }

  deinit {
    cmailbox_destroy(mailbox)
  }

  @inlinable
  func sendMessage(envelope: Envelope<Message>) -> Void {
    let ptr = UnsafeMutablePointer<Envelope<Message>>.allocate(capacity: 1)
    ptr.initialize(to: envelope)
    if (cmailbox_send_message(mailbox, ptr)) {
      cell.dispatcher.execute(self.run)
    }
  }

  @inlinable
  func sendSystemMessage(_ systemMessage: SystemMessage) -> Void {
    let ptr = UnsafeMutablePointer<SystemMessage>.allocate(capacity: 1)
    ptr.initialize(to: systemMessage)
    if (cmailbox_send_system_message(mailbox, ptr)) {
      cell.dispatcher.execute(self.run)
    }
  }

  @inlinable
  func run() -> Void {
    let requeue = cmailbox_run(mailbox, &context, &systemContext, interpretMessage)

    if (requeue) {
      cell.dispatcher.execute(self.run)
    }
  }
}
