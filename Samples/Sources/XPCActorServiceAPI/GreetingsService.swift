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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
// tag::xpc_example[]
import DistributedActors
import DistributedActorsXPC
import NIO

public protocol GreetingsService: XPCActorableProtocol {
    func logGreeting(name: String) throws
    func greet(name: String) throws -> String
    func fatalCrash()
    func greetDirect(who: ActorRef<String>) // can send many values to `who`

    func greetFuture(name: String) -> EventLoopFuture<String> // "leaking" that we use ELFs, but good that allows "async-return"

    /// Special static function needed to implement an Actorable protocol, for use only by generated code.
    static func _boxGreetingsService(_ message: GeneratedActor.Messages.GreetingsService) -> Self.Message
}

// end::xpc_example[]
#endif
