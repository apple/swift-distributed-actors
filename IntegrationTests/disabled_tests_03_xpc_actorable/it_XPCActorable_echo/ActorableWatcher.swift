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
import DistributedActorsXPC
import Foundation
import it_XPCActorable_echo_api

struct ActorableWatcher: Actorable {
    let context: Myself.Context
    let service: Actor<XPCEchoServiceProtocolStub>

    init(context: Myself.Context, service: Actor<XPCEchoServiceProtocolStub>) {
        self.context = context
        self.service = service

        context.watch(service)
    }

    /* @actor */ func noop() {
        // do nothing
    }

    /* @actor */ func receiveTerminated(context: Myself.Context, terminated: Signals.Terminated) -> DeathPactDirective {
        context.log.info("Received \(#function): \(terminated)")
        return .stop
    }

    // TODO: require that if those are present they should be actor marked
    /* @actor */ func receiveSignal(context: Myself.Context, signal: Signal) {
        context.log.info("Received \(#function): \(signal)")
        exit(0)
    }
}
