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
    associatedtype Context = ActorContext<Message>

    var context: ActorContext<Message> { get }

    static func makeBehavior(context: ActorContext<Message>) -> Behavior<Message>

    init(context: ActorContext<Self.Message>)
}

public struct Actor<Myself: Actorable> {
    public let ref: ActorRef<Myself.Message>

    public init(ref: ActorRef<Myself.Message>) {
        self.ref = ref
    }
}
