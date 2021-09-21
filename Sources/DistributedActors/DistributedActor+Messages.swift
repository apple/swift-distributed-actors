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

import _Distributed

// FIXME(distributed): we need to get rid of this all of this... probably means having to remove the entire Ref based infrastructure

/// `Void` equivalent but `Codable`.
public enum _Done: String, ActorMessage {
    case done
}

public protocol AnyDistributedClusterActor {
    static func _spawnAny(instance: Self, on system: ActorSystem) throws -> AddressableActorRef
}

/// Necessary to get `Message` out of the `DistributedActor`
public protocol DistributedClusterActor: AnyDistributedClusterActor {
    associatedtype Message: Codable // TODO: & Sendable

    static func makeBehavior(instance: Self) -> Behavior<Message>

    static func _spawn(instance: Self, on system: ActorSystem) -> ActorRef<Message>
}

extension DistributedClusterActor {

    // FIXME(distributed): this is not enough since we can't get the Message associated type protocol by casting...
    public static func _spawn(instance: Self, on system: ActorSystem) -> ActorRef<Message> {
        let behavior = makeBehavior(instance: instance)
        return try! system.spawn(.prefixed(with: "\(Self.self)"), behavior)
    }
}