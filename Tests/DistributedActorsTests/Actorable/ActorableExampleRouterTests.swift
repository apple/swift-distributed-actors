//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tests

final class ActorableExampleRouterTests: ActorSystemXCTestCase {
    func test_actorRouter_viaReceptionist_shouldWork() throws {
        let router: Actor<MessageActorReceptionistRouter> = try system.spawn("ref-router") { _ in
            MessageActorReceptionistRouter()
        }

        try system.spawn("one") { BarRefTarget(context: $0, router: Actor(ref: self.system.deadLetters.adapted())) }
        try system.spawn("two") { BarRefTarget(context: $0, router: Actor(ref: self.system.deadLetters.adapted())) }

        let p = testKit.spawnTestProbe(expecting: String.self)

        router.dispatchMessage("one", message: .foo, replyTo: p.ref)
        router.dispatchMessage("one", message: .bar, replyTo: p.ref)
        router.dispatchMessage("two", message: .foo, replyTo: p.ref)
        router.dispatchMessage("two", message: .bar, replyTo: p.ref)

        try p.expectMessagesInAnyOrder([
            "one: foo",
            "one: bar",
            "two: foo",
            "two: bar",
        ], within: .seconds(5))
    }

    func test_refRouter_shouldWork() throws {
        let refRouter: Actor<MessageRefRouter> = try system.spawn("ref-router") { _ in
            MessageRefRouter()
        }

        try system.spawn("one") { BarRefTarget(context: $0, router: refRouter) }
        try system.spawn("two") { FooRefTarget(context: $0, router: refRouter) }

        let p = testKit.spawnTestProbe(expecting: String.self)

        refRouter.dispatchMessage("one", message: .foo, replyTo: p.ref)
        refRouter.dispatchMessage("one", message: .bar, replyTo: p.ref)
        refRouter.dispatchMessage("two", message: .foo, replyTo: p.ref)
        refRouter.dispatchMessage("two", message: .bar, replyTo: p.ref)

        try p.expectMessagesInAnyOrder([
            "one: foo",
            "one: bar",
            "two: foo",
            "two: bar",
        ])
    }

    func test_actorRouter_shouldWork() throws {
        let router: Actor<MessageRouter> = try system.spawn("ref-router") { _ in
            MessageRouter()
        }

        try system.spawn("one") { BarActorTarget(context: $0, router: router) }
        try system.spawn("two") { FooActorTarget(context: $0, router: router) }

        let p = testKit.spawnTestProbe(expecting: String.self)

        router.dispatchMessage("one", message: .foo, replyTo: p.ref)
        router.dispatchMessage("one", message: .bar, replyTo: p.ref)
        router.dispatchMessage("two", message: .foo, replyTo: p.ref)
        router.dispatchMessage("two", message: .bar, replyTo: p.ref)

        try p.expectMessagesInAnyOrder([
            "one: foo",
            "one: bar",
            "two: foo",
            "two: bar",
        ])
    }
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Impls


public enum MessageType: String, Codable {
    case foo
    case bar
}

public protocol MessageTarget: Actorable {
    // @actor
    func handleMessage(_ message: MessageType, replyTo: ActorRef<String>)

    static func _boxMessageTarget(_ message: GeneratedActor.Messages.MessageTarget) -> Self.Message
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Impls: routers

private let key: Reception.Key<ActorRef<GeneratedActor.Messages.MessageTarget>> = "*"

final class MessageActorReceptionistRouter: Actorable {

    var listing: ActorableOwned<Reception.Listing<ActorRef<GeneratedActor.Messages.MessageTarget>>>!

    var buffer: [(String, MessageType, ActorRef<String>)] = []

    /* @actor */
    func preStart(context: Myself.Context) {
        self.listing = context.receptionist.autoUpdatedListing(key)

        self.listing.onUpdate { l in
            let buffered = self.buffer
            self.buffer = []

            buffered.forEach { identifier, message, replyTo in
                self.dispatchMessage(identifier, message: message, replyTo: replyTo)
            }
        }
    }

    /* @actor */
    func dispatchMessage(_ identifier: String, message: MessageType, replyTo: ActorRef<String>) {
        guard let listing = self.listing.lastObservedValue else {
            self.buffer.append((identifier, message, replyTo))
            return
        }

        if let target = listing.first(named: identifier) {
            target.tell(.handleMessage(message, replyTo: replyTo))
        } else {
            self.buffer.append((identifier, message, replyTo))
        }
    }
}


final class MessageRefRouter: Actorable {
    var targets: [String: ActorRef<GeneratedActor.Messages.MessageTarget>] = [:]

    /* @actor */
    func registerTarget(_ identifier: String, actor ref: ActorRef<GeneratedActor.Messages.MessageTarget>) {
        targets[identifier] = ref
    }

    /* @actor */
    func dispatchMessage(_ identifier: String, message: MessageType, replyTo: ActorRef<String>) {
        if let target = targets[identifier] {
            target.tell(.handleMessage(message, replyTo: replyTo))
        } else {
            // do some error handling
        }
    }
}

final class MessageRouter: Actorable {
    // Map of target identifier to Actor
    var targets: [String: AnyActor.MessageTarget]

    init() {
        self.targets = [:]
    }

