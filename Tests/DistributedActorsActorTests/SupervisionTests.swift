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

class SupervisionTests: XCTestCase {

    let system = ActorSystem("SupervisionTests")

    override func tearDown() {
        system.terminate()
    }

    func test_compile() throws {
        let faultyWorker: Behavior<String> = .ignore

        // supervise

        let _: Behavior<String> = Behavior.supervise(faultyWorker, withStrategy: .stop)
        let _: Behavior<String> = Behavior.supervise(faultyWorker, withStrategy: .restart(atMost: 3))

        // supervised
    }

}

