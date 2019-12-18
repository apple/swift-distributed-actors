//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonProxy

/// Proxy for `ActorRef<Message>` which is a singleton.
///
/// The underlying `ActorRef` for the singleton might change due to re-allocation, but all of that happens
/// automatically and is transparent to the `ActorRef` holder.
///
/// The proxy has a buffer to hold messages temporarily in case the singleton is not available. The buffer capacity
/// is configurable in `ActorSingletonSettings`. Note that if the buffer becomes full, the *oldest* message
/// would be disposed to allow insertion of the latest message.
internal class ActorSingletonProxy<Message> {
    /// Settings for `ActorSingleton`
    private let settings: ActorSingletonSettings

    /// The `ActorSingletonManager` paired with this proxy
    private let manager: ActorRef<ActorSingletonManager<Message>.ManagerMessage>

    /// The actual, singleton `ActorRef<Message>`
    private var singleton: ActorRef<Message>?

    /// Message buffer in case `singleton` is `nil`
    private let buffer: StashBuffer<Message>

    init(settings: ActorSingletonSettings, manager: ActorRef<ActorSingletonManager<Message>.ManagerMessage>) {
        self.settings = settings
        self.manager = manager
        self.buffer = StashBuffer(capacity: settings.bufferCapacity)
    }

    var behavior: Behavior<Message> {
        .setup { context in
            // This is how the proxy receives update from manager on singleton ref changes
            let singletonSubReceive = context.subReceive(SubReceiveId(id: "ref-\(context.name)"), ActorRef<Message>?.self) {
                self.updateSingleton(context, $0)
            }
            // Link manager and proxy
            self.manager.tell(.linkProxy(singletonSubReceive))

            // Stop myself if manager terminates
            _ = context.watch(self.manager)

            return Behavior<Message>.receiveMessage { message in
                try self.forwardOrStash(context, message: message)
                return .same
            }.receiveSpecificSignal(Signals.Terminated.self) { context, signal in
                if self.manager.address == signal.address {
                    context.log.error("Stopping myself because manager [\(signal.address)] terminated")
                    return .stop
                }
                context.log.warning("Received unexpected termination signal for non-manager [\(signal.address)]")
                return .same
            }
        }
    }

    private func updateSingleton(_ context: ActorContext<Message>, _ newSingleton: ActorRef<Message>?) {
        context.log.debug("Updating singleton ref from [\(String(describing: self.singleton))] to [\(String(describing: newSingleton))]")
        self.singleton = newSingleton

        // Unstash messages if we have the singleton
        if let singleton = self.singleton {
            while let stashed = self.buffer.take() {
                singleton.tell(stashed)
            }
        }
    }

    private func forwardOrStash(_ context: ActorContext<Message>, message: Message) throws {
        // Forward the message if `singleton` is not `nil`, else stash it.
        if let singleton = self.singleton {
            singleton.tell(message)
        } else {
            if self.buffer.isFull {
                // TODO: log this warning only "once in while" after buffer becomes full
                context.log.warning("Buffer is full. Messages might start getting disposed.", metadata: self.metadata(context))
                // Move the oldest message to dead letters to make room
                if let oldestMessage = self.buffer.take() {
                    context.system.deadLetters.tell(DeadLetter(oldestMessage, recipient: context.address))
                }
            }

            try self.buffer.stash(message: message)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonProxy + logging

extension ActorSingletonProxy {
    func metadata<Message>(_: ActorContext<Message>) -> Logger.Metadata {
        [
            "name": "\(self.settings.name)",
            "buffer": "\(self.buffer.count)/\(self.settings.bufferCapacity)",
        ]
    }
}
