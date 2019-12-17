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
import XPCActorable
import NIO

public protocol GreetingsServiceProtocol: XPCActorableProtocol {

    func logGreeting(name: String) throws
    func greet(name: String) throws -> String
    func fatalCrash()
    func greetDirect(who: ActorRef<String>) // can send many values to `who`

    func greetFuture(name: String) -> EventLoopFuture<String> // "leaking" that we use ELFs, but good that allows "async-return"

    static func _boxGreetingsServiceProtocol(_ message: GeneratedActor.Messages.GreetingsServiceProtocol) -> Self.Message
}
