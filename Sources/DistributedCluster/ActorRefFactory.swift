//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ActorRefFactory

/// Public but not intended for user-extension.
///
/// An `_ActorRefFactory` is able to create ("spawn") new actors and return `_ActorRef` instances for them.
/// Only the `ClusterSystem`, `_ActorContext` and potentially testing facilities can ever expose this ability.
public protocol _ActorRefFactory {
    /// Spawn an actor with the given `name`, optional `props` and `behavior`.
    ///
    /// ### Naming
    /// `_ActorNaming` is used to determine the actors real name upon spawning;
    /// A name can be sequentially (or otherwise) assigned based on the owning naming context (i.e. `_ActorContext` or `ClusterSystem`).
    ///
    /// ### Actor Reference
    /// Discarding the returned reference means that there MAY be no longer a way to communicate with the spawned actor.
    /// Keep this in mind and only discard references if the actor is performing asks like periodically scheduling some work,
    /// or can be discovered using other means.
    ///
    /// ### Lifecycle
    /// Actors remain alive until they are explicitly stopped (or crash).
    /// They are NOT using ref-counting as a means of lifecycle control, and losing references to it does not imply that the actor will be stopped.
    ///
    /// - Parameters:
    ///   - naming: determines the name of the spawned actor.
    ///     Passing a string literal is the same as using an *unique* actor naming strategy, and may cause throws if the name is already used.
    ///     See also `_ActorNaming` on details on other naming strategies (such as `.anonymous`).
    ///   - props: props held by this actor. Allow configuring details about failure handling and execution semantics of this actor.
    ///   - behavior: the `_Behavior` of the actor to be spawned.
    /// - Returns: `_ActorRef` for the spawned actor.
    /// - Throws: When `_ActorNaming.unique` (or a string literal is passed in) is used and the given name is already used in this namespace.
    ///     This can happen when a parent actor attempts to spawn two actors of the same name, or the same situation happens on top-level actors.
    @discardableResult
    func _spawn<Message>(
        _ naming: _ActorNaming,
        of type: Message.Type,
        props: _Props,
        file: String,
        line: UInt,
        _ behavior: _Behavior<Message>
    ) throws -> _ActorRef<Message> where Message: Codable
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ChildActorRefFactory

public protocol _ChildActorRefFactory: _ActorRefFactory {
    var children: _Children { get set }  // lock-protected

    func stop<Message>(child ref: _ActorRef<Message>) throws
    where Message: Codable
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ActorContext + ActorFactory

extension _ActorContext: _ChildActorRefFactory {
    // implementation is in _ActorShell, since it has to be because the shell is a subclass of the context
}
