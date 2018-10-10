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

// MARK: Dispatch based executors

public protocol Runnable {
  func run()
}

/// An `Executor` is a low building block that is able to take blocks and schedule them for running
public protocol MessageDispatcher {

  // TODO we should make it dedicated to dispatch() rather than raw executing perhaps? This way it can take care of fairness things


  // TODO will show up in performance work I guess; make sure we don't need to allocate those () -> always,
  //      but e.g. only when the underlying one impl needs it; e.g. dispatch seems to

  // func attach(cell: AnyActorCell)

  var name: String { get }

  // TODO is Swift style to do those `-> Void` or `-> ()` or just nothing for func declarations?
//  func execute(_ f: @escaping () -> Void) -> ()
  func execute(_ f: Runnable) -> ()
}

// TODO not sure we need this extension
extension DispatchQueue: MessageDispatcher {

  public var name: String {
    return String(cString: __dispatch_queue_get_label(nil), encoding: .utf8)!

    // TODO if Foundation available also log the thread name?

    // TODO if pthread, log process id
  }

  public func execute(_ f: Runnable) {
    self.async(execute: { () -> () in
      print("[dispatcher: \(self.name)]: \(f)")
      f.run()
    })
  }

}

// MARK: TODO implement custom executors

