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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

final class ActorMemoryTests: XCTestCase {
    // Tests which measure how much memory actors take

    // TODO: we could use malloc hooking to get an idea about this in allocation tests; more interesting since over time as well based on ops

    func test_osx_actorShell_instanceSize() {
        #if os(OSX)
        class_getInstanceSize(ActorShell<Int>.self).shouldEqual(560)
        class_getInstanceSize(ActorShell<String>.self).shouldEqual(560)
        #else
        print("Skipping test_osx_actorShell_instanceSize as requires Objective-C runtime")
        #endif
    }
}
