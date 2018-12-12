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

    public static func supervisorFor<Message>(_ strategy: SupervisionStrategy) -> Supervisor<Message> {
        switch strategy {
        case .stop: return StoppingSupervisor() // TODO: strategy could carry additional configuration
        case .restart: return RestartingSupervisor() // TODO: strategy could carry additional configuration
        }
    }
    
    public enum Fault {
        // TODO: figure out how to represent failures, carry error code, actor path etc I think
        case error(error: Error)
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

public class Supervisor<Message>: Interceptor<Message> {

    final override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        do {
            return try target.interpretSignal(context: context, signal: signal)
        } catch {
            return self.handleSignalFault(error: .error(error))
        }
    }

    final override func interceptMessage(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        do {
            return try target.interpretMessage(context: context, message: message) // no-op implementation by default
        } catch {
            return self.handleMessageHandlingFault(error: .error(error)) // TODO also message?
        }
    }

    // MARK: Internal Supervisor API

    /// Handle a fault that
    func handleMessageFault(error: Supervision.Fault)  -> Behavior<Message> {
        return undefined()
    }

    func handleSignalFault(error: Supervision.Fault)  -> Behavior<Message> {
        return undefined()
    }

    func isSameAs(_ supervisor: Supervisor<Message>) -> Bool {
        return undefined()
    }
}


final class StoppingSupervisor<Message>: Supervisor<Message> {
    override func handleMessageFault(error: Supervision.Fault)  -> Behavior<Message> {
        fatalError("handleMessageHandlingFault(error:) has not been implemented")
    }

    override func handleSignalFault(error: Supervision.Fault)  -> Behavior<Message> {
        fatalError("handleSignalHandlingFault(error:) has not been implemented")
    }

    override func isSameAs(_ supervisor: Supervisor<Message>) -> Bool {
        fatalError("isSameAs(to:) has not been implemented")
    }
}

final class RestartingSupervisor<Message>: Supervisor<Message> {
    override func handleMessageFault(error: Supervision.Fault)  -> Behavior<Message> {
        fatalError("handleMessageHandlingFault(error:) has not been implemented")
    }

    override func handleSignalFault(error: Supervision.Fault)  -> Behavior<Message> {
        fatalError("handleSignalHandlingFault(error:) has not been implemented")
    }

    override func isSameAs(_ supervisor: Supervisor<Message>) -> Bool {
        fatalError("isSameAs(to:) has not been implemented")
    }
}
