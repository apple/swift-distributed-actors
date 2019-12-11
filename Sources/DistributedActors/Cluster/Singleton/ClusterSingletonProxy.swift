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

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterSingletonProxy

/// Proxy for `ActorRef<Message>` which is a cluster singleton.
///
/// The underlying `ActorRef` for the singleton might change due to re-allocation, but all of that happens
/// automatically and is transparent to the `ActorRef` holder.
///
/// The proxy has a buffer to hold messages temporarily in case the singleton is not available. The buffer capacity
/// is configurable in `ClusterSingletonSettings`. Note that if the buffer becomes full, the *oldest* message
/// would be disposed to allow insertion of the latest message.
internal class ClusterSingletonProxy<Message> {
    /// Cluster singleton settings
    private let settings: ClusterSingletonSettings

    /// The `ClusterSingletonManager` paired with this proxy
    private let manager: ActorRef<ClusterSingletonManager<Message>.ManagerMessage>

    /// The actual, singleton `ActorRef<Message>`
    private var singleton: ActorRef<Message>?

    /// Message buffer in case `singleton` is `nil`
    private let buffer: StashBuffer<Message>
    /// Whether the buffer capacity has been reached and messages starting to get discarded
    private var bufferOverflow: Bool = false

    init(settings: ClusterSingletonSettings, manager: ActorRef<ClusterSingletonManager<Message>.ManagerMessage>) {
        self.settings = settings
        self.manager = manager
        self.buffer = StashBuffer(capacity: settings.bufferCapacity)
    }

    var behavior: Behavior<Message> {
        .setup { context in
            // This is how the proxy receives update from manager on singleton ref changes
            let singletonSubReceive = context.subReceive(ActorRef<Message>?.self) {
                self.updateSingleton($0)
            }
            // Link manager and proxy
            self.manager.tell(.linkProxy(singletonSubReceive))

            return .receiveMessage { message in
                try self.forwardOrStash(context, message: message)
                return .same
            }
        }
    }

    private func updateSingleton(_ newSingleton: ActorRef<Message>?) {
        self.singleton = newSingleton

        // Empty stashed messages if we have the singleton
        if let singleton = self.singleton {
            while let stashed = self.buffer.buffer.take() {
                singleton.tell(stashed)
            }
            self.bufferOverflow = false // Reset
        }
    }

    private func forwardOrStash(_ context: ActorContext<Message>, message: Message) throws {
        // Forward the message if `singleton` is not `nil`, else stash it.
        if let singleton = self.singleton {
            singleton.tell(message)
        } else {
            if self.buffer.buffer.isFull {
                if !self.bufferOverflow {
                    context.log.warning("Buffer is full. Messages might start getting disposed.", metadata: self.metadata(context))
                    self.bufferOverflow = true // Set flag so we only warn once
                }
                // Delete the oldest message to make room
                _ = self.buffer.buffer.take()
            }

            try self.buffer.stash(message: message)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterSingletonProxy + logging

extension ClusterSingletonProxy {
    func metadata<Message>(_: ActorContext<Message>) -> Logger.Metadata {
        [
            "name": "\(self.settings.name)",
            "buffer": "\(self.buffer.count)/\(self.settings.bufferCapacity)",
        ]
    }
}
