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
import XPCActorServiceAPI

public struct GreetingsServiceImpl: GreetingsServiceProtocol, Actorable {

    // TODO: allow for manually writing the Message enum, for fine control over what to expose as messages?

    let context: Myself.Context

    public func preStart(context: Myself.Context) {
        context.log.info("\(context.address.path) started.")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor message handlers


    public func logGreeting(name: String) throws {
        self.context.log.info("[actor service:\(self.context.system.name)][\(self.context.path)] Received .greet(\(name))")
    }

    public func greet(name: String) throws -> String {
        self.context.log.info("[actor service:\(self.context.system.name)][\(self.context.path)] Received .greet(\(name))")
        return "Greetings, \(name)!"
    }

    public func fatalCrash() {
        self.context.log.info("[actor service:\(self.context.system.name)][\(self.context.path)] Received .fatalCrash")
        fatalError("Boom, crashing hard!")
    }

}
