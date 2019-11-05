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

import DistributedActors
import class NIO.EventLoopFuture

public protocol Parking: Actorable {
    func park()

    static func _boxParking(_ message: GeneratedActor.Messages.Parking) -> Self.Message
}

// TODO: allow not public
public protocol Ticketing: Actorable {
    func makeTicket()

    static func _boxTicketing(_ message: GeneratedActor.Messages.Ticketing) -> Self.Message
}

// TODO: take into account that type may not be public
public struct JackOfAllTrades: Ticketing, Parking, Actorable {

    let context: ActorContext<Message>

    public init(context: ActorContext<Message>) {
        self.context = context
    }

    public func hello(replyTo: ActorRef<String>) {
        context.log.info("hello")


        let ref: ActorRef<Message> = context.myself

        replyTo.tell("Hello")
    }

    public func makeTicket() {
        context.log.info("makeTicket")
    }

    public func park() {
        context.log.info("park")
    }
}
