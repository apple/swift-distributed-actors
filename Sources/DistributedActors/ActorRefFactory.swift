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

import Dispatch
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorRefFactory

/// Public but not intended for user-extension.
///
/// An `ActorRefFactory` is able to create ("spawn") new actors and return `ActorRef` instances for them.
/// Only the `ActorSystem`, `ActorContext` and potentially testing facilities can ever expose this ability.
public protocol ActorRefFactory {
    /// Spawn an actor with the given `name`, optional `props` and `behavior`.
    ///
    /// ### Naming
    /// `ActorNaming` is used to determine the actors real name upon spawning;
    /// A name can be sequentially (or otherwise) assigned based on the owning naming context (i.e. `ActorContext` or `ActorSystem`).
    ///
    /// ### Actor Reference
    /// Discarding the returned reference means that there MAY be no longer a way to communicate with the spawned actor.
    /// Keep this in mind and only discard references if the actor is performing asks like periodically scheduling some work,
    /// or can be discovered using other means (e.g. it registers itself with the `SystemReceptionist` on setup).
    ///
    /// ### Lifecycle
    /// Actors remain alive until they are explicitly stopped (or crash).
    /// They are NOT using ref-counting as a means of lifecycle control, and losing references to it does not imply that the actor will be stopped.
    ///
    /// - Parameters:
    ///   - naming: determines the name of the spawned actor.
    ///     Passing a string literal is the same as using an *unique* actor naming strategy, and may cause throws if the name is already used.
    ///     See also `ActorNaming` on details on other naming strategies (such as `.anonymous`).
    ///   - props: props held by this actor. Allow configuring details about failure handling and execution semantics of this actor.
    ///   - behavior: the `Behavior` of the actor to be spawned.
    /// - Returns: `ActorRef` for the spawned actor.
    /// - Throws: When `ActorNaming.unique` (or a string literal is passed in) is used and the given name is already used in this namespace.
    ///     This can happen when a parent actor attempts to spawn two actors of the same name, or the same situation happens on top-level actors.
    @discardableResult
    func spawn<Message>(
        _ naming: ActorNaming,
        of type: Message.Type,
        props: Props,
        file: String, line: UInt,
        _ behavior: Behavior<Message>
    ) throws -> ActorRef<Message> where Message: ActorMessage
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ChildActorRefFactory

public protocol ChildActorRefFactory: ActorRefFactory {
    var children: Children { get set } // lock-protected

    func stop<Message>(child ref: ActorRef<Message>) throws
        where Message: ActorMessage
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor.Context + ActorFactory

extension Actor.Context: ChildActorRefFactory {
    public var children: Children {
        get {
            self._underlying.children
        }
        set {
            self._underlying.children = newValue
        }
    }

    public func stop<Message>(child ref: ActorRef<Message>) throws where Message: Codable {
        try self._underlying.stop(child: ref)
    }

    @discardableResult
    public func spawn<Message>(
        _ naming: ActorNaming,
        of type: Message.Type,
        props: Props = Props(),
        file: String = #file, line: UInt = #line,
        _ behavior: Behavior<Message>
    ) throws -> ActorRef<Message> where Message: Codable {
        try self.spawn(naming, of: type, props: props, file: file, line: line, behavior)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorContext + ActorFactory

extension ActorContext: ChildActorRefFactory {
    // implementation is in ActorShell, since it has to be because the shell is a subclass of the context
}
