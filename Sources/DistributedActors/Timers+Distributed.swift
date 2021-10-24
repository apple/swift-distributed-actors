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

import _Distributed
import Dispatch
import Logging
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
    let owner: ActorIdentity
}

/// Creates and manages timers which may only be accessed from the actor that owns it.
///
/// Timers are bound to this objects lifecycle, i.e. when the actor owning this object is deallocated,
/// and the `ActorTimers` are deallocated as well, all timers associated with it are cancelled.
// TODO(distributed): rename once we're able to hide or remove `Timers`
public final class ActorTimers<Act: DistributedActor> {

    @usableFromInline
    internal let ownerID: ActorIdentity // TODO: can be just identity

    @usableFromInline
    internal let dispatchQueue = DispatchQueue.global()
    @usableFromInline
    internal var installedTimers: [TimerKey: DistributedActorTimer] = [:]

    @usableFromInline
    internal var log: Logger

    /// Create a timers instance owned by the passed in actor.
    ///
    /// Does not retain the distributed actor.
    ///
    /// - Parameter myself:
    public init<Act: DistributedActor>(_ myself: Act) {
        self.log = Logger(label: "\(myself)") // FIXME(distributed): pick up the actor logger (!!!)
        log[metadataKey: "actor/id"] = "\(myself.id._unwrapActorAddress?.detailedDescription ?? String(describing: myself.id.underlying))"
        self.ownerID = myself.id
    }

    deinit {
        if installedTimers.count > 0 {
            log.debug("\(Self.self) deinit, cancelling [\(installedTimers.count)] timers") // TODO: include actor address
        }
        self._cancelAll(includeSystemTimers: true)
    }

    /// Cancel all timers currently stored in this ``ActorTimers`` instance.
    public func cancelAll() {
        self._cancelAll(includeSystemTimers: false)
    }

    internal func _cancelAll(includeSystemTimers: Bool) {
        for key in self.installedTimers.keys where includeSystemTimers || !key.isSystemTimer {
            // TODO: represent with "system timer key" type?
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
//            if system.settings.logging.verboseTimers {
//                self.log.trace("Cancel timer [\(key)] with generation [\(timer.generation)]", metadata: self.metadata)
//            }
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
    /// Timer keys are used for logging purposes and should descriptively explain the purpose of this timer.
    ///
    /// - Parameters:
    ///   - key: the key associated with the timer
    ///   - call: the call that will be made after the `delay` amount of time elapses
    ///   - delay: the delay after which the message will be sent
    @inlinable
    public func startSingle(key: TimerKey, delay: TimeAmount,
                            @_inheritActorContext @_implicitSelfCapture call: @Sendable @escaping () async -> Void) {
        self.start(key: key, call: call, interval: delay, repeated: false)
    }

    /// Starts a timer that will periodically invoke the passed in `call` closure on the actor's context.
    ///
    /// Timer keys are used for logging purposes and should descriptively explain the purpose of this timer.
    ///
    /// - Parameters:
    ///   - key: the key associated with the timer
    ///   - call: the call that will be executed after the `delay` amount of time elapses
    ///   - interval: the interval with which the message will be sent
    @inlinable
    public func startPeriodic(key: TimerKey, interval: TimeAmount,
                              @_inheritActorContext @_implicitSelfCapture call: @Sendable @escaping () async -> Void) {
        self.start(key: key, call: call, interval: interval, repeated: true)
    }

    @usableFromInline
    internal func start(key: TimerKey,
                        @_inheritActorContext @_implicitSelfCapture call: @Sendable @escaping () async -> Void,
                        interval: TimeAmount, repeated: Bool) {
        self.cancel(for: key)

//        let generation = self.nextTimerGen() // TODO(distributed): we're not using generations since we don't have restarts
        // let event = DistributedActorTimerEvent(key: key, generation: generation, owner: self.ownerID)
        let handle: Cancelable
        if repeated {
            handle = self.dispatchQueue.scheduleAsync(initialDelay: interval, interval: interval) {
                await call()
            }
        } else {
            handle = self.dispatchQueue.scheduleOnceAsync(delay: interval) {
                await call()
            }
        }

//        if system.settings.logging.verboseTimers {
//            self.log.trace("Started timer [\(key)] with generation [\(generation)]", metadata: self.metadata)
//        }
        self.installedTimers[key] = DistributedActorTimer(key: key, repeated: repeated, handle: handle)
    }

}