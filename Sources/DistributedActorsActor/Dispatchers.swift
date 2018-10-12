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

import Foundation
import NIO

/// An `Executor` is a low building block that is able to take blocks and schedule them for running
public protocol MessageDispatcher {

  // TODO we should make it dedicated to dispatch() rather than raw executing perhaps? This way it can take care of fairness things

  // TODO will show up in performance work I guess; make sure we don't need to allocate those () -> always,
  //      but e.g. only when the underlying one impl needs it; e.g. dispatch seems to

  // func attach(cell: AnyActorCell)

  var name: String { get }

  func registerForExecution(_ mailbox: Mailbox, status: MailboxStatus, hasMessageHint: Bool, hasSystemMessageHint: Bool)

  func execute(_ f: @escaping () -> Void)
}

// MARK: Dispatch based executors

// TODO not sure we need this extension
extension DispatchQueue: MessageDispatcher {

  public var name: String {
    let queueName = String(cString: __dispatch_queue_get_label(nil), encoding: .utf8)!

    let threadName = Thread.current // .terribleHackThreadId

    return  "\(queueName)#\(threadName)"

    // TODO if Foundation available also log the thread name?

    // TODO if pthread, log process id
  }

  public func registerForExecution(_ mailbox: Mailbox, status: MailboxStatus, hasMessageHint: Bool, hasSystemMessageHint: Bool) {
     // volatile read needed (acquire) (in future)
    var canBeScheduled: Bool = false
    if hasMessageHint || hasSystemMessageHint {
      canBeScheduled = true
    } else if (status.isTerminated) {
      canBeScheduled = false
    } // FIXME needs more reads once we go async
    
    if canBeScheduled {
      pprint("mailbox \(mailbox) = \(canBeScheduled)")
      // TODO set as scheduled
      // status.setAsScheduled
      self.execute(mailbox.run)
    }
  }

  public func execute(_ f: @escaping () -> Void) {
    #if SACT_DEBUG
    self.async(execute: { () -> () in
      pprint("[dispatcher: \(self.name)]: \(f)")
      f()
    })
    #else
    self.async(execute: f)
    #endif
  }
}

extension MessageDispatcher {
  func execute(mailbox: Mailbox) {
    self.execute(mailbox.run)
  }
}

// terrible hack, would prefer NSThread to solve: "Expose thread number in NSThread" https://bugs.swift.org/browse/SR-1075

extension Foundation.Thread {
  // FIXME 1) do this nicer 2) get official API for thread id
  // TODO is it better to expose the <...> thread id rather than number?
  var terribleHackThreadId: Int {
    let idString: String = self.debugDescription
    let trimmedFront = idString.drop(while: { $0 != "=" }).dropFirst(2)
    let it = trimmedFront.reversed().drop(while: { $0 != "," }).dropFirst().reversed() // reversed is cheap, just a view right?
    return Int(String(it))!
  }
}