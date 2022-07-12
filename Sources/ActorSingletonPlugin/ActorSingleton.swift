//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActors
import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Settings

/// Settings for a `ActorSingleton`.
public struct ActorSingletonSettings {
    /// Unique name for the singleton
    public let name: String

    /// Capacity of temporary message buffer in case singleton is unavailable.
    /// If the buffer becomes full, the *oldest* messages would be disposed to make room for the newer messages.
    public var bufferCapacity: Int = 2048 {
        willSet(newValue) {
            precondition(newValue > 0, "bufferCapacity must be greater than 0")
        }
    }

    /// Controls allocation of the node on which the singleton runs.
    public var allocationStrategy: AllocationStrategySettings = .byLeadership

    public init(name: String) {
        self.name = name
    }
}

/// Singleton node allocation strategies.
public enum AllocationStrategySettings {
    /// Singletons will run on the cluster leader. *All* nodes are potential candidates.
    case byLeadership

    func make(_: ClusterSystemSettings, _: ActorSingletonSettings) -> ActorSingletonAllocationStrategy {
        switch self {
        case .byLeadership:
            return ActorSingletonAllocationByLeadership()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonRemoteCallInterceptor

struct ActorSingletonRemoteCallInterceptor<Singleton: DistributedActor>: RemoteCallInterceptor where Singleton.ActorSystem == ClusterSystem {
    let system: ClusterSystem
    let proxy: ActorSingletonProxy<Singleton>

    func interceptRemoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error,
        Res: Codable
    {
        // FIXME: better error handling
        guard actor is Singleton else {
            fatalError("Wrong interceptor")
        }

        // FIXME: can't capture inout param
        let invocation = invocation
        return try await self.proxy.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            try await __secretlyKnownToBeLocal.forwardOrStashRemoteCall(target: target, invocation: invocation, throwing: throwing, returning: returning)
        }! // FIXME: !-use
    }

    func interceptRemoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error
    {
        // FIXME: better error handling
        guard actor is Singleton else {
            fatalError("Wrong interceptor")
        }

        // FIXME: can't capture inout param
        let invocation = invocation
        try await self.proxy.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            try await __secretlyKnownToBeLocal.forwardOrStashRemoteCallVoid(target: target, invocation: invocation, throwing: throwing)
        }
    }
}
