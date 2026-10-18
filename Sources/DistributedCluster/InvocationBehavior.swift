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

import Distributed
import Logging

import struct Foundation.Data

/// Representation of the distributed invocation in the Behavior APIs.
/// This needs to be removed eventually as we remove behaviors.
public struct InvocationMessage: Sendable, Codable, CustomStringConvertible {
    let callID: ClusterSystem.CallID
    let targetIdentifier: String
    /// What the call was made through: the recipient runs it only as that.
    ///
    /// `nil` only for a call from a node that doesn't send it yet, which runs as before, unchecked.
    let recipient: Recipient?
    let genericSubstitutions: [String]
    let arguments: [Data]

    init(
        callID: ClusterSystem.CallID,
        targetIdentifier: String,
        recipient: Recipient,
        genericSubstitutions: [String],
        arguments: [Data]
    ) {
        self.callID = callID
        self.targetIdentifier = targetIdentifier
        self.recipient = recipient
        self.genericSubstitutions = genericSubstitutions
        self.arguments = arguments
    }

    /// What a call was made through, which decides which actors may run it.
    enum Recipient: Sendable, Codable, Equatable {
        /// An actor of this type, by its name, as ``ClusterSystem/typeName(_:)`` gives it.
        case actor(type: String)
        /// Any actor conforming to the protocol of a `@Resolvable` stub: its target goes through
        /// the protocol, which the actor's own type witnesses.
        case protocolStub
    }

    var target: RemoteCallTarget {
        RemoteCallTarget(targetIdentifier)
    }

    public var description: String {
        "InvocationMessage(callID: \(callID), target: \(target), genericSubstitutions: \(genericSubstitutions), arguments: \(arguments.count))"
    }
}

// FIXME(distributed): remove [#957](https://github.com/apple/swift-distributed-actors/issues/957)
enum InvocationBehavior {
    static func behavior(instance weakInstance: WeakLocalRef<some DistributedActor>) -> _Behavior<InvocationMessage> {
        _Behavior.setup { context in
            ._receiveMessageAsync { (message) async throws -> _Behavior<InvocationMessage> in
                guard let _ = weakInstance.actor else {
                    context.log.warning("Received message \(message) while distributed actor instance was released! Stopping...")
                    context.system.personalDeadLetters(type: InvocationMessage.self, recipient: context.id).tell(message)
                    return .stop
                }

                // `InvocationMessage`s are handled in `UserMessageHandler`
                // old impl: await context.system.receiveInvocation(actor: instance, message: message)
                return fatalErrorBacktrace("We don't invoke distributed actors via the behavior runtime anymore! ")
            }.receiveSignal { _, signal in

                // We received a signal, but our target actor instance was already released;
                // This should not really happen, but let's handle it by stopping the behavior.
                guard let instance = weakInstance.actor else {
                    return .stop
                }

                if let terminated = signal as? _Signals.Terminated {
                    if let watcher = instance as? (any LifecycleWatch) {
                        Task {
                            await watcher.whenLocal { __secretlyKnownToBeLocalK in
                                let __secretlyKnownToBeLocal: any LifecycleWatch = __secretlyKnownToBeLocalK
                                await __secretlyKnownToBeLocal._receiveActorTerminated(id: terminated.id)
                            }
                        }

                        return .same
                    }
                }

                // Invocation behaviors don't really handle signals at all.
                // Watching is done via `LifecycleWatch`.
                return .unhandled
            }
        }
    }
}
