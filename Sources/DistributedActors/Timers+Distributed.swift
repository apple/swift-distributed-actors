//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
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
import struct NIO.TimeAmount

@usableFromInline
struct DistributedActorTimer {
    @usableFromInline
    let key: TimerKey
    @usableFromInline
    let repeated: Bool
    @usableFromInline
    let handle: Cancelable
}

@usableFromInline
struct DistributedActorTimerEvent {
    let key: TimerKey
//    let generation: Int
    let owner: ActorID
}

/// Creates and manages timers which may only be accessed from the actor that owns it.
///
/// _BehaviorTimers are bound to this objects lifecycle, i.e. when the actor owning this object is deallocated,
/// and the `ActorTimers` are deallocated as well, all timers associated with it are cancelled.
// TODO(distributed): rename once we're able to hide or remove `_BehaviorTimers`
public final class ActorTimers<Act: DistributedActor> where Act.ActorSystem == ClusterSystem {
    @usableFromInline
    internal let ownerID: ActorID

    @usableFromInline
    internal let dispatchQueue = DispatchQueue.global()
    @usableFromInline
    internal var installedTimers: [TimerKey: DistributedActorTimer] = [:]

    // TODO: this is a workaround, we're removing ActorTimers since they can't participate in structured cancellation
    weak var actorSystem: Act.ActorSystem?

    /// Create a timers instance owned by the passed in actor.
    ///
    /// Does not retain the distributed actor.
    ///
    /// - Parameter myself:
    public init(_ myself: Act) {
        self.ownerID = myself.id
    }

    deinit {
        self._cancelAll(includeSystemTimers: true)
    }

    /// Cancel all timers currently stored in this ``ActorTimers`` instance.
    public func cancelAll() {
        self._cancelAll(includeSystemTimers: false)
    }

    internal func _cancelAll(includeSystemTimers: Bool) {
        for key in self.installedTimers.keys where includeSystemTimers || !key.isSystemTimer {
            // TODO: the reason the `_` keys are not cancelled is because we want to cancel timers in _restartPrepare but we need "our restart timer" to remain
            self.cancel(for: key)
        }
    }

    /// Cancels timer associated with the given key.
    ///
    /// - Parameter key: key of the timer to cancel
    @inlinable
    public func cancel(for key: TimerKey) {
        if let timer = self.installedTimers.removeValue(forKey: key) {
            timer.handle.cancel()
        }
    }

    /// Checks for the existence of a scheduler timer for given key (single or periodic).
    ///
    /// - Returns: true if timer exists, false otherwise
    @inlinable
    public func exists(key: TimerKey) -> Bool {
        self.installedTimers[key] != nil
    }

    /// Starts a timer that will invoke the provided `call` closure on the actor's context after the specified delay.
    ///
    /// - Parameters:
    ///   - key: the key associated with the timer
    ///   - call: the call that will be made after the `delay` amount of time elapses
    ///   - delay: the delay after which the message will be sent
    @inlinable
    public func startSingle(
        key: TimerKey,
        delay: TimeAmount,
        @_inheritActorContext @_implicitSelfCapture call: @Sendable @escaping () async -> Void
    ) {
        self.start(key: key, call: call, interval: delay, repeated: false)
    }

    /// Starts a timer that will periodically invoke the passed in `call` closure on the actor's context.
    ///
    /// - Parameters:
    ///   - key: the key associated with the timer
    ///   - call: the call that will be executed after the `delay` amount of time elapses
    ///   - interval: the interval with which the message will be sent
    @inlinable
    public func startPeriodic(
        key: TimerKey,
        interval: TimeAmount,
        @_inheritActorContext @_implicitSelfCapture call: @Sendable @escaping () async -> Void
    ) {
        self.start(key: key, call: call, interval: interval, repeated: true)
    }

    @usableFromInline
    internal func start(
        key: TimerKey,
        @_inheritActorContext @_implicitSelfCapture call: @Sendable @escaping () async -> Void,
        interval: TimeAmount,
        repeated: Bool
    ) {
        self.cancel(for: key)

        let handle: Cancelable
        if repeated {
            handle = self.dispatchQueue.scheduleAsync(initialDelay: interval, interval: interval) {
                // We take the lock to prevent the system from shutting down
                // while we're in the middle of potentially issuing remote calls
                // Which may cause: Cannot schedule tasks on an EventLoop that has already shut down.
                // The actual solution is outstanding work tracking potentially.
                let system = self.actorSystem
                system?.shutdownLock.lock()
                defer {
                    system?.shutdownLock.unlock()
                }

                await call()
            }
        } else {
            handle = self.dispatchQueue.scheduleOnceAsync(delay: interval) {
                // We take the lock to prevent the system from shutting down
                // while we're in the middle of potentially issuing remote calls
                // Which may cause: Cannot schedule tasks on an EventLoop that has already shut down.
                // The actual solution is outstanding work tracking potentially.
                let system = self.actorSystem
                system?.shutdownLock.lock()
                defer {
                    system?.shutdownLock.unlock()
                }

                await call()
            }
        }

        self.installedTimers[key] = DistributedActorTimer(key: key, repeated: repeated, handle: handle)
    }
}
