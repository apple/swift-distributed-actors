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

class ActorSystemTests: XCTestCase {

    let MaxSpecialTreatedValueTypeSizeInBytes = 24

    let system = ActorSystem("ActorSystemTests")

    override func tearDown() {
        // system.terminate()
    }

}
