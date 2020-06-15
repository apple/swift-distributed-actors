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

// tag::imports[]

import DistributedActors
import Foundation

// end::imports[]

import DistributedActorsTestKit
import XCTest

class Docs_quickstart_types {
    func x(system: ActorSystem) {
        // tag::quickstart_types[]
        let node: UniqueNode = system.cluster.node
        let replicaID: ReplicaID = .uniqueNode(node)

        let set: CRDT.ORSet<String> = CRDT.ORSet(replicaID: replicaID)
        // end::quickstart_types[]
        _ = set

        // compilation sanity checks it works well in a different module
        _ = CRDT.GCounter(replicaID: replicaID)
        _ = CRDT.LWWMap<String, String>(replicaID: replicaID, defaultValue: "Hello")
        _ = CRDT.ORMap<String, CRDT.ORSet<String>>(replicaID: replicaID, defaultValue: CRDT.ORSet<String>(replicaID: replicaID))
        _ = CRDT.ORMultiMap<String, String>(replicaID: replicaID)
        _ = CRDT.LWWRegister<String?>(replicaID: replicaID)
    }
}

// tag::quickstart_owned_actorable[]
enum ShoppingList {
    static let ID = "shopping-list-alice-bob"
}

struct Shopper: Actorable {
    let context: Myself.Context
    let itemsToBuy: CRDT.ActorableOwned<CRDT.ORSet<String>>

    init(context: Myself.Context) {
        self.context = context
        self.itemsToBuy = CRDT.ORSet<String>.makeOwned(by: context, id: ShoppingList.ID) // <1>
    }

    // @actor
    func add(item: String) { /* ... */ }

    // @actor
    func checkOff(item: String) { /* ... */ }
}

// end::quickstart_owned_actorable[]

struct Shopper_2: Actorable {
    // tag::quickstart_direct_write_add[]
    let context: Myself.Context
    let itemsToBuy: CRDT.ActorableOwned<CRDT.ORSet<String>>

    // @actor
    func add(item: String) {
        let write = self.itemsToBuy.insert(
            item, // <1>
            writeConsistency: .local, // <2>
            timeout: .effectivelyInfinite // <3>
        )

        write.onComplete { // <4>
            switch $0 {
            case .success(let updatedSet):
                self.context.log.info("Added \(item) to shopping list: \(updatedSet)")
            case .failure(let error):
                self.context.log.warning("Unexpected error: \(error)")
            }
        }
    }

    // end::quickstart_direct_write_add[]

    // tag::quickstart_direct_write_remove[]
    // @actor
    func checkOff(item: String) {
        let write = self.itemsToBuy.remove(item, writeConsistency: .local, timeout: .effectivelyInfinite)

        write.onComplete { _ in
            // ...
        }
    }

    // end::quickstart_direct_write_remove[]
}

func quickstart_alice_bob_writes(oneSystem: ActorSystem, otherSystem: ActorSystem) throws {
    // tag::quickstart_alice_bob_writes[]
    let alice: Actor<Shopper> = try oneSystem.spawn("alice", Shopper.init)
    let bob: Actor<Shopper> = try otherSystem.spawn("bob", Shopper.init)

    // before they go shopping, they add to the shopping list:
    alice.add(item: "apples")
    alice.add(item: "oranges")
    bob.add(item: "coffee")
    bob.add(item: "apples")
    bob.add(item: "water")
    // ...

    // while shopping, they check off items
    bob.checkOff(item: "apples")
    alice.checkOff(item: "oranges")
    // end::quickstart_alice_bob_writes[]
}

func quickstart_bob_onUpdate(context: ActorContext<Never>, itemsToBuy: CRDT.ActorableOwned<CRDT.ORSet<String>>) {
    // tag::quickstart_bob_onUpdate[]
    itemsToBuy.onUpdate { id, updatedSet in
        context.log.info("Someone updated shopping list [\(id)], remaining items to buy: \(updatedSet)")
    }
    // end::quickstart_bob_onUpdate[]
}

func quickstart_peek_state(context: ActorContext<Never>, itemsToBuy: CRDT.ActorableOwned<CRDT.ORSet<String>>) {
    // tag::quickstart_peek_state[]
    let lastSeenValue: Set<String>? = itemsToBuy.lastObservedValue
    // end::quickstart_peek_state[]
    _ = lastSeenValue
}
