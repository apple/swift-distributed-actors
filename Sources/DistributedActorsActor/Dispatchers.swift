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

import Dispatch
import NIO

/// An `Executor` is a low building block that is able to take blocks and schedule them for running
public protocol MessageDispatcher {

  // TODO we should make it dedicated to dispatch() rather than raw executing perhaps? This way it can take care of fairness things

  // func attach(cell: AnyActorCell)

  var name: String { get }

  /// - Returns: `true` iff the mailbox status indicated that the mailbox should be run (still contains pending messages)
  //func registerForExecution(_ mailbox: Mailbox, status: MailboxStatus, hasMessageHint: Bool, hasSystemMessageHint: Bool) -> Bool

  func execute(_ f: @escaping () -> Void)
}

// MARK: Dispatch based executors

// TODO not sure we need this extension
extension DispatchQueue: MessageDispatcher {

  public var name: String {
    let queueName = String(cString: __dispatch_queue_get_label(nil), encoding: .utf8)!

     //let thread: Thread = Thread.current
//    let threadName = thread.name ?? "\(thread.terribleHackThreadId)"
    let threadName = "--" //"\(thread.terribleHackThreadId)"

    return  "\(queueName)#\(threadName)"

    // TODO if Foundation available also log the thread name?

    // TODO if pthread, log process id
  }

  // TODO would want to mutate the status here
  public func registerForExecution(_ mailbox: Mailbox, status: MailboxStatus, hasMessageHint: Bool, hasSystemMessageHint: Bool) -> Bool {
     // volatile read needed (acquire) (in future)
    var canBeScheduled: Bool

    if hasMessageHint || hasSystemMessageHint {
      canBeScheduled = true
    } else if (status.isTerminated) {
      canBeScheduled = false
    } else {
      canBeScheduled = false
    }
    
    if canBeScheduled {
      pprint("[dispatcher: Thread: --] \(mailbox), canBeScheduled=\(canBeScheduled); ")
      self.execute({ () in
        pprint("[Executor: Thread: --] Running mailbox \(mailbox), CALLING RUN NOW")
        mailbox.run()
      })
    }

    return canBeScheduled
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
  func execute(_ mailbox: Mailbox) {
    self.execute(mailbox.run)
  }
}

// terrible hack, would prefer NSThread to solve: "Expose thread number in NSThread" https://bugs.swift.org/browse/SR-1075
/*
extension Thread {
  // FIXME 1) do this nicer 2) get official API for thread id
  // TODO is it better to expose the <...> thread id rather than number?
  var terribleHackThreadId: Int {
    let idString: String = self.debugDescription
    let trimmedFront = idString.drop(while: { $0 != "=" }).dropFirst(2)
    let it = trimmedFront.reversed().drop(while: { $0 != "," }).dropFirst().reversed() // reversed is cheap, just a view right?
    return Int(String(it))!
  }
}
*/
