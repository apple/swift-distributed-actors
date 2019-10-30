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

public protocol Actorable {
    associatedtype Message
    associatedtype ActorableContext = ActorContext<Message>

    static func makeBehavior(instance: Self) -> Behavior<Message>

    init(context: ActorableContext)
}

public struct Actor<A: Actorable> {
    public let ref: ActorRef<A.Message>

    public init(ref: ActorRef<A.Message>) {
        self.ref = ref
    }
}
