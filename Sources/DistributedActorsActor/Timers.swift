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

@usableFromInline
struct TimerEvent {
    let key: String
    let generation: Int
    let owner: AnyReceivesSystemMessages
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

        let generation = self.nextTimerGen()
        let event = TimerEvent(key: key, generation: generation, owner: self.context.myself._boxAnyReceivesSystemMessages())
        let handle: Cancelable
        let cb = self.timerCallback
        if repeated {
            handle = self.q.schedule(initialDelay: interval, interval: interval) {
                cb.invoke(event)
            }
        } else {
            handle = self.q.scheduleOnce(delay: interval) {
                cb.invoke(event)
            }
        }

        self.context.log.debug("Started timer [\(key)] with generation [\(generation)]")
        self.installedTimers[key] = Timer.init(key: key, message: message, repeated: repeated, generation: generation, handle: handle)
    }

    func nextTimerGen() -> Int {
        defer { self.timerGen += 1 }
        return self.timerGen
    }

    lazy var timerCallback: AsynchronousCallback<TimerEvent> =
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

                    context.myself.tell(timer.message)

                    if !timer.repeated {
                        self.cancelTimer(forKey: timer.key)
                    }
                }
            }
        }
}
