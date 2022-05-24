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

import Distributed
import struct Foundation.Data

/// Representation of the distributed invocation in the Behavior APIs.
/// This needs to be removed eventually as we remove behaviors.
public struct InvocationMessage: Sendable, Codable, CustomStringConvertible {
    let targetIdentifier: String
    let arguments: [Data]
    var replyToAddress: ActorAddress

    var target: RemoteCallTarget {
        RemoteCallTarget(targetIdentifier)
    }

    public var description: String {
        "InvocationMessage(target: \(target), arguments: \(arguments.count))"
    }
}

enum InvocationBehavior {
    static func behavior(instance weakInstance: Weak<some DistributedActor>) -> _Behavior<InvocationMessage> {
        return _Behavior.setup { context in
            return ._receiveMessageAsync { (message) async throws -> _Behavior<InvocationMessage> in
                guard let instance = weakInstance.actor else {
                    context.log.warning("Received message \(message) while distributed actor instance was released! Stopping...")
                    context.system.personalDeadLetters(type: InvocationMessage.self, recipient: context.address).tell(message)
                    return .stop
                }
                
                await context.system.receiveInvocation(actor: instance, message: message)
                return .same
            }.receiveSignal { context, signal in
                pprint("RECEIVE SIGNAL: \(signal) ON \(context.myself)")

                // We received a signal, but our target actor instance was already released;
                // This should not really happen, but let's handle it by stopping the behavior.
                guard let instance = weakInstance.actor else {
                    return .stop
                }

                context.log.warning("signal as? Signals.Terminated == \(signal as? Signals.Terminated)")
                context.log.warning("instance as? (any LifecycleWatch) == \(instance as? (any LifecycleWatch))")

                if let terminated = signal as? Signals.Terminated {
                    context.log.info("TERMINATED ...")
                    if let watcher = instance as? (any LifecycleWatch) {
                        context.log.info("INSTANCE IS WATCHING...")
                        let watch = watcher.actorSystem._getLifecycleWatch(watcher: watcher)
                        watch?.receiveTerminated(terminated)
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
