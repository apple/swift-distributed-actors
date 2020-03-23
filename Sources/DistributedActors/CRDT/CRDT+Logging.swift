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
// MARK: ActorOwned + Logger Metadata

extension CRDT.ActorOwned {
    func metadata() -> Logger.Metadata {
        [
            "crdt/id": "\(self.id.id)",
            "crdt/status": "\(self.status)",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GCounter + Logger Metadata

extension CRDT.GCounter {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        [
            "crdt/type": "gcounter",
            "crdt/owner": "\(context.address)",
            "crdt/replicaId": "\(self.replicaId)",
            "crdt/gcounter/value": "\(self.value)",
            "crdt/gcounter/delta": "\(String(describing: self.delta))",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LWWMap + Logger Metadata

extension CRDT.LWWMap {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        [
            "crdt/type": "lwwmap",
            "crdt/owner": "\(context.address)",
            "crdt/replicaId": "\(self.replicaId)",
            "crdt/lwwmap/count": "\(self.count)",
            "crdt/lwwmap/delta": "\(String(describing: self.delta))",
        ]
    }
}

//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: LWWRegister + Logger Metadata
//
extension CRDT.LWWRegister {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        [
            "crdt/type": "lwwregister",
            "crdt/owner": "\(context.address)",
            "crdt/replicaId": "\(self.replicaId)",
            "crdt/lwwreg/value": "\(self.value)",
            "crdt/lwwreg/clock": "\(self.clock)",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ORSet + Logger Metadata

extension CRDT.ORSet {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        [
            "crdt/type": "orset",
            "crdt/owner": "\(context.address)",
            "crdt/replicaId": "\(self.replicaId)",
            "crdt/orset/count": "\(self.count)",
            "crdt/orset/delta": "\(String(describing: self.delta))",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ORMap + Logger Metadata

extension CRDT.ORMap {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        [
            "crdt/type": "ormap",
            "crdt/owner": "\(context.address)",
            "crdt/replicaId": "\(self.replicaId)",
            "crdt/ormap/count": "\(self.count)",
            "crdt/ormap/delta": "\(String(describing: self.delta))",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator.Shell + Logger Metadata

extension CRDT.Replicator.Shell {
    func metadata<Message>(_ context: ActorContext<Message>) -> Logger.Metadata {
        [
            "crdt/replicator": "\(context.path)",
            "crdt/replicator/remoteReplicators": "\(self.remoteReplicators)",
        ]
    }
}
