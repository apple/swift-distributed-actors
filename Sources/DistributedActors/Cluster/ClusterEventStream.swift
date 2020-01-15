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

import Logging

/// Specialized event stream behavior which takes into account emitting a snapshot event on first subscription,
/// followed by a stream of `ClusterEvent`s.
///
/// This ensures that every subscriber to cluster events never misses any of the membership events, meaning
/// it is possible for anyone to maintain a local up-to-date copy of `Membership` by applying all these events to that copy.
enum ClusterEventStream {
    enum Shell {
        static var behavior: Behavior<EventStreamShell.Message<ClusterEvent>> {
            .setup { context in

                // We maintain a snapshot i.e. the "latest version of the membership",
                // in order to eagerly publish it to anyone who subscribes immediately,
                // followed by joining them to the subsequent `ClusterEvent` publishes.
                //
                // Thanks to this, any subscriber immediately gets a pretty recent view of the membership,
                // followed by the usual updates via events. Since all events are published through this
                // event stream actor, all subscribers are guaranteed to see events in the right order,
                // and not miss any information as long as they apply all events they receive.
                var snapshot = Membership.empty
                var subscribers: [ActorAddress: ActorRef<ClusterEvent>] = [:]

                let behavior: Behavior<EventStreamShell.Message<ClusterEvent>> = .receiveMessage { message in
                    switch message {
                    case .subscribe(let ref):
                        subscribers[ref.address] = ref
                        context.watch(ref)
                        context.log.trace("Successfully subscribed [\(ref)], offering membership snapshot")
                        ref.tell(.snapshot(snapshot))

                    case .unsubscribe(let ref):
                        if subscribers.removeValue(forKey: ref.address) != nil {
                            context.unwatch(ref)
                            context.log.trace("Successfully unsubscribed [\(ref)]")
                        } else {
                            context.log.warning("Received `.unsubscribe` for non-subscriber [\(ref)]")
                        }

                    case .publish(let event):
                        try snapshot.apply(event: event)

                        for subscriber in subscribers.values {
                            subscriber.tell(event)
                        }
                        context.log.trace("Published event \(event) to \(subscribers.count) subscribers", metadata: [
                            "eventStream/subscribers": Logger.MetadataValue.array(subscribers.map {
                                Logger.MetadataValue.stringConvertible($0.key)
                            }),
                        ])
                    }

                    return .same
                }

                return behavior.receiveSpecificSignal(Signals.Terminated.self) { context, signal in
                    if subscribers.removeValue(forKey: signal.address) != nil {
                        context.log.trace("Removed subscriber [\(signal.address)], because it terminated")
                    } else {
                        context.log.warning("Received unexpected termination signal for non-subscriber [\(signal.address)]")
                    }

                    return .same
                }
            }
        }
    }
}
