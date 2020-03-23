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

extension AwaitingActorable.Message: NotTransportableActorMessage {}

public struct AwaitingActorable: Actorable {
    let context: Myself.Context

    // don't generate Codable messages since we do a few Future-passing APIs here to test specific behaviors / context capabilities
    public static var generateCodableConformance: Bool {
        false
    }

    func awaitOnAFuture(f: EventLoopFuture<String>, replyTo: ActorRef<Result<String, Error>>) -> Behavior<Myself.Message> {
        return context.awaitResult(of: f, timeout: .effectivelyInfinite) {
            replyTo.tell($0)
        }
    }

    func onResultAsyncExample(f: EventLoopFuture<String>, replyTo: ActorRef<Result<String, Error>>) {
        context.onResultAsync(of: f, timeout: .effectivelyInfinite) {
            replyTo.tell($0)
        }
    }
}

// should not accidentally try to make this actorable
public struct ExampleModel {
    public struct ExampleData {}
}
