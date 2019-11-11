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
import DistributedActorsTestTools
import XCTest

final class ActorNamingTests: XCTestCase {
    func test_makeName_unique() {
        var context = ActorNamingContext()
        let naming = ActorNaming.unique("hello")

        for _ in 0 ... 3 {
            let name = naming.makeName(&context)
            name.shouldEqual("hello")
        }
    }

    func test_makeName_sequentialNumeric() {
        var context = ActorNamingContext()
        let naming = ActorNaming(unchecked: .prefixed(prefix: "hello", suffixScheme: .sequentialNumeric))

        for i in 0 ... 100 {
            let name = naming.makeName(&context)
            name.shouldEqual("hello-\(i)")
        }
    }

    func test_makeName_letters() {
        var context = ActorNamingContext()
        let naming = ActorNaming(unchecked: .prefixed(prefix: "hello", suffixScheme: .letters))

        naming.makeName(&context).shouldEqual("hello-y")
        naming.makeName(&context).shouldEqual("hello-b")
        naming.makeName(&context).shouldEqual("hello-n")
        naming.makeName(&context).shouldEqual("hello-d")
        naming.makeName(&context).shouldEqual("hello-r")
        naming.makeName(&context).shouldEqual("hello-f")
        naming.makeName(&context).shouldEqual("hello-g")
        naming.makeName(&context).shouldEqual("hello-8")
        naming.makeName(&context).shouldEqual("hello-e")
        naming.makeName(&context).shouldEqual("hello-j")
        naming.makeName(&context).shouldEqual("hello-k")
        naming.makeName(&context).shouldEqual("hello-m")
        naming.makeName(&context).shouldEqual("hello-c")
        naming.makeName(&context).shouldEqual("hello-p")
        naming.makeName(&context).shouldEqual("hello-q")
        naming.makeName(&context).shouldEqual("hello-x")
        naming.makeName(&context).shouldEqual("hello-o")
        naming.makeName(&context).shouldEqual("hello-t")
        naming.makeName(&context).shouldEqual("hello-1")
        naming.makeName(&context).shouldEqual("hello-u")
        naming.makeName(&context).shouldEqual("hello-w")
        naming.makeName(&context).shouldEqual("hello-i")
        naming.makeName(&context).shouldEqual("hello-s")
        naming.makeName(&context).shouldEqual("hello-z")
        naming.makeName(&context).shouldEqual("hello-a")
        naming.makeName(&context).shouldEqual("hello-3")
        naming.makeName(&context).shouldEqual("hello-4")
        naming.makeName(&context).shouldEqual("hello-5")
        naming.makeName(&context).shouldEqual("hello-h")
        naming.makeName(&context).shouldEqual("hello-7")
        naming.makeName(&context).shouldEqual("hello-6")
        naming.makeName(&context).shouldEqual("hello-9")
        naming.makeName(&context).shouldEqual("hello-yb")
        naming.makeName(&context).shouldEqual("hello-bb")
        naming.makeName(&context).shouldEqual("hello-nb")
        naming.makeName(&context).shouldEqual("hello-db")
        naming.makeName(&context).shouldEqual("hello-rb")
        naming.makeName(&context).shouldEqual("hello-fb")
        naming.makeName(&context).shouldEqual("hello-gb")
        naming.makeName(&context).shouldEqual("hello-8b")
        naming.makeName(&context).shouldEqual("hello-eb")
        naming.makeName(&context).shouldEqual("hello-jb")
        naming.makeName(&context).shouldEqual("hello-kb")
        naming.makeName(&context).shouldEqual("hello-mb")
        naming.makeName(&context).shouldEqual("hello-cb")
        naming.makeName(&context).shouldEqual("hello-pb")
        naming.makeName(&context).shouldEqual("hello-qb")
        naming.makeName(&context).shouldEqual("hello-xb")
        naming.makeName(&context).shouldEqual("hello-ob")
        naming.makeName(&context).shouldEqual("hello-tb")
        naming.makeName(&context).shouldEqual("hello-1b")
        naming.makeName(&context).shouldEqual("hello-ub")
        naming.makeName(&context).shouldEqual("hello-wb")
        naming.makeName(&context).shouldEqual("hello-ib")
        naming.makeName(&context).shouldEqual("hello-sb")
        naming.makeName(&context).shouldEqual("hello-zb")
        naming.makeName(&context).shouldEqual("hello-ab")
        naming.makeName(&context).shouldEqual("hello-3b")
        naming.makeName(&context).shouldEqual("hello-4b")
        naming.makeName(&context).shouldEqual("hello-5b")
        naming.makeName(&context).shouldEqual("hello-hb")
    }
}
