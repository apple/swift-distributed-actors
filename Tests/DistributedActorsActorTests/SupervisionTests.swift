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

class SupervisionTests: XCTestCase {

  func test_compile() throws {
    let b: Behavior<String> = .receive { s in .same }

//    public enum Behavior<Message> {
//      indirect case supervise(_ behavior: Behavior<Message>, strategy: (Supervision.Failure) -> Supervision.Directive) // TODO I assume this causes us to lose all benefits of being an enum? since `indirect`
//    }

      // when you want to inspect the failure before deciding:
    let _: Behavior<String> = .supervise(b) { failure -> Supervision.Directive in
      return Supervision.Directive.restart
    }

//    indirect case supervise(_ behavior: Behavior<Message>, strategy: (Supervision.Failure) -> Supervision.Directive) // TODO I assume this causes us to lose all benefits of being an enum? since `indirect`
//
//    public static func supervise(_ behavior: Behavior<Message>, directive: Supervision.Directive) -> Behavior<Message> {
//      return .supervise(behavior) { _ in directive }
//    }
    // when you always want to apply a given directive for failures of given behavior:
    let _: Behavior<String> = .supervise(b, directive: .stop)
  }

}
