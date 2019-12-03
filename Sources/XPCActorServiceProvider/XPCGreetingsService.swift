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
import Files
import XPCActorServiceAPI

public struct XPCGreetingsService: GreetingsServiceProtocol, Actorable {

    let file = try! Folder(path: "/tmp").file(named: "xpc.txt")

    // TODO: allow for manually writing the Message enum, for fine control over what to expose as messages?

    let context: Myself.Context

    public func preStart(context: Myself.Context) {
        try! self.file.append("\(context.address.path) started.\n")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor message handlers


    public func logGreeting(name: String) throws {
        try file.append("[actor service:\(self.context.system.name)][\(self.context.path)] Received .greet(\(name))\n")
    }

    public func greet(name: String) throws -> String {
        try file.append("[actor service:\(self.context.system.name)][\(self.context.path)] Received .greet(\(name))\n")
        return "Greetings, \(name)!"
    }

    public func fatalCrash() {
        try! file.append("[actor service:\(self.context.system.name)][\(self.context.path)] Received .fatalCrash\n")
        fatalError("Boom, crashing hard!")
    }

}
