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
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _Props

/// `_Props` configure an Actors' properties such as mailbox, dispatcher as well as supervision semantics.
///
/// `_Props` can be easily changed in-line using the fluent APIs provided.
/// Functions starting with `add...` are additive, i.e. they add another setting of the same kind to the props (possibly
/// overriding a previously existing one), while functions starting with `with...` are replacement functions, always
/// replacing the entire inner props with the new one
///
/// Naming mnemonic: "_Props" are what a theater actor may use during a performance.
/// For example, a skull would be a classic example of a "prop" used while performing the William Shakespeare's
/// Hamlet Act III, scene 1, saying "To be, or not to be, that is the question: [...]." In the same sense,
/// props for Swift Distributed Actors are accompanying objects/settings, which help the actor perform its duties.
public struct _Props: @unchecked Sendable {
    internal var dispatcher: _DispatcherProps = .default

    // _Supervision properties will be removed.
    // This type of "parent/child" supervision and the entire actor tree will be removed.
    // Instead we will rely exclusively on watching other actors explicitly.
    internal var supervision: _SupervisionProps = .default

    /// Tags to be passed to the actor's identity.
    internal var metadata: ActorMetadata

    public var metrics: MetricsProps

    /// INTERNAL API: Allows spawning a "well known" actor. Use with great care,
    /// only if a single incarnation of actor will ever exist under the given path.
    internal var _wellKnown: Bool = false

    /// Sets the ``ActorMetadataKeys/wellKnown`` key to this name during spawning.
    internal var _wellKnownName: String? {
        get {
            self.metadata.wellKnown
        }
        set {
            self._wellKnown = newValue != nil
            self.metadata.wellKnown = newValue
        }
    }

    /// INTERNAL API: Internal system actor, spawned under the /system namespace.
    /// This is likely to go away as we remove the actor tree, and move completely to 'distributed actor'.
    internal var _systemActor: Bool = false

    /// INTERNAL API: Allows to request the actor system to spawn this actor under a specific name
    /// Used only with 'distributed actor' as a way to pass path to the `assignIdentity` call.
    /// // TODO(distributed): We should instead allow for an explicit way to pass params to the transport.
    internal var _knownActorName: String? {
        get {
            self.metadata.knownActorName
        }
        set {
            self.metadata.knownActorName = newValue
        }
    }

    /// Makes `DistributedActor.resolve` use the designated ID, rather than assigning one.
    internal var _designatedActorID: ActorID?

    /// INTERNAL API: Marks that this ref is spawned in service of a 'distributed actor'.
    /// This is a temporary solution until we move all the infrastructure onto distributed actors.
    @usableFromInline
    internal var _distributedActor: Bool = false

    // FIXME(distributed): remove this init
    public init(
        metadata: ActorMetadata = ActorMetadata(),
        metrics: MetricsProps = .disabled
    ) {
        self.metadata = metadata
        self.metrics = metrics
    }

    func consume() -> _Props {
        let c = self.deepCopy()
        self.metadata.clear()
        return c
    }

    /// Since metadata is mutable storage, we sometimes may need to perform a deep copy of Props if we want to have
    /// separate metadata storage from the original copy.
    func deepCopy() -> _Props {
        var p = _Props(metadata: ActorMetadata(), metrics: self.metrics)
        p.supervision = self.supervision
        p.dispatcher = self.dispatcher
        p._systemActor = self._systemActor
        p._designatedActorID = self._designatedActorID
        if p._knownActorName == nil {
            p._knownActorName = self._knownActorName
        }
        p._wellKnownName = self._wellKnownName
        p._wellKnown = self._wellKnown
        return p
    }

    /// Allows for passing properties to creating a distributed actor.
    @TaskLocal
    internal static var forSpawn: _Props = .init()
}

/// INTERNAL: Used for shuttling the Props into the ID while performing assignID.
/// These props must be used during `_spawn` which happens on `actorReady`.
///
/// This is somewhat of a relict of ActorRef infrastructure and should eventually be removed.
struct _PropsShuttle: @unchecked Sendable, Codable {
    let props: _Props
    init(props: _Props) {
        self.props = props.deepCopy()
    }

