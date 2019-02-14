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

import DistributedActorsConcurrencyHelpers
import CSwiftDistributedActorsMailbox
import Dispatch

/// An `ActorSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ActorSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
///
/// An `ActorSystem` and all of the actors contained within remain alive until the `terminate` call is made.
public final class ActorSystem {
    // TODO: think about if we need ActorSystem to IS-A ActorRef; in Typed we did so, but it complicated the understanding of it to users...
    // it has upsides though, it is then possible to expose additional async APIs on it, without doing any weird things
    // creating an actor them becomes much simpler; it becomes an `ask` and we can avoid locks then (!)

    public let name: String

    // Implementation note:
    // First thing we need to start is the event stream, since is is what powers our logging infrastructure // TODO: ;-)
    // so without it we could not log anything.
    let eventStream = "" // FIXME actual implementation

    @usableFromInline let deadLetters: ActorRef<DeadLetter>

    /// Impl note: Atomic since we are being called from outside actors here (or MAY be), thus we need to synchronize access
    internal let anonymousNames = AtomicAnonymousNamesGenerator(prefix: "$") // TODO: make the $ a constant TODO: where

    private let dispatcher: InternalMessageDispatcher

    // Note: This differs from Akka, we do full separate trees here
    private let systemProvider: ActorRefProvider // TODO maybe we don't need this?
    private let userProvider: ActorRefProvider // TODO maybe we don't need this?

    private let _theOneWhoWalksTheBubblesOfSpaceTime: ReceivesSystemMessages

    private let terminationLock = Lock()

    /// Allows inspecting settings that were used to configure this actor system.
    /// Settings are immutable and may not be changed once the system is running.
    // TODO: We currently do not allow configuring it at all, which is fine for now.
    public let settings: ActorSystemSettings = ActorSystemSettings()

    public let serialization: Serialization

//  // TODO: provider is what abstracts being able to fabricate remote or local actor refs
//  // Implementation note:
//  // We MAY be able to get rid of this (!), I think in Akka it causes some indirections which we may not really need... we'll see
//  private let provider =

    // FIXME should link to the logging infra rather than be ad hoc (init will be tricky, chicken-and-egg ;-))
    // TODO: lazy var is unsafe here
    public lazy var log: Logger = ActorLogger.make(system: self)

    #if SACT_TESTS_LEAKS
    let cellInitCounter: Atomic<Int> = Atomic<Int>(value: 0)
    #endif

    /// Creates a named ActorSystem; The name is useful for debugging cross system communication
    public init(_ name: String, configuredWith configureSettings: (inout ActorSystemSettings) -> Void = { _ in () }) {
        self.name = name

        var settings = ActorSystemSettings()
        configureSettings(&settings)

        // TODO would we be able to without mutating theOne make it traversable? This way we could use it as traversable for Serialization()
        self._theOneWhoWalksTheBubblesOfSpaceTime = TheOneWhoHasNoParentActorRef()
        let theOne = self._theOneWhoWalksTheBubblesOfSpaceTime
        let userGuardian = Guardian(parent: theOne, name: "user")
        let systemGuardian = Guardian(parent: theOne, name: "system")

        let userProvider = LocalActorRefProvider(root: userGuardian)
        self.userProvider = userProvider
        let systemProvider = LocalActorRefProvider(root: systemGuardian)
        self.systemProvider = systemProvider

        // dead letters init
        // TODO actually attach dead letters to a parent?
        let deadLettersPath = try! ActorPath(root: "system") / ActorPathSegment("deadLetters") // TODO actually make child of system
        let deadLog = Logging.make(deadLettersPath.description)
        self.deadLetters = DeadLettersActorRef(deadLog, path: deadLettersPath.makeUnique(uid: .opaque))

        self.dispatcher = try! FixedThreadPool(settings.threadPoolSize)

        let traversable = CompositeActorTreeTraversable(systemTree: systemProvider, userTree: userProvider)
        self.serialization = Serialization(settings: settings.serialization, deadLetters: deadLetters, traversable: traversable)

        do {
            try FaultHandling.installCrashHandling()
        } catch {
            CSwift Distributed ActorsMailbox.sact_dump_backtrace()
            fatalError("Unable to install crash handling signal handler. Terminating. Error was: \(error)")
        }
    }

    public convenience init() {
        self.init("ActorSystem")
    }


    // FIXME: make termination async and add an awaitable that signals completion of the termination

    /// Forcefully stops this actor system and all actors that live within.
    ///
    /// - Warning: Blocks current thread until the system has terminated.
    ///            Do not call from within actors or you may deadlock shutting down the system.
    public func terminate() {
        self.log.log(level: .warning, message: "TERMINATING ACTOR SYSTEM [\(self.name)]. All actors will be stopped.", file: #file, function: #function, line: #line)
        self.userProvider.stopAll()
        self.systemProvider.stopAll()
        self.dispatcher.shutdown()
    }
}

/// Public but not intended for user-extension.
///
/// An `ActorRefFactory` is able to create ("spawn") new actors and return `ActorRef` instances for them.
/// Only the `ActorSystem`, `ActorContext` and potentially testing facilities can ever expose this ability.
public protocol ActorRefFactory {

