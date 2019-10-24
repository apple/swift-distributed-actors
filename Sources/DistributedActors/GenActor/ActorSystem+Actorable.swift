//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension ActorSystem {
    public func spawn<A>(_ naming: ActorNaming, _: (A.Context) -> A) throws -> Actor<A>
        where A: Actorable {
        let ref = try self.spawn(naming, of: A.Message.self, .setup {
            A.makeBehavior(context: $0)
        })
        return Actor(ref: ref)
    }
}
