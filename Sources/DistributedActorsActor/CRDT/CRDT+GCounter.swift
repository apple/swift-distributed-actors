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

extension CRDT {
    public struct GCounter: DeltaCRDT, NamedCRDT {
        public let replicaId: ReplicaId

        let id: Identity

        // State is a dictionary of replicas and the counter values they've observed.
        var state: [ReplicaId: Int]

        var delta: Delta?

        var value: Int {
            return state.values.reduce(0, +)
        }

        init(replicaId: ReplicaId, id: Identity, state: [ReplicaId: Int] = [:], delta: Delta? = nil) {
            self.replicaId = replicaId
            self.id = id
            self.state = state
            self.delta = delta
        }

        mutating func increment(by amount: Int) {
            precondition(amount > 0, "Amount must be greater than 0")

            let newCount: Int
            if let currentCount = state[replicaId] {
                // TODO: handle overflow (use currentCount.addingReportingOverflow)
                newCount = currentCount + amount
            } else {
                newCount = amount
            }

            // Update state
            state[replicaId] = newCount

            // Update/create delta
            switch delta {
            case .some(var delta):
                delta.state[replicaId] = newCount
            case .none:
                delta = Delta(state: [replicaId: newCount])
            }
        }

        // To merge delta into state, call `mergeDelta`.
        mutating public func merge(other: GCounter) -> GCounter {
            state.merge(other.state, uniquingKeysWith: max)
            return self
        }

        mutating public func mergeDelta(_ delta: Delta) -> GCounter {
            state.merge(delta.state, uniquingKeysWith: max)
            return self
        }

        mutating public func resetDelta() -> GCounter {
            delta = nil
            return self
        }

        // TODO: delete?
        public func delta(other: GCounter) -> Delta {
            // Compute delta across all replicas, not just self's.
            // This is because a replicator-owned instance might include changes from multiple
            // local actors (i.e., there are multiple local `ActorOwned`s for the same `GCounter`).
            // Each actor has a different `ReplicaId`, including the replicator itself, so when we compute
            // the delta to send to remote replicators, we need to look at all replicas.
            var replicaIds = Set<ReplicaId>(state.keys)
            replicaIds.formUnion(other.state.keys)

            var deltaState = Dictionary<ReplicaId, Int>(minimumCapacity: replicaIds.count)

            for replicaId in replicaIds {
                let (thisCount, otherCount) = (state[replicaId], other.state[replicaId])

                switch (thisCount, otherCount) {
                case (.some(let thisCount), .some(let otherCount)) where thisCount == otherCount:
                    // No change, exclude from delta
                    continue
                case (.some(let thisCount), .some(let otherCount)):
                    deltaState[replicaId] = max(thisCount, otherCount)
                case (.some(let thisCount), .none):
                    deltaState[replicaId] = thisCount
                case (.none, .some(let otherCount)):
                    deltaState[replicaId] = otherCount
                case (.none, .none):
                    // Hmm, if neither self.state nor other.state has value then this key shouldn't exist
                    continue
                }
            }

            return Delta(state: deltaState)
        }

        public struct Delta: CvRDT {
            // State is a dictionary of replicas and their counter values.
            var state: [ReplicaId: Int]

            init(state: [ReplicaId: Int] = [:]) {
                self.state = state
            }

            mutating public func merge(other: Delta) -> Delta {
                state.merge(other.state, uniquingKeysWith: max)
                return self
            }
        }
    }
}

extension CRDT.ActorOwned where DataType == CRDT.GCounter {
    public var lastObservedValue: Int {
        return self.data.value
    }

    mutating public func increment(by amount: Int, writeConsistency consistency: CRDT.OperationConsistency) -> CRDT.Result<DataType> {
        // perform write locally
        self.data.increment(by: amount)

        return self.owner.write(self.data, consistency: consistency)

        // effectively something like this most likely (types may become weird internally):
        //   (or maybe first get the delta and only send the delta to replicator?)
        //
        // let answer = self.owner.replicator.ask(for: CRDT.AnyWriteResult.self) { replyTo in
        //    CRDT.WriteRequest(self.datatype, consistency: consistency)
        // }
        // return CRDT.WriteResult(answer)
        //
        // (the returning like that there some type flattening to be done here since we'd get `Answer<CRDT.WriteResult<Self>>`)
    }

    public func read(atConsistency consistency: CRDT.OperationConsistency) -> CRDT.Result<DataType> {
        fatalError("read to be implemented")
        // TODO: handle consistency
        // if local: just return
        // if querying: self.owner.replicator.ask ... similar to the write

        // return .init()
    }
}

extension CRDT.GCounter {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String) -> CRDT.ActorOwned<CRDT.GCounter> {
        return .init(owner: owner, data: CRDT.GCounter(replicaId: .actorAddress(owner.address), id: CRDT.Identity(id)))
    }
}

// TODO: find better home for these type aliases
typealias GrowOnlyCounter = CRDT.GCounter
