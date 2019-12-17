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

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Transport Settings

/// Internal protocol allowing for introduction of additional transports.
public class ActorTransport {
    var `protocol`: String {
        fatalError("Not implemented: \(#function) in \(self) transport!")
    }

    func onActorSystemStart(system: ActorSystem) {
        // do nothing by default
    }

    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        fatalError("Not implemented: \(#function) in \(self) transport!")
    }

    func makeCellDelegate<Message>(system: ActorSystem, address: ActorAddress) throws -> CellDelegate<Message> {
        fatalError("Not implemented: \(#function) in \(self) transport!")
    }

}
