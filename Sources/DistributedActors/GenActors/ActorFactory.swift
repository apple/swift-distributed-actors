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

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorFactory

public protocol ActorFactory {
    /// Spawns an actor using an `Actorable`, that `GenActors` is able to generate methods and behaviors for.
    ///
    /// ### Generate Actors
    /// Use `swift run GenActors` to generate the necessary additional sources for your actorable.
    /// This invocation has to be done whenever messages (`@actor` annotated function *signatures*) that an actor handles are changed.
    ///
    /// ### Messaging
    /// The actor is immediately available to receive messages, which may be sent to it using function calls, which are turned into message-sends.
    /// The underlying `ActorRef<Message>` is available as `ref` on the returned actor, and allows passing the actor to `Behavior` style APIs.
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
    ///   - makeActorable: auto closure (!) which will be invoked when creating the actor.
    ///     DO NOT close over any mutable state in such closures as it could result in unexpected behavior if the actor were to be restarted (and thus, thus closure would be invoked again).
    /// - Returns: `Actor<Act>` reference for the spawned actor.
    /// - Throws: When `ActorNaming.unique` (or a string literal is passed in) is used and the given name is already used in this namespace.
    ///     This can happen when a parent actor attempts to spawn two actors of the same name, or the same situation happens on top-level actors.
    @discardableResult
    func spawn<Act>(
        _ naming: ActorNaming,
        props: Props,
        file: String, line: UInt,
        _ makeActorable: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act> where Act: Actorable

    /// Spawns an actor using an `Actorable`, that `GenActors` is able to generate methods and behaviors for.
    ///
    /// ### Generate Actors
    /// Use `swift run GenActors` to generate the necessary additional sources for your actorable.
    /// This invocation has to be done whenever messages (`@actor` annotated function *signatures*) that an actor handles are changed.
    ///
    /// ### Messaging
    /// The actor is immediately available to receive messages, which may be sent to it using function calls, which are turned into message-sends.
    /// The underlying `ActorRef<Message>` is available as `ref` on the returned actor, and allows passing the actor to `Behavior` style APIs.
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
    ///   - makeActorable: auto closure (!) which will be invoked when creating the actor.
    ///     DO NOT close over any mutable state in such closures as it could result in unexpected behavior if the actor were to be restarted (and thus, thus closure would be invoked again).
    /// - Returns: `Actor<Act>` reference for the spawned actor.
    /// - Throws: When `ActorNaming.unique` (or a string literal is passed in) is used and the given name is already used in this namespace.
    ///     This can happen when a parent actor attempts to spawn two actors of the same name, or the same situation happens on top-level actors.
    @discardableResult
    func spawn<Act>(
        _ naming: ActorNaming,
        props: Props,
        file: String, line: UInt,
        _ makeActorable: @autoclosure @escaping () -> Act
    ) throws -> Actor<Act> where Act: Actorable
}

extension ActorFactory {
    @discardableResult
    public func spawn<Act>(
        _ naming: ActorNaming,
        props: Props = .init(),
        file: String = #file, line: UInt = #line,
        _ makeActorable: @autoclosure @escaping () -> Act
    ) throws -> Actor<Act> where Act: Actorable {
        try self.spawn(naming, props: props, file: file, line: line) { _ in
            makeActorable()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ChildActorFactory

protocol ChildActorFactory: ActorFactory {
    /// Spawn a child actor and start watching it, entering a "death pact" with it.
    /// See `DeathWatch` to learn more about the concept of watching.
    ///
    /// - Warning: The way child actors are available today MAY CHANGE; See: https://github.com/apple/swift-distributed-actors/issues?q=is%3Aopen+is%3Aissue+label%3Aga%3Aactor-tree-removal
    ///
    /// - SeeAlso: `spawn`
    /// - SeeAlso: `watch`
    /// - SeeAlso: `DeathWatch`
    @discardableResult
    func spawnWatch<Act>(
        _ naming: ActorNaming,
        props: Props,
        file: String, line: UInt,
        _ makeActorable: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act> where Act: Actorable

    /// Spawn a child actor and start watching it to get notified about termination.
    /// See `DeathWatch` to learn more about the concept of watching.
    ///
    /// - Warning: The way child actors are available today MAY CHANGE; See: https://github.com/apple/swift-distributed-actors/issues?q=is%3Aopen+is%3Aissue+label%3Aga%3Aactor-tree-removal
    ///
    /// - SeeAlso: `spawn`
    /// - SeeAlso: `watch`
    /// - SeeAlso: `DeathWatch`
    @discardableResult
    func spawnWatch<Act>(
        _ naming: ActorNaming,
        props: Props,
        file: String, line: UInt,
        _ makeActorable: @autoclosure @escaping () -> Act
    ) throws -> Actor<Act> where Act: Actorable
}

extension ChildActorFactory {
    @discardableResult
    public func spawnWatch<Act>(
        _ naming: ActorNaming,
        props: Props = .init(),
        file: String = #file, line: UInt = #line,
        _ makeActorable: @autoclosure @escaping () -> Act
    ) throws -> Actor<Act> where Act: Actorable {
        try self.spawnWatch(naming, props: props, file: file, line: line) { _ in makeActorable() }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSystem + ActorFactory

extension ActorSystem: ActorFactory {
    @discardableResult
    public func spawn<Act>(
        _ naming: ActorNaming,
        props: Props = Props(),
        file: String = #file, line: UInt = #line,
        _ makeActorable: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act> where Act: Actorable {
        let behavior = Behavior<Act.Message>.setup { context in
            Act.makeBehavior(instance: makeActorable(.init(underlying: context)))
        }

        let ref = try self.spawn(
            naming,
            of: Act.Message.self,
            props: props,
            file: file, line: line,
            behavior
        )
        return Actor(ref: ref)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor.Context + ActorFactory

extension Actor.Context: ChildActorFactory {
    @discardableResult
    public func spawn<Act>(
        _ naming: ActorNaming,
        props: Props = .init(),
        file: String = #file, line: UInt = #line,
        _ makeActorable: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act> where Act: Actorable {
        try self._underlying.spawn(naming, props: props, file: file, line: line) { context in makeActorable(context) }
    }

    @discardableResult
    func spawnWatch<Act>(
        _ naming: ActorNaming,
        props: Props,
        file: String, line: UInt,
        _ makeActorable: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act> where Act: Actorable {
        try self._underlying.spawnWatch(naming, props: props, file: file, line: line) { context in makeActorable(context) }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorContext + ActorFactory

extension ActorContext: ChildActorFactory {
    @discardableResult
    public func spawn<Act>(
        _ naming: ActorNaming,
        props: Props = .init(),
        file: String = #file, line: UInt = #line,
        _ makeActorable: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act>
        where Act: Actorable {
        let behavior = Behavior<Act.Message>.setup { behaviorContext in
            let actorableContext = Actor<Act>.Context(underlying: behaviorContext)
            return Act.makeBehavior(instance: makeActorable(actorableContext))
        }
        let ref = try self.spawn(naming, of: Act.Message.self, props: props, file: file, line: line, behavior)
        return Actor<Act>(ref: ref)
    }

    @discardableResult
    func spawnWatch<Act>(
        _ naming: ActorNaming,
        props: Props,
        file: String, line: UInt,
        _ makeActorable: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act> where Act: Actorable {
        let actor = try self.spawn(naming, props: props, file: file, line: line) { context in makeActorable(context) }
        self.watch(actor.ref)
        return actor
    }
}
