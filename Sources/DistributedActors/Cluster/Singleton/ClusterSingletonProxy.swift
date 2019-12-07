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

internal class ClusterSingletonProxy<Message> {
    private let settings: ClusterSingleton.Settings

    private let managerRef: ActorRef<ClusterSingletonManager<Message>.ManagerMessage>

    private var singleton: ActorRef<Message>?

    private let buffer: StashBuffer<Message>

    init(settings: ClusterSingleton.Settings, managerRef: ActorRef<ClusterSingletonManager<Message>.ManagerMessage>) {
        self.settings = settings
        self.managerRef = managerRef
        self.buffer = StashBuffer(capacity: settings.bufferSize)
    }

    var behavior: Behavior<Message> {
        .setup { context in
            let singletonSubReceive = context.subReceive(ActorRef<Message>?.self) {
                self.singleton = $0

                // Process stashed messages once we have the singleton
                if let singleton = self.singleton {
                    while let stashed = self.buffer.buffer.take() {
                        singleton.tell(stashed)
                    }
                }
            }
            self.managerRef.tell(.registerProxy(singletonSubReceive))

            return .receiveMessage { message in
                try self.tellOrStash(message: message)
                return .same
            }
        }
    }

    private func tellOrStash(message: Message) throws {
        // If `singleton` is set, forward the message. Else stash it.
        if let singleton = self.singleton {
            singleton.tell(message)
        } else {
            if self.buffer.buffer.isFull {
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
            "buffer": "\(self.buffer.count)/\(self.settings.bufferSize)",
        ]
    }
}
