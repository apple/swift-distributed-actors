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

public final class MPSCLinkedQueue<A> {
  public let q: UnsafeMutablePointer<CMPSCLinkedQueue>;
  public init() {
    q = cmpsc_linked_queue_create()
  }

  deinit {
    cmpsc_linked_queue_destroy(q)
  }

  @inlinable
  public func enqueue(_ item: A) -> Void {
    // When using this, A has to be constrained to AnyObject, but
    // performance is better
    //
    // let unmanaged = Unmanaged<A>.passRetained(item)

    let ptr = UnsafeMutablePointer<A>.allocate(capacity: 1)
    ptr.initialize(to: item)
    cmpsc_linked_queue_enqueue(q, ptr)
  }

  @inlinable
  public func dequeue() -> A? {
    if let p = cmpsc_linked_queue_dequeue(q) {
      // When using this, A has to be constrained to AnyObject, but
      // performance is better
      //
      // return Unmanaged<A>.fromOpaque(p).takeRetainedValue()

      let ptr = p.assumingMemoryBound(to: A.self)
      defer {
        ptr.deallocate()
      }
      return ptr.move()
    }

    return nil
  }

  @inlinable
  public func isEmpty() -> Bool {
    return cmpsc_linked_queue_is_empty(q) != 0
  }
}

//protocol Queue {
//  associatedtype A
//
//  func dequeue() -> A?
//
//  func enqueue(_ item: A) -> Void
//
//  func isEmpty() -> Bool
//}
