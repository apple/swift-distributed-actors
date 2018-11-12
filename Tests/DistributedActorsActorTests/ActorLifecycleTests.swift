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
@testable import Swift Distributed ActorsActor
import Swift Distributed ActorsActorTestkit

class ActorLifecycleTests: XCTestCase {

  let system = ActorSystem("ActorSystemTests")

  override func tearDown() {
    // Await.on(system.terminate()) // FIXME termination that actually does so
  }

  func test_shouldNotAllowStartingWith_Same() throws {
    // since there is no previous behavior to stay "same" name at the same time:

    let ex = shouldThrow({
      let sameBehavior: Behavior<String> = .same
      let _ = try self.system.spawn(sameBehavior, named: "same")
    })

    "\(ex)".shouldEqual("""
                        notAllowedAsInitial(Swift Distributed ActorsActor.Behavior<Swift.String>.same)
                        """)
  }

  func test_shouldNotAllowStartingWith_Unhandled() throws {
    // the purpose of unhandled is to combine with things that can handle, and if we start a raw unhandled
    // it always will be unhandled until we use some signal to make it otherwise... weird edge case which
    // is better avoided all together.
    //
    // We do allow starting with .ignore though since that's like a "blackhole"

    let ex = shouldThrow({
      let unhandledBehavior: Behavior<String> = .unhandled
      let _ = try system.spawn(unhandledBehavior, named: "unhandled")
    })

    "\(ex)".shouldEqual("notAllowedAsInitial(Swift Distributed ActorsActor.Behavior<Swift.String>.unhandled)")
  }

  func test_spawn_shouldNotAllowIllegalActorNames() throws {
    func check(illegalName: String, expectedError: String) throws {
      let err = shouldThrow({
        let b: Behavior<String> = .ignore

        // more coverage for all the different chars in [[ActorPathTests]]
        let _ = try system.spawn(b, named: illegalName)
      })
      "\(err)".shouldEqual(expectedError)
    }

    try check(illegalName: "hello world", expectedError: """
                                                         illegalActorPathElement(name: "hello world", illegal: " ", index: 5)
                                                         """)

    try check(illegalName: "he//o", expectedError: """
                                                   illegalActorPathElement(name: "he//o", illegal: "/", index: 2)
                                                   """)
    try check(illegalName: "ążŻŌżąć", expectedError: """
                                                     illegalActorPathElement(name: "ążŻŌżąć", illegal: "ą", index: 0)
                                                     """)
    try check(illegalName: "カピバラ", expectedError: """
                                                     illegalActorPathElement(name: "カピバラ", illegal: "カ", index: 0)
                                                     """)

  }

}