    init(from decoder: Decoder) throws {
        fatalError()
    }

    public func encode(to encoder: Encoder) throws {
        fatalError()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Dispatcher _Props

// TODO: likely better as class hierarchy, by we'll see...

extension _Props {
    /// Creates a new `_Props` with default values, and overrides the `dispatcher` with the provided one.
    static func dispatcher(_ dispatcher: _DispatcherProps) -> _Props {
        var props = _Props()
        props.dispatcher = dispatcher
        return props
    }

    /// Creates copy of this `_Props` changing the dispatcher props, useful for setting a few options in-line when spawning actors.
    func dispatcher(_ dispatcher: _DispatcherProps) -> _Props {
        var props = self
        props.dispatcher = dispatcher
        return props
    }
}

/// Configuring dispatchers should only be associated with actual research if the change is indeed beneficial.
/// In the vast majority of cases the default thread pool backed implementation should perform the best for typical workloads.
// TODO: Eventually: probably also best as not enum but a bunch of factories?
internal enum _DispatcherProps {
    /// Lets runtime determine the default dispatcher
    case `default`

    //    /// Use the Dispatch library as underlying executor.
    //    case dispatch(qosClass: Dispatch.DispatchQoS.QoSClass) // TODO: we want diff actors to be able to run on diff priorities, thus this setting

    // TODO: definitely good, though likely not as first thing We can base it on Akka's recent "Affinity" one,
    // though in Akka we had a hard time really proving that it outperforms the FJP since here we have no FJP readily available, and the Affinity one is much simpler,
    // I'd rather implement such style, as it actually is build "for" actors, and not accidentally running them well...
    // case OurOwnFancyActorSpecificDispatcher

    case dispatchQueue(DispatchQueue)

    /// WARNING: Use with Caution!
    ///
    /// This dispatcher will keep a real dedicated _Thread for this actor. This is very rarely something you want,
    // unless designing an actor that is intended to spin without others interrupting it on some resource and may block on it etc.
    case pinnedThread  // TODO: implement pinned thread dispatcher
    // TODO: CPU Affinity when pinning

    /// WARNING: Use with Caution!
    ///
    /// Allows binding an actor to an `EventLoopGroup` or a specific `EventLoop` itself.
    /// For most actors this should not matter, however it may show some benefit if interacting with many Futures
    /// fired on a specific `EventLoop`, for reasons of "locality" to where the events are fired (when on the same exact event loop).
    // TODO: not extensively tested but should just-work™ since we treat NIO as plain thread pool basically here.
    // TODO: not sure if we'd need this or not in reality, we'll see... executing futures safely would be more interesting perhaps
    case nio(NIO.EventLoopGroup)

    // TODO: or hide it completely somehow; too dangerous
    /// WARNING: Use with Caution!
    ///
    /// Dispatcher which hijacks the calling thread to schedule execution.
    case callingThread

    public var name: String {
        switch self {
        case .default: return "default"
        case .pinnedThread: return "pinnedThread"
        case .nio: return "nioEventLoopGroup"
        case .dispatchQueue: return "dispatchQueue"
        case .callingThread: return "callingThread"
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal _Props settings

extension _Props {
    /// Shorthand for `_Props()._asSellKnown`
    /// - SeeAlso: `_Props._asWellKnown`
    public static let _wellKnown: Self = _Props()._asWellKnown

    /// Use with great care, and ONLY if a path is known to only ever be occupied by the one and only actor that is going to be spawned using this well known identity.
    /// Allows spawning actors with "well known" identity (meaning the unique actor incarnation identifier will be set to `ActorIncarnation.wellKnown`).
    public var _asWellKnown: Self {
        var p = self
        p._wellKnown = true
        return p
    }

    /// All "normal" actors are not-so well-known.
    /// Inverse of a well-known actor, i.e. having it's unique identity generated upon spawning.
    public var _asNotSoWellKnown: Self {
        var p = self
        p._wellKnown = false
        return p
    }
}
