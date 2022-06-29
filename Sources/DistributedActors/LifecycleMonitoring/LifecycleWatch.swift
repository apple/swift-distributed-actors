//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Distributed
import DistributedActorsConcurrencyHelpers
import NIO

/// Provides a distributed actor with the ability to "watch" other actors lifecycles.
///
/// - SeeAlso:
///     - <doc:Lifecycle>
public protocol LifecycleWatch: DistributedActor where ActorSystem == ClusterSystem {
    /// Called with an ``ClusterSystem/ActorID`` of a distributed actor that was previously
    /// watched using ``watchTermination(of:file:line:)``, and has now terminated.
    ///
    /// Termination means either deinitialization of the actor, or that the node the actor was
    /// located on has been declared ``Cluster/MemberStatus/down``.
    ///
    /// - Parameter id: the ID of the now terminated actor
    func terminated(actor id: ActorID) async throws // FIXME(distributed): Should not need to be throwing: https://github.com/apple/swift/pull/59397
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Lifecycle Watch API

extension LifecycleWatch {
    /// Watch the `watchee` actor for termination, and trigger the `whenTerminated` callback when
    @available(*, deprecated, message: "Replaced with the much safer `watchTermination(of:)` paired with `actorTerminated(_:)`")
    public func watchTermination<Watchee>(
        of watchee: Watchee,
        @_inheritActorContext whenTerminated: @escaping @Sendable (ID) async -> Void,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        pprint("ENTER (via actor): \(#function)")
        guard let watch = self.context.lifecycle else {
            return watchee
        }

        watch.termination(of: watchee.id, whenTerminated: whenTerminated, file: file, line: line)
        return watchee
    }

    /// Watch the `watchee` actor for termination.
    ///
    /// As result of watching a distributed actor, the ``terminated(actor:)`` method is invoked when the actor terminates.
    /// That method gets only the actors `ID` passed, as passing the reference would mean keeping the actor alive,
    /// which is counter to the purpose of this API: notifying when a distributed actor has terminated (i.e. deinitialized,
    /// or a member it was hosted on was determined ``Cluster/MemberStatus/down``).
    ///
    /// - Parameters:
    ///   - watchee: the actor to watch
    /// - Returns: the watched actor
    @discardableResult
    public func watchTermination<Watchee>(
        of watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        pprint("ENTER (via actor): \(#function)")
        guard let watch = self.context.lifecycle else {
            return watchee
        }

        watch.termination(of: watchee.id, whenTerminated: { id in
            try? await self.terminated(actor: id)
        }, file: file, line: line)

        return watchee
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered, since the intent of no longer watching the terminating
    /// actor takes immediate effect.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. return context.unwatch(ref)`
    public func isWatching<Watchee>(_ watchee: Watchee) -> Bool where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        pprint("ENTER (via actor): \(#function)")
        guard let watch = self.context.lifecycle else {
            return false
        }

        return watch.isWatching(watchee.id)
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered to the `onSignal` behavior, since the intent of no longer
    /// watching the terminating actor takes immediate effect.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. return context.unwatch(ref)`
    @available(*, deprecated, renamed: "unwatchTermination(of:file:line:)")
    @discardableResult
    public func unwatch<Watchee: DistributedActor>(
        _ watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee.ActorSystem == ClusterSystem {
        pprint("ENTER (via actor): \(#function)")
        return self.unwatchTermination(of: watchee, file: file, line: line)
    }

    @discardableResult
    public func unwatchTermination<Watchee: DistributedActor>(
        of watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee.ActorSystem == ClusterSystem {
        pprint("ENTER (via actor): \(#function)")
        guard let watch = self.context.lifecycle else {
            return watchee
        }

        return watch.unwatch(watchee: watchee, file: file, line: line)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal functions made to make the watch signals work

extension LifecycleWatch {
    /// Function invoked by the actor transport when a distributed termination is detected.
    public func _receiveActorTerminated(id: ID) async {
        guard let watch = self.context.lifecycle else {
            return
        }

        watch.receiveTerminated(id)
    }
}
