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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

public final class Mutex {
  var mutex: pthread_mutex_t = pthread_mutex_t()

  public init() {
    var attr: pthread_mutexattr_t = pthread_mutexattr_t()
    pthread_mutexattr_init(&attr)
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE)

    let error = pthread_mutex_init(&mutex, &attr)
    pthread_mutexattr_destroy(&attr)

    switch error {
    case 0:
      return
    default:
      fatalError("Could not create mutex: \(error)")
    }
  }

  deinit {
    pthread_mutex_destroy(&mutex)
  }

  public func lock() -> Void {
    let error = pthread_mutex_lock(&mutex)

    switch error {
    case 0:
      return
    case EDEADLK:
      fatalError("Mutex could not be acquired because it would have caused a deadlock")
    default:
      fatalError("Failed with unspecified error: \(error)")
    }
  }

  public func unlock() -> Void {
    let error = pthread_mutex_unlock(&mutex)

    switch error {
    case 0:
      return
    case EPERM:
      fatalError("Mutex could not be unlocked because it is not held by the current thread")
    default:
      fatalError("Unlock failed with unspecified error: \(error)")
    }
  }

  public func synchronized<A>(_ f: () -> A) -> A {
    lock()

    defer {
      unlock()
    }

    return f()
  }
}