    /// Spawn an actor with the given behavior name and props.
    ///
    /// Returns: `ActorRef` for the spawned actor.
    func spawn<Message>(_ behavior: Behavior<Message>, name: String, props: Props) throws -> ActorRef<Message>
}

// MARK: Actor creation

extension ActorSystem: ActorRefFactory {

    /// Spawn a new top-level Actor with the given initial behavior and name.
    ///
    /// - throws: when the passed behavior is not a legal initial behavior
    /// - throws: when the passed actor name contains illegal characters (e.g. symbols other than "-" or "_")
    public func spawn<Message>(_ behavior: Behavior<Message>, name: String, props: Props = Props()) throws -> ActorRef<Message> {
        guard !name.starts(with: "$") else {
            // only system and anonymous actors are allowed have names beginning with "$"
            throw ActorPathError.illegalLeadingSpecialCharacter(name: name, illegal: "$")
        }

        return try self.spawnInternal(behavior, name: name, props: props)
    }

    // Actual spawn implementation, minus the leading "$" check on names;
    // spawnInternal is used by spawnAnonymous and others, which are privileged and may start with "$"
    private func spawnInternal<Message>(_ behavior: Behavior<Message>, name: String, props: Props = Props()) throws -> ActorRef<Message> {
        try behavior.validateAsInitial()

        let path = try self.userProvider.rootPath.makeChildPath(name: name, uid: .random())
        // TODO: reserve the name, atomically

        let dispatcher: MessageDispatcher
        switch props.dispatcher {
        case .default: dispatcher = self.dispatcher
        case .callingThread: dispatcher = CallingThreadDispatcher()
        default: fatalError("not implemented yet, only default dispatcher and calling thread one work")
        }

        let refWithCell: ActorRef<Message> = try userProvider.spawn(
            system: self,
            behavior: behavior, path: path,
            dispatcher: dispatcher, props: props
        )

        return refWithCell
    }

    // TODO _systemSpawn: for spawning under the system one

    public func spawn<Message>(_ behavior: ActorBehavior<Message>, name: String, props: Props = Props()) throws -> ActorRef<Message> {
        return try spawn(.custom(behavior: behavior), name: name, props: props)
    }

    // Implementation note:
    // It is important to have the anonymous one have a "long discouraging name", we want actors to be well named,
    // and developers should only opt into anonymous ones when they are aware that they do so and indeed that's what they want.
    // This is why there should not be default parameter values for actor names
    public func spawnAnonymous<Message>(_ behavior: Behavior<Message>, props: Props = Props()) throws -> ActorRef<Message> {
        return try spawnInternal(behavior, name: self.anonymousNames.nextName(), props: props)
    }

    public func spawnAnonymous<Message>(_ behavior: ActorBehavior<Message>, props: Props = Props()) throws -> ActorRef<Message> {
        return try spawnAnonymous(.custom(behavior: behavior), props: props)
    }
}

// MARK: Internal actor tree traversal utilities

extension ActorSystem: ActorTreeTraversable {

    /// Prints Actor hierarchy as a "tree".
    ///
    /// Note that the printout is NOT a "snapshot" of a systems state, and therefore may print actors which by the time
    /// the print completes already have terminated, or may not print actors which started just after a visit at certain parent.
    internal func _printTree() {
        self._traverseAllVoid { context, ref in
            print("\(String(repeating: "  ", count: context.depth))- /\(ref.path.name) - \(ref)")
            return .continue
        }
    }

    internal func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        let systemTraversed: TraversalResult<T> = self.systemProvider._traverse(context: context, visit)

        switch systemTraversed {
        case .completed:
            return self.userProvider._traverse(context: context, visit)

        case .result(let t):
            var c = context
            c.accumulated.append(t)
            return self.userProvider._traverse(context: c, visit)
        case .results(let ts):
            var c = context
            c.accumulated.append(contentsOf: ts)
            return self.userProvider._traverse(context: c, visit)

        case .failed(let err):
            return .failed(err) // short circuit
        }
    }


    internal func _traverseAll<T>(_ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        let context = TraversalContext<T>()
        return self._traverse(context: context, visit)
    }

    @discardableResult
    internal func _traverseAllVoid(_ visit: (TraversalContext<Void>, AnyAddressableActorRef) -> TraversalDirective<Void>) -> TraversalResult<Void> {
        return self._traverseAll(visit)
    }


    func _resolve(context: ResolveContext, uid: ActorUID) -> AnyAddressableActorRef? {
        guard let selector = context.selectorSegments.first else {
            return nil
        }
        switch selector.value {
        case "system": return self.systemProvider._resolve(context: context.deeper, uid: uid)
        case "user": return self.userProvider._resolve(context: context.deeper, uid: uid)
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

}
