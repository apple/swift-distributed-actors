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
import struct NIO.TimeAmount

@usableFromInline
struct Timer<Message> {
    @usableFromInline
    let key: TimerKey
    @usableFromInline
    let message: Message?
    @usableFromInline
    let repeated: Bool
    @usableFromInline
    let generation: Int
    @usableFromInline
    let handle: Cancelable
}

@usableFromInline
struct TimerEvent {
    let key: TimerKey
    let generation: Int
    let owner: AddressableActorRef
}

/// A `TimerKey` is used to identify a timer. It can be stored and re-used.
///
/// Example:
///
///     let timerKey = TimerKey("my-key")
///     timers.startPeriodicTimer(key: timerKey, message: "ping", interval: .seconds(1))
///     // ...
///     timers.cancelTimer(forKey: timerKey)
///
public struct TimerKey: Hashable {
    private let identifier: AnyHashable

    @usableFromInline
    let isSystemTimer: Bool

    public init<T: Hashable>(_ identifier: T) {
        self.init(identifier, isSystemTimer: false)
    }

    internal init<T: Hashable>(_ identifier: T, isSystemTimer: Bool) {
        self.identifier = AnyHashable(identifier)
        self.isSystemTimer = isSystemTimer
    }
}

extension TimerKey: CustomStringConvertible {
    public var description: String {
        if self.isSystemTimer {
            return "TimerKey(\(self.identifier), isSystemTimer: \(self.isSystemTimer))"
        } else {
            return "TimerKey(\(self.identifier.base))"
        }
    }
}

extension TimerKey: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

public class Timers<Message> {
    @usableFromInline
    internal var timerGen: Int = 0

    // TODO: eventually replace with our own scheduler implementation
    @usableFromInline
    internal let dispatchQueue = DispatchQueue.global()
    @usableFromInline
    internal var installedTimers: [TimerKey: Timer<Message>] = [:]
    @usableFromInline
    internal unowned var context: ActorContext<Message>

    init(context: ActorContext<Message>) {
        self.context = context
    }

    /// Cancels all active timers.
    ///
    /// - WARNING: Does NOT cancel `_` prefixed keys. This is currently a workaround for "system timers" which should not be cancelled arbitrarily.
    // TODO: This will be replaced by proper timer keys which can express such need eventually.
    public func cancelAll() {
        self._cancelAll(includeSystemTimers: false)
    }

    internal func _cancelAll(includeSystemTimers: Bool) {
        for key in self.installedTimers.keys where includeSystemTimers || !key.isSystemTimer { // TODO: represent with "system timer key" type?
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
            self.context.log.trace("Cancel timer [\(key)] with generation [\(timer.generation)]")
            timer.handle.cancel()
        }
    }

    /// Starts a timer that will send the given message to `myself` after the specified delay.
    ///
    /// - Parameters:
    ///   - key: the key associated with the timer
    ///   - message: the message that will be sent to `myself`
    ///   - delay: the delay after which the message will be sent
    @inlinable
    public func startSingle(key: TimerKey, message: Message, delay: TimeAmount) {
        self.start(key: key, message: message, interval: delay, repeated: false)
    }

    /// Starts a timer that will periodically send the given message to `myself`.
    ///
    /// - Parameters:
    ///   - key: the key associated with the timer
    ///   - message: the message that will be sent to `myself`
    ///   - interval: the interval with which the message will be sent
    @inlinable
    public func startPeriodic(key: TimerKey, message: Message, interval: TimeAmount) {
        self.start(key: key, message: message, interval: interval, repeated: true)
    }

    @usableFromInline
    internal func start(key: TimerKey, message: Message, interval: TimeAmount, repeated: Bool) {
        self.cancel(for: key)

        let generation = self.nextTimerGen()
        let event = TimerEvent(key: key, generation: generation, owner: self.context.myself.asAddressable())
        let handle: Cancelable
        let cb = self.timerCallback
        if repeated {
            handle = self.dispatchQueue.schedule(initialDelay: interval, interval: interval) {
                cb.invoke(event)
            }
        } else {
            handle = self.dispatchQueue.scheduleOnce(delay: interval) {
                cb.invoke(event)
            }
        }

        self.context.log.trace("Started timer [\(key)] with generation [\(generation)]")
        self.installedTimers[key] = Timer(key: key, message: message, repeated: repeated, generation: generation, handle: handle)
    }

    internal func nextTimerGen() -> Int {
        defer { self.timerGen += 1 }
        return self.timerGen
    }

    internal lazy var timerCallback: AsynchronousCallback<TimerEvent> =
        self.context.makeAsynchronousCallback { [weak context = self.context] timerEvent in
            if let context = context {
                if timerEvent.owner.path != context.path {
                    context.log.warning("Received timer signal with key [\(timerEvent.key)] for different actor with path [\(context.path)]. Will ignore and continue.")
                    return
                }

                if let timer = self.installedTimers[timerEvent.key] {
                    if timer.generation != timerEvent.generation {
                        context.log.warning("Received timer event for old generation [\(timerEvent.generation)], expected [\(timer.generation)]. Will ignore and continue.")
                        return
                    }

                    if let message = timer.message {
                        context.myself.tell(message)
                    }

                    if !timer.repeated {
                        self.cancel(for: timer.key)
                    }
                }
            }
        }
}

// ==== ----------------------------------------------------------------------------------------------------------------

// MARK: Internal System Timer capabilities

internal extension Timers {
    @usableFromInline
    struct ScheduledResume<T> {
        let token: T
    }

    /// Dangerous version of `_startTimer` which allows scheduling a `.resume` system message (directly!) with a token `T`, after a time `delay`.
    /// This can be used e.g. to implement restarting an actor after a backoff delay.
    func _startResumeTimer<T>(key: TimerKey, delay: TimeAmount, resumeWith token: T) {
        assert(key.isSystemTimer, "_startResumeTimer MUST ONLY be used by system internal tasks, and keys MUST be `_` prefixed. Key was: \(key)")
        self.cancel(for: key)

        let generation = self.nextTimerGen()

        let handle = self.dispatchQueue.scheduleOnce(delay: delay) { [weak context = self.context] in
            guard let context = context else {
                return
            }
            traceLog_Supervision("executing the task ::: \(context.myself)")

            // TODO: avoid the box part?
            context.myself.asAddressable().sendSystemMessage(.resume(.success(token)))
        }

        traceLog_Supervision("Scheduled actor wake-up [\(key)] with generation [\(generation)], in \(delay.prettyDescription)")
        self.context.log.debug("Scheduled actor wake-up [\(key)] with generation [\(generation)], in \(delay.prettyDescription)")
        self.installedTimers[key] = Timer(key: key, message: nil, repeated: false, generation: generation, handle: handle)
    }
}
