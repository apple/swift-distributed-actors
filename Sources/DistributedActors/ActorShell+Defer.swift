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

import NIO
import Dispatch
import Logging
import CDistributedActorsMailbox

/// Selects until when an actor deferred block should be delayed.
///
/// - SeeAlso: `ActorContext.defer(until:file:line:_:)` for usage and semantics details.
public enum DeferUntilWhen {

    /// Semantically equivalent to a classic Swift `defer`, however also triggers in case of a fault occurring while receiving a message.
    case received

    /// Semantically equivalent to a classic Swift `defer`, however ONLY triggers in case of a fault occurring while receiving a message.
    ///
    /// Upon successful `receive` reduction the captured closure is NOT executed and **discarded**.
    case receiveFailed

    /// Defers execution of closure until the actor has terminated, for whichever reason (failure or stopping).
    case terminated

    /// Delays execution until actor terminates with any failure.
    ///
    /// Upon successful `receive` reduction the captured closure is NOT executed and **discarded**.
    case failed
    // TODO specialize for fault / error.
}

@usableFromInline
internal struct ActorDeferredClosure {
    @usableFromInline
    let when: DeferUntilWhen
    @usableFromInline
    let closure: () -> ()

    // TODO: Perhaps only store them in "debug mode", keeping only filename could also be enough
    let file: String
    let line: UInt

    init(until: DeferUntilWhen, _ closure: @escaping () -> (),
         file: String = #file, line: UInt = #line) {
        self.when = until
        self.closure = closure

        self.file = file
        self.line = line
    }
}
extension ActorDeferredClosure: CustomStringConvertible {
    public var description: String {
        fatalError("ActorDeferredClosure(until:\(when), Function defined at \(file):\(line))")
    }
}

struct DeferError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

@usableFromInline
final internal class DefersContainer {

    @usableFromInline
    var _deferredStack: [ActorDeferredClosure] = []

    /// Set true whenever during a reduction (the process interpreting message) a closure was pushed on the defers stack.
    /// If false, it is known that there is no need to attempt invoking defers after the reduction.
    @usableFromInline
    var _wasPushedDuringReduction: Bool = false

    /// Used to properly handle nested defers
    @usableFromInline
    var _invocationInProgress: Bool = false

    @usableFromInline
    func push(_ closure: ActorDeferredClosure) throws {
        if self._invocationInProgress {
            throw DeferError("Attempted to invoke context.defer within another context.defer; This is currently not supported. Please raise an issue if you need this functionality.")
        }

        self._wasPushedDuringReduction = true
        self._deferredStack.append(closure)
    }

    @usableFromInline
    func clear() {
        self._deferredStack = []
        self._wasPushedDuringReduction = false
    }

    // TODO: It is not trivial to figure out what is the right thing to do if we failed in a defer, maybe we have another defer that we wanted to execute etc...

    @usableFromInline
    var shouldInvokeAfterReceived: Bool {
        return self._wasPushedDuringReduction
    }

    // TODO: optimize, no need to always scan entire thing; can keep index around "after which there definitely are no more .received defers"
    /// Applies all `.received` deferred closures while removing them from the stack.
    ///
    /// Other closures remain untouched, as they may have to be triggered upon failure or termination of the actor.@usableFromInline
    @usableFromInline
    func invokeAllAfterReceived() throws {
        guard self._wasPushedDuringReduction else {
            return
        }
        self._wasPushedDuringReduction = false
        self._invocationInProgress = true

        defer {
            self._invocationInProgress = false
        }

        self._deferredStack = self._deferredStack.reversed().compactMap { deferred -> ActorDeferredClosure? in
            switch deferred.when {
            case .received:
                deferred.closure()
                return nil // we applied it, so can safely drop
            case .receiveFailed:
                return nil // receive did not fail, we have to drop the closure as it shall not be invoked
            case .terminated:
                return deferred // "keep"
            case .failed:
                return deferred // "keep"
            }
        }.reversed()
    }

    @usableFromInline
    func invokeAllAfterReceiveFailed() throws {
        guard self._wasPushedDuringReduction else {
            return
        }
        self._wasPushedDuringReduction = false
        self._invocationInProgress = true

        defer {
            self._invocationInProgress = false
        }

        self._deferredStack = self._deferredStack.reversed().compactMap { deferred -> ActorDeferredClosure? in
            switch deferred.when {
            case .received:
                deferred.closure()
                return nil // we applied it, so can safely drop
            case .receiveFailed:
                deferred.closure() // receive did fail, so we have to invoke and drop these as well
                return nil
            case .terminated:
                return deferred // "keep"
            case .failed:
                return deferred // "keep"
            }
        }.reversed()
    }

    /// Invokes all pending `defer(.received|.terminated)` but skips `.failed` since we have a clean termination at hand.
    ///
    /// Clears the defer stack once completed.
    @usableFromInline
    func invokeAllAfterStop() throws {
        self._invocationInProgress = true
        defer {
            self._invocationInProgress = false
            self.clear()
        }

        self._deferredStack.reversed().forEach { deferred in
            switch deferred.when {
            case .received:
                deferred.closure()
            case .terminated:
                deferred.closure()

            case .receiveFailed:
                () // ignore, this should only be invoked upon failure
            case .failed:
                () // ignore, since termination was proper (stop), rather than a failure
            }
        }
    }

    /// Invokes all pending deferred closures.
    ///
    /// Clears the defer stack once completed.
    @usableFromInline
    func invokeAllAfterFailing() throws {
        self._invocationInProgress = true
        defer {
            self._invocationInProgress = false
            self.clear()
        }

        self._deferredStack.reversed().forEach { deferred in
            switch deferred.when {
            case .received:
                deferred.closure()
            case .receiveFailed:
                deferred.closure()
            case .terminated:
                deferred.closure()
            case .failed:
                deferred.closure()
            }
        }
    }
}