    // Invoked by actors to register as targets
    /* @actor */
    func registerTarget(_ identifier: String, actor: AnyActor.MessageTarget) {
        targets[identifier] = actor
    }

    // Invoked by some other component receiving messages from an external
    /* @actor */
    func dispatchMessage(_ identifier: String, message: MessageType, replyTo: ActorRef<String>) {
        if let target = targets[identifier] {
            target.handleMessage(message, replyTo: replyTo)
        } else {
            // do some error handling
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Impls: targets

struct BarRefTarget: Actorable, MessageTarget {
    let context: Myself.Context
    let router: Actor<MessageRefRouter>

    init(context: Myself.Context, router: Actor<MessageRefRouter>) {
        self.context = context
        self.router = router
    }

    // @actor
    func preStart(context: Myself.Context) {
        router.registerTarget(
            self.context.name,
            actor: context._underlying.messageAdapter {
                Self._boxMessageTarget($0)
            }
        )

        // also register with receptionist
        context.receptionist.register(context._underlying.messageAdapter {
            Self._boxMessageTarget($0)
        }, as: "*")
    }

    // @actor
    func handleMessage(_ message: MessageType, replyTo: ActorRef<String>) {
        replyTo.tell("\(self.context.name): \(message)")
    }
}

struct FooRefTarget: Actorable, MessageTarget {
    let context: Myself.Context
    let router: Actor<MessageRefRouter>

    init(context: Myself.Context, router: Actor<MessageRefRouter>) {
        self.context = context
        self.router = router
    }

    // @actor
    func preStart(context: Myself.Context) {
        router.registerTarget(
            self.context.name,
            actor: context._underlying.messageAdapter {
                Self._boxMessageTarget($0)
            }
        )

        // also register with receptionist
        context.receptionist.register(context._underlying.messageAdapter {
            Self._boxMessageTarget($0)
        }, as: "*")
    }

    // @actor
    func handleMessage(_ message: MessageType, replyTo: ActorRef<String>) {
        replyTo.tell("\(self.context.name): \(message)")
    }
}

struct BarActorTarget: Actorable, MessageTarget {
    let context: Myself.Context
    let router: Actor<MessageRouter>

    init(context: Myself.Context, router: Actor<MessageRouter>) {
        self.context = context
        self.router = router
    }

    // @actor
    func preStart(context: Myself.Context) {
        router.registerTarget(
            self.context.name,
            actor: context.asAnyMessageTarget
        )

        // also register with receptionist
        let key = context.receptionist.register(context.myself.ref, as: "*")
        pprint("key = \(key)")
    }

    // @actor
    func handleMessage(_ message: MessageType, replyTo: ActorRef<String>) {
        replyTo.tell("\(self.context.name): \(message)")
    }
}

struct FooActorTarget: Actorable, MessageTarget {
    let context: Myself.Context
    let router: Actor<MessageRouter>

    init(context: Myself.Context, router: Actor<MessageRouter>) {
        self.context = context
        self.router = router
    }

    // @actor
    func preStart(context: Myself.Context) {
        router.registerTarget(
            self.context.name,
            actor: context.asAnyMessageTarget
        )

        // also register with receptionist
        context.receptionist.register(context.myself.ref, as: "*")
    }

    // @actor
    func handleMessage(_ message: MessageType, replyTo: ActorRef<String>) {
        replyTo.tell("\(self.context.name): \(message)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: What would need to be generated for Any...-able Actorable Protocols

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AnyActor

/// Namespace for `Any...Actor` type erasers, enabling accepting *any* actor that conforms to a specific actorable protocol
/// and still being able to send it around as a normal location transparent `Actor` reference.
///
/// This namespace is populated automatically by GenActors when generating proxies for `Actorable`s.
public enum AnyActor {
}

extension AnyActor {
    public typealias MessageTarget = AnyMessageTargetActor
}

public protocol MessageTargetActorProtocol {
    // @actor
    func handleMessage(_ message: MessageType, replyTo: ActorRef<String>)
}

extension Actor.Context where Act: MessageTarget {
    /// Returns type-erased `Any...Actor` type which allows for using this reference without
    /// specifying which actual actor is implementing it, and using it in actor messages.
    public var asAnyMessageTarget: AnyMessageTargetActor {
        .init(self)
    }
}

/// Type erasure for Actor<any MessageTarget> types which is not expressible in today's Swift
///
/// Convenience typealias is provided in `AnyActor` as `AnyActor.MessageTarget`.
public struct AnyMessageTargetActor: MessageTargetActorProtocol, DeathWatchable, Codable {
    public typealias Ref = ActorRef<GeneratedActor.Messages.MessageTarget>

    public let ref: Ref
    public var asAddressable: AddressableActorRef {
        self.ref.asAddressable
    }

    public init<Act>(_ context: Actor<Act>.Context) where Act: MessageTarget {
        self.ref = context._underlying.messageAdapter { message in
            Act._boxMessageTarget(message)
        }
    }

    @inlinable
    public func handleMessage(_ message: MessageType, replyTo: ActorRef<String>) {
        self.ref.tell(.handleMessage(message, replyTo: replyTo))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Coding

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.ref = try container.decode(Ref.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.ref)
    }
}

extension Actor: MessageTargetActorProtocol where Act: MessageTarget {
}

