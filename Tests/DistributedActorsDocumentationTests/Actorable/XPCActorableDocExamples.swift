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

// tag::imports[]

import DistributedActors
import XPCActorable

// end::imports[]

import DistributedActorsTestKit
import XCTest

// tag::xpc_greeter_0[]
struct Greeter: Actorable {
    func greet(name: String) -> String {
        "Hello, \(name)!"
    }
}

// end::xpc_greeter_0[]

class XPCExampleCaller {
// tag::xpc_greeter_caller0[]

// end::xpc_greeter_caller[]
}
