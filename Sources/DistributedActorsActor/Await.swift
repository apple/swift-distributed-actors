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

public class Awaitable {
  fileprivate let underlyingLock: Lock

  init(underlyingLock: Lock) {
    self.underlyingLock = underlyingLock
  }
}


// Implementation notes:
// Since we want to discourage blocking, we dont' expose blocking methods on APIs themselfes,
// but instead return something that is able to block on. And then it is very explicit that we `Await.ready(theThing)`
// It also is visually similar to what we would get to if there was `async await`, though the same pattern exists
// in Scala/Akka just to steer people away from blocking, even without presence of async await.
public struct Await {
  public static func ready(_ awaitable: Awaitable /*, atMost timeout: Timeout*/) -> Void {
    self.on(awaitable)
  }

  public static func on(_ awaitable: Awaitable /*, atMost timeout: Timeout*/) -> Void {
    awaitable.underlyingLock.lock() // TODO one with timeout would be nice
  }

  // func result(awaitable: Awaitable<T>) -> T
}