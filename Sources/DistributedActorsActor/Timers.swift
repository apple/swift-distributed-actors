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
    let key: String
    @usableFromInline
    let message: Message
    @usableFromInline
    let repeated: Bool
    @usableFromInline
    let generation: Int
    @usableFromInline
    let handle: Cancelable
}

class TimerInterceptor<Message>: Interceptor<Message> {
    let timers: Timers<Message>

    init(_ timers: Timers<Message>) {
        self.timers = timers
    }

    override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        if let timerSignal = signal as? Signals.TimerSignal {
            if timerSignal.owner.path != context.path {
                context.log.warning("Received timer signal with key [\(timerSignal.key)] for different actor with path [\(context.path)]. Will ignore and continue.")
                return .ignore
            }

            if let timer = self.timers.installedTimers[timerSignal.key] {
                if timer.generation != timerSignal.generation {
                    context.log.warning("Received timer event for old generation [\(timerSignal.generation)], expected [\(timer.generation)]. Will ignore and continue.")
                    return .ignore
                }

                context.myself.tell(timer.message)

                if !timer.repeated {
                    self.timers.cancelTimer(forKey: timer.key)
                }
            }
        } else {
            if signal is Signals.PreRestart || signal is Signals.PostStop {
                self.timers.cancelAll()
            }
            return try target.interpretSignal(context: context, signal: signal)
        }

        return .same
    }
}

public class Timers<Message> {
    @usableFromInline
    var timerGen: Int = 0

    // TODO: eventually replace with our own scheduler implementation
    @usableFromInline
    let q = DispatchQueue.global()
    @usableFromInline
    var installedTimers: [String: Timer<Message>] = [:]
    @usableFromInline
    unowned var context: ActorContext<Message>

    init(context: ActorContext<Message>) {
        self.context = context
    }

    var interceptor: Interceptor<Message> {
        return TimerInterceptor(self)
    }

    /// Cancels all active timers.
    @inlinable
    public func cancelAll() {
        for key in self.installedTimers.keys {
            self.cancelTimer(forKey: key)
        }
    }

    /// Cancels timer associated with the given key.
    ///
    /// - Parameter key: key of the timer to cancel
    @inlinable
    public func cancelTimer(forKey key: String) {
        if let timer = self.installedTimers.removeValue(forKey: key) {
            self.context.log.debug("Cancel timer [\(key)] with generation [\(timer.generation)]")
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
    public func startSingleTimer(key: String, message: Message, delay: TimeAmount) {
        self.startTimer(key: key, message: message, interval: delay, repeated: false)
    }

    /// Starts a timer that will periodically send the given message to `myself`.
    ///
    /// - Parameters:
    ///   - key: the key associated with the timer
    ///   - message: the message that will be sent to `myself`
    ///   - interval: the interval with which the message will be sent
    @inlinable
    public func startPeriodicTimer(key: String, message: Message, interval: TimeAmount) {
        self.startTimer(key: key, message: message, interval: interval, repeated: true)
    }

    @usableFromInline
    func startTimer(key: String, message: Message, interval: TimeAmount, repeated: Bool) {
        self.cancelTimer(forKey: key)

        let ref = self.context.myself._downcastUnsafe

        let generation = self.nextTimerGen()
        let signal: SystemMessage = .timerSignal(key: key, generation: generation, owner: self.context.myself._boxAnyReceivesSystemMessages())
        let handle: Cancelable
        if repeated {
            handle = self.q.schedule(initialDelay: interval, interval: interval) {
                ref.sendSystemMessage(signal)
            }
        } else {
            handle = self.q.scheduleOnce(delay: interval) {
                ref.sendSystemMessage(signal)
            }
        }

        self.context.log.debug("Started timer [\(key)] with generation [\(generation)]")
        self.installedTimers[key] = Timer.init(key: key, message: message, repeated: repeated, generation: generation, handle: handle)
    }

    func nextTimerGen() -> Int {
        defer { self.timerGen += 1 }
        return self.timerGen
    }
}

extension Behavior {
    /// Creates a timers structure that can be used inside the behavior to schedule
    /// messages to `myself`.
    ///
    /// - Parameter block: creator for behaviors that can create timers
    /// - Returns: the behavior returned from `block` wrapped with timers functionality
    public static func withTimers<Message>(_ block: @escaping (Timers<Message>) -> Behavior<Message>) -> Behavior<Message> {
        return .setup { context in
            let timers = Timers<Message>(context: context)
            return .intercept(behavior: block(timers), with: timers.interceptor)
        }
    }
}
