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
import XCTest
import Swift Distributed ActorsActor

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

// TODO just prototyping, not sure yet
struct Failure {
  var isError = false
  var isFatalError = false
  var isFailure = false

  var underlyingSignal = Optional(EINVAL) // underlying error signal if it was a Failure

}

private extension Behavior {
  func supervise(_ decide: (Failure) -> Supervision.Directive) -> Behavior<Message> {
    return TODO("not implemented yet")
  }
}

class SupervisionTests: XCTestCase {

  func test_compile() throws {
    return () // compile only spec

    let b: Behavior<String> = .receiveMessage { s in .same }

    let _: Behavior<String> = b.supervise { failure -> Supervision.Directive in
      return .restart
    }
  }

}
