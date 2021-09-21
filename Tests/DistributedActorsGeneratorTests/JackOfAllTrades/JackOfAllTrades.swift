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
import _Distributed
import Logging
import class NIO.EventLoopFuture

public protocol Parking {
    func park() async throws
}

public protocol Ticketing {
    func makeTicket() async throws
}

public distributed actor JackOfAllTrades: Ticketing, Parking {

    lazy var log = Logger(actor: self)

    public distributed func hello(replyTo: ActorRef<String>) {
        log.info("hello")
        replyTo.tell("Hello")
    }

    public distributed func makeTicket() {
        log.info("makeTicket")
    }

    public distributed func park() {
        log.info("park")
    }
}
