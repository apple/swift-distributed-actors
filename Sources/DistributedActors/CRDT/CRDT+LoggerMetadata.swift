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

// TODO: add id?

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GCounter + Logger Metadata

extension CRDT.GCounter {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        return [
            "crdt/type": "gcounter",
            "crdt/owner": "\(context.address)",
            "crdt/replicaId": "\(self.replicaId)",
            "crdt/gcounter/value": "\(self.value)",
            "crdt/gcounter/delta": "\(self.delta)",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ORSet + Logger Metadata

extension CRDT.ORSet {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        return [
            "crdt/type": "orset",
            "crdt/owner": "\(context.address)",
            "crdt/replicaId": "\(self.replicaId)",
            "crdt/orset/count": "\(self.count)",
            "crdt/orset/delta": "\(self.delta)",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator.Shell + Logger Metadata

extension CRDT.Replicator.Shell {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        return [
            "crdt/replicator": "\(context.path)",
            "crdt/replicator/remoteReplicators": "\(self.remoteReplicators)",
        ]
    }
}
