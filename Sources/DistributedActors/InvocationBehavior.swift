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

import Distributed
import struct Foundation.Data

/// Representation of the distributed invocation in the Behavior APIs.
/// This needs to be removed eventually as we remove behaviors.
public struct InvocationMessage: Sendable, Codable, CustomStringConvertible {
    let callID: ClusterSystem.CallID
    let targetIdentifier: String
    let genericSubstitutions: [String]
    let arguments: [Data]

    var target: RemoteCallTarget {
        RemoteCallTarget(targetIdentifier)
    }

    public var description: String {
        "InvocationMessage(callID: \(callID), target: \(target), genericSubstitutions: \(genericSubstitutions), arguments: \(arguments.count))"
    }
}

// FIXME(distributed): remove [#957](https://github.com/apple/swift-distributed-actors/issues/957)
enum InvocationBehavior {
    static func behavior(instance weakInstance: DistributedActorRef.Weak<some DistributedActor>) -> _Behavior<InvocationMessage> {
        return _Behavior.setup { context in
            return ._receiveMessageAsync { (message) async throws -> _Behavior<InvocationMessage> in
                guard let instance = weakInstance.actor else {
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
                            await instance.whenLocal { __secretlyKnownToBeLocalK in
                                let __secretlyKnownToBeLocal: any LifecycleWatch = __secretlyKnownToBeLocalK as! any LifecycleWatch
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
