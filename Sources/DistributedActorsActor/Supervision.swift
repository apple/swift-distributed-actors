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

import struct NIO.TimeAmount

public enum SupervisionStrategy {

    case stop
    case restart(atMost: Int) // TODO: within: TimeAmount etc
    // TODO: how to plug in custom one
}

public struct Supervision {

    public static func supervisorFor<Message>(_ behavior: Behavior<Message>, _ strategy: SupervisionStrategy) -> Supervisor<Message> {
        switch strategy {
        case .stop: return StoppingSupervisor() // TODO: strategy could carry additional configuration
        case .restart: return RestartingSupervisor(initialBehavior: behavior) // TODO: strategy could carry additional configuration
        }
    }

    public enum Failure {
        // TODO: figure out how to represent failures, carry error code, actor path etc I think
        case error(Error)
        case fault(Error)
    }

    /// Supervision directives instruct the actor system to apply a specific
    public enum Directive {
        /// TODO: document
        case stop

        /// TODO: document
        case escalate

        /// TODO: document
        case restart

        // TODO: exponential backoff settings, best as config object for easier extension?
        case backoffRestart
    }
}

/// Handles failures that may occur during message (or signal) handling within an actor.
///
/// To implement your own `Supervisor` implement the `handleMessageFailure` and `handleSignalFailure` methods,
/// OR use the
public class Supervisor<Message>: Interceptor<Message> {

    final override func interceptMessage(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        do {
            return try target.interpretMessage(context: context, message: message) // no-op implementation by default
        } catch {
            context.log.warn("Supervision: Actor has THROWN [\(error)]:\(type(of: error)), HANDLING IN \(self)")
            return try self.handleMessageFailure(context, failure: .error(error))
        }
    }

    final override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        do {
            return try target.interpretSignal(context: context, signal: signal)
        } catch {
            context.log.warn("Supervision: Actor has THROWN [\(error)]:\(type(of: error)), HANDLING IN \(self)")
            return try self.handleSignalFailure(context, failure: .error(error))
        }
    }

    // MARK: Internal Supervisor API

    /// Handle a fault that happened during message processing
    // TODO clarify what happens on faults here -- they should not be recovered I think; no double faults allowed
    func handleMessageFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        return undefined()
    }

    func handleSignalFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        return undefined()
    }

    func isSameAs(_ supervisor: Supervisor<Message>) -> Bool {
        return undefined()
    }
}


final class StoppingSupervisor<Message>: Supervisor<Message> {
    override func handleMessageFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        return .stopped
    }

    override func handleSignalFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        return .stopped
    }

    override func isSameAs(_ supervisor: Supervisor<Message>) -> Bool {
        fatalError("isSameAs(to:) has not been implemented")
    }
}

final class RestartingSupervisor<Message>: Supervisor<Message> {

    private let initialBehavior: Behavior<Message>

    private var failures: Int = 0

    public init(initialBehavior behavior: Behavior<Message>) {
        self.initialBehavior = behavior
        super.init()
    }

    override func handleMessageFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        self.failures += 1
        pprint("!!!!!!RESTART (\(self.failures)-th time)!!!!!! >>>> \(initialBehavior)")
        // TODO has to modify restart counters here and supervise with modified supervisor
        return try initialBehavior.start(context: context).supervisedWith(supervisor: self)
    }

    override func handleSignalFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        pprint("!!!!!!RESTART!!!!!! >>>> \(initialBehavior)")
        return try initialBehavior.start(context: context).supervisedWith(supervisor: self)
    }

    override func isSameAs(_ supervisor: Supervisor<Message>) -> Bool {
        fatalError("isSameAs(to:) has not been implemented")
    }
}
