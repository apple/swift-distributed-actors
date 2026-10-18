//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActorsTestKit
import XCTest

@testable import DistributedCluster

private distributed actor Echo {
    typealias ActorSystem = ClusterSystem

    distributed func echo<Value: Codable>(_ value: Value) -> Value {
        value
    }
}

/// Passes each call on to `echo` as a local call without its generic substitutions or arguments,
/// which fails before the call reaches its result handler.
private struct DroppingArguments: RemoteCallInterceptor {
    let echo: Echo

    func interceptRemoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where
        Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error,
        Res: Codable
    {
        var empty = self.echo.actorSystem.makeInvocationEncoder()
        try empty.doneRecording()
        return try await self.echo.actorSystem.localCall(
            on: self.echo,
            target: target,
            invocation: &empty,
            throwing: throwing,
            returning: returning
        )
    }

    func interceptRemoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where
        Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error
    {
        fatalError("not used")
    }
}

final class LocalCallTests: ClusteredActorSystemsXCTestCase {
    func test_localCall_thatCantBeDecoded_throwsToTheCaller() async throws {
        let system = await setUpNode("local")
        let echo = Echo(actorSystem: system)
        let proxy: Echo = try system.interceptCalls(to: Echo.self, metadata: ActorMetadata(), interceptor: DroppingArguments(echo: echo))

        let error = try await shouldThrow {
            _ = try await proxy.echo("hello")
        }
        guard error is ExecuteDistributedTargetError else {
            throw TestError("Expected the decoding failure to be thrown to the caller, got: \(error)")
        }
    }
}
