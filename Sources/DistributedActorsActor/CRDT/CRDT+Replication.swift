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

// TODO: instance+shell pattern (https://github.com/apple/swift-distributed-actors/pull/870#discussion_r2003176)

// TODO: gossip. always send full CRDT, even for delta-CRDT. (https://github.com/apple/swift-distributed-actors/pull/787#issuecomment-4274783)
// TODO: when to call `resetDelta` on delta-CRDTs stored in Replicator? after gossip? (https://github.com/apple/swift-distributed-actors/pull/831#discussion_r1969174)
// TODO: reduce CRDT state size by pruning replicas associated with removed nodes; listen to membership changes

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Message protocol for interacting with `Replicator`

extension CRDT {
    internal enum ReplicationProtocol {
        // The API for CRDT owner (e.g., actor) to call local replicator
        case ownerCommand(OwnerCommand)
        // Replication-related operations within the cluster and sent by local replicator to remote replicator
        case clusterCommand(ClusterCommand)
        // For querying local replicator's state, etc.
        case query(Query)

        enum OwnerCommand: NoSerializationVerification {
            // Register owner for CRDT
            case register(ownerRef: ActorRef<ReplicatedDataOwnerProtocol>, id: Identity, data: ReplicatedData, replyTo: ActorRef<RegisterResult>)

            // Perform write to at least `consistency` members
            // `data` is expected to be the full CRDT. Don't send delta even if it is a delta-CRDT.
            case write(id: Identity, data: ReplicatedData, consistency: OperationConsistency, ownerRef: ActorRef<ReplicatedDataOwnerProtocol>, replyTo: ActorRef<WriteResult>)
            // Perform read from at least `consistency` members
            case read(id: Identity, consistency: OperationConsistency, ownerRef: ActorRef<ReplicatedDataOwnerProtocol>, replyTo: ActorRef<ReadResult>)
            // Perform delete to at least `consistency` members
            case delete(id: Identity, consistency: OperationConsistency, ownerRef: ActorRef<ReplicatedDataOwnerProtocol>, replyTo: ActorRef<DeleteResult>)

            enum RegisterResult {
                case success
                case failed(RegisterError)
            }

            enum RegisterError: Error {
                case inputAndStoredDataTypeMismatch(stored: AnyMetaType)
                case unsupportedCRDT
            }

            enum WriteResult {
                // TODO: should this return the underlying CRDT like `read` does?
                case success
                case failed(WriteError)
            }

            enum WriteError: Error {
                case inputAndStoredDataTypeMismatch(stored: AnyMetaType)
                case deltaCRDTHasNotBeenChanged
                case unsupportedCRDT
            }

            enum ReadResult {
                // Returns the underlying CRDT
                case success(StateBasedCRDT)
                case failed(ReadError)
            }

            enum ReadError: Error {
                case notFound
            }

            enum DeleteResult {
                case success
                case failed(DeleteError)
            }

            enum DeleteError: Error {
            }
        }

        enum ClusterCommand {
            // Sent from one replicator to another to write the given CRDT as part of `OwnerCommand.write` to meet consistency requirement
            case write(id: Identity, data: ReplicatedData, replyTo: ActorRef<WriteResult>)
            // Sent from one replicator to another to write the given delta of delta-CRDT as part of `OwnerCommand.write` to meet consistency requirement
            case writeDelta(id: Identity, delta: ReplicatedData, replyTo: ActorRef<WriteResult>)
            // Sent from one replicator to another to read CRDT with the given identity as part of `OwnerCommand.read` to meet consistency requirement
            case read(id: Identity, replyTo: ActorRef<ReadResult>)
            // Sent from one replicator to another to delete CRDT with the given identity as part of `OwnerCommand.delete` to meet consistency requirement
            case delete(id: Identity, replyTo: ActorRef<DeleteResult>)

            enum WriteResult {
                case success
                case failed(WriteError)
            }

            enum WriteError: Error {
                case missingCRDTForDelta
                case incorrectDeltaType(expected: AnyMetaType)
                case cannotWriteDeltaForNonDeltaCRDT
                case inputAndStoredDataTypeMismatch(stored: AnyMetaType)
                case unsupportedCRDT
            }

            enum ReadResult {
                case success(ReplicatedData)
                case failed(ReadError)
            }

            enum ReadError: Error {
                case notFound
            }

            enum DeleteResult {
                case success
                case failed
            }
        }

        enum Query {
        }
    }
}

extension CRDT.ReplicationProtocol.OwnerCommand.RegisterError: Equatable {
    public static func ==(lhs: CRDT.ReplicationProtocol.OwnerCommand.RegisterError, rhs: CRDT.ReplicationProtocol.OwnerCommand.RegisterError) -> Bool {
        switch (lhs, rhs) {
        case let (.inputAndStoredDataTypeMismatch(lt), .inputAndStoredDataTypeMismatch(rt)):
            return lt.asHashable() == rt.asHashable()
        case (.unsupportedCRDT, .unsupportedCRDT):
            return true
        default:
            return false
        }
    }
}

extension CRDT.ReplicationProtocol.OwnerCommand.WriteError: Equatable {
    public static func ==(lhs: CRDT.ReplicationProtocol.OwnerCommand.WriteError, rhs: CRDT.ReplicationProtocol.OwnerCommand.WriteError) -> Bool {
        switch (lhs, rhs) {
        case let (.inputAndStoredDataTypeMismatch(lt), .inputAndStoredDataTypeMismatch(rt)):
            return lt.asHashable() == rt.asHashable()
        case (.deltaCRDTHasNotBeenChanged, .deltaCRDTHasNotBeenChanged):
            return true
        case (.unsupportedCRDT, .unsupportedCRDT):
            return true
        default:
            return false
        }
    }
}

extension CRDT.ReplicationProtocol.ClusterCommand.WriteError: Equatable {
    public static func ==(lhs: CRDT.ReplicationProtocol.ClusterCommand.WriteError, rhs: CRDT.ReplicationProtocol.ClusterCommand.WriteError) -> Bool {
        switch (lhs, rhs) {
        case (.missingCRDTForDelta, .missingCRDTForDelta):
            return true
        case let (.incorrectDeltaType(lt), .incorrectDeltaType(rt)):
            return lt.asHashable() == rt.asHashable()
        case (.cannotWriteDeltaForNonDeltaCRDT, .cannotWriteDeltaForNonDeltaCRDT):
            return true
        case let (.inputAndStoredDataTypeMismatch(lt), .inputAndStoredDataTypeMismatch(rt)):
            return lt.asHashable() == rt.asHashable()
        case (.unsupportedCRDT, .unsupportedCRDT):
            return true
        default:
            return false
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Replicator

extension CRDT {
    // Replicator works with type-erased CRDTs (i.e., `AnyCvRDT`, `AnyDeltaCRDT`) because protocols `CvRDT` and
    // `DeltaCRDT` can be used as generic constraint only due to `Self` or associated type requirements.
    internal typealias ReplicatedData = AnyStateBasedCRDT

    internal struct Replicator {
        typealias OwnerProtocol = ReplicatedDataOwnerProtocol

        internal static let name: String = "replicator" // TODO make an ActorName

        static func behavior() -> Behavior<ReplicationProtocol> {
            return Replicator().behavior(state: State())
        }

        struct State {
            // CRDT store
            var dataStore: [Identity: ReplicatedData] = [:]
            // TODO: tombstone should have TTL
            // Tombstones for deleted CRDTs
            var tombstones: Set<Identity> = []
            // CRDTs and their actor owners
            var owners: [Identity: Set<ActorRef<OwnerProtocol>>] = [:]

            func copy(dataStore: [Identity: ReplicatedData]? = nil, tombstones: Set<Identity>? = nil, owners: [Identity: Set<ActorRef<OwnerProtocol>>]? = nil) -> State {
                return State(dataStore: dataStore ?? self.dataStore, tombstones: tombstones ?? self.tombstones, owners: owners ?? self.owners)
            }
        }

        private func behavior(state: State) -> Behavior<ReplicationProtocol> {
            return .receive { context, message in
                switch message {
                case .ownerCommand(let command):
                    return self.receiveOwnerCommand(context, state: state, command: command)
                case .clusterCommand(let command):
                    return self.receiveClusterCommand(context, state: state, command: command)
                case .query(let query):
                    return self.receiveQuery(context, state: state, query: query)
                }
            }
        }

        private func receiveOwnerCommand(_ context: ActorContext<ReplicationProtocol>, state: State, command: ReplicationProtocol.OwnerCommand) -> Behavior<ReplicationProtocol> {
            switch command {
            case .register(let ownerRef, let id, let data, let replyTo):
                // Change to mutable since we will update it
                var dataStore = state.dataStore

                // TODO: should we also write CRDT to local store during registration? if we don't do that the problem
                // is that `.notFound` error will be returned for `read`.
                // Update local store
                switch dataStore[id] {
                case .none: // New CRDT; just add to store
                    // TODO: check tombstone with same id
                    dataStore[id] = data
                    replyTo.tell(.success)
                case .some(let stored):
                    // The logic is the same for both CvRDT and delta-CRDT since input is a full CRDT:
                    // 1. validate data type
                    // 2. call `merge` and update data store
                    switch stored {
                    case var stored as AnyCvRDT:
                        guard let input = data as? AnyCvRDT, stored.metaType.asHashable() == input.metaType.asHashable() else {
                            replyTo.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored.metaType)))
                            return .same
                        }
                        stored.merge(other: input)
                        dataStore[id] = stored
                    case var stored as AnyDeltaCRDT:
                        guard let input = data as? AnyDeltaCRDT, stored.metaType.asHashable() == input.metaType.asHashable() else {
                            replyTo.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored.metaType)))
                            return .same
                        }
                        stored.merge(other: input)
                        dataStore[id] = stored
                    default:
                        replyTo.tell(.failed(.unsupportedCRDT))
                        return .same
                    }
                }

                // Change to mutable since we will update it
                var owners = state.owners
                // Add to owner set for the CRDT
                var ownersForId = owners[id, default: Set<ActorRef<OwnerProtocol>>()]
                ownersForId.insert(ownerRef)
                owners[id] = ownersForId

                // We are essentially initializing local store with the CRDT. There is no need to send `.updated` to
                // owners or propagate change to the cluster (i.e., local only).

                return self.behavior(state: state.copy(dataStore: dataStore, owners: owners))
            case .write(let id, let data, let consistency, let ownerRef, let replyTo):
                // Change to mutable since we will update it
                var dataStore = state.dataStore

                // Update local store
                switch dataStore[id] {
                case .none: // New CRDT; just add to store
                    var data = data
                    if var deltaCRDT = data as? AnyDeltaCRDT {
                        deltaCRDT.resetDelta()
                        data = deltaCRDT
                    }
                    // TODO: check tombstone with same id
                    dataStore[id] = data
                case .some(let stored):
                    // Update existing CRDT in store
                    switch stored {
                    case var stored as AnyDeltaCRDT:
                        guard let input = data as? AnyDeltaCRDT, stored.metaType.asHashable() == input.metaType.asHashable() else {
                            replyTo.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored.metaType)))
                            return .same
                        }
                        guard let delta = input.delta else {
                            replyTo.tell(.failed(.deltaCRDTHasNotBeenChanged))
                            return .same
                        }
                        stored.mergeDelta(delta)
                        dataStore[id] = stored
                    case var stored as AnyCvRDT:
                        guard let input = data as? AnyCvRDT, stored.metaType.asHashable() == input.metaType.asHashable() else {
                            replyTo.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored.metaType)))
                            return .same
                        }
                        stored.merge(other: input)
                        dataStore[id] = stored
                    default:
                        replyTo.tell(.failed(.unsupportedCRDT))
                        return .same
                    }
                }

                // Propagate change to the cluster if needed
                switch consistency {
                case .local: // We are done
                    replyTo.tell(.success)
                case .atLeast, .quorum, .all:
                    // TODO: send update to a subset of remote replicators based on consistency then send reply
                    // if CvRDT send full CRDT (`ClusterCommand.write`); if DeltaCRDT send data.delta (not replicator's
                    // delta, but the received CRDT's) (`ClusterCommand.writeDelta`)
                    // if CRDT is new locally, send full regardless if it's a DeltaCRDT. the id might be unknown to
                    // remote replicator as well and sending just the delta would not work in that case.
                    replyTo.tell(.success)
                }

                // Notify owners about the change
                self.sendUpdate(on: id, data: dataStore[id]!, to: state.owners[id, default: []], triggeredBy: ownerRef) // ! safe since write has just been performed

                return self.behavior(state: state.copy(dataStore: dataStore))
            case .read(let id, let consistency, let ownerRef, let replyTo):
                switch consistency {
                case .local:
                    guard let stored = state.dataStore[id] else {
                        replyTo.tell(.failed(.notFound))
                        return .same
                    }

                    replyTo.tell(.success(stored.underlying))

                    return .same
                case .atLeast, .quorum, .all:
                    // TODO: read (ClusterCommand.read) from a subset of remote replicators based on consistency then send reply
                    // remote replicator sends full CRDT

                    // Change to mutable since we will update it
                    var dataStore = state.dataStore

                    // TODO: local merge of all responses
                    // TODO: update CRDT in dataStore
                    // TODO: insert real implementation then delete this code
                    guard let stored = state.dataStore[id] else {
                        replyTo.tell(.failed(.notFound))
                        return .same
                    }
                    replyTo.tell(.success(stored.underlying))

                    // Notify owners about the change
                    // TODO: this notifies owners even when the CRDT hasn't changed
                    self.sendUpdate(on: id, data: dataStore[id]!, to: state.owners[id, default: []], triggeredBy: ownerRef) // ! safe since data store should have just been updated with the latest CRDT

                    return self.behavior(state: state.copy(dataStore: dataStore))
                }
            case .delete(let id, let consistency, let ownerRef, let replyTo):
                // Change to mutable since we will update it
                var dataStore = state.dataStore
                var tombstones = state.tombstones

                // Update local store
                dataStore.removeValue(forKey: id)
                tombstones.insert(id)

                // Propagate change to the cluster if needed
                switch consistency {
                case .local:
                    replyTo.tell(.success)
                case .atLeast, .quorum, .all:
                    // TODO: send delete (ClusterCommand.delete) to a subset of remote replicators based on consistency then send reply
                    replyTo.tell(.success)
                }

                // Notify owners about the deletion
                self.sendDeletion(of: id, to: state.owners[id, default: []], triggeredBy: ownerRef)

                return self.behavior(state: state.copy(dataStore: dataStore, tombstones: tombstones))
            }
        }

        private func receiveClusterCommand(_ context: ActorContext<ReplicationProtocol>, state: State, command: ReplicationProtocol.ClusterCommand) -> Behavior<ReplicationProtocol> {
            switch command {
            case .write(let id, let data, let replyTo):
                // Change to mutable since we will update it
                var dataStore = state.dataStore

                // Update local store
                switch dataStore[id] {
                case .none: // New CRDT; just add to store
                    // TODO: check tombstone with same id
                    dataStore[id] = data
                    replyTo.tell(.success)
                case .some(let stored):
                    // The logic is the same for both CvRDT and delta-CRDT since input is a full CRDT:
                    // 1. validate data type
                    // 2. call `merge` and update data store
                    switch stored {
                    case var stored as AnyCvRDT:
                        guard let input = data as? AnyCvRDT, stored.metaType.asHashable() == input.metaType.asHashable() else {
                            replyTo.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored.metaType)))
                            return .same
                        }
                        stored.merge(other: input)
                        dataStore[id] = stored
                    case var stored as AnyDeltaCRDT:
                        guard let input = data as? AnyDeltaCRDT, stored.metaType.asHashable() == input.metaType.asHashable() else {
                            replyTo.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored.metaType)))
                            return .same
                        }
                        stored.merge(other: input)
                        dataStore[id] = stored
                    default:
                        replyTo.tell(.failed(.unsupportedCRDT))
                        return .same
                    }
                }

                replyTo.tell(.success)

                // Notify owners about the change
                self.sendUpdate(on: id, data: dataStore[id]!, to: state.owners[id, default: []]) // ! safe since write has just been performed

                return self.behavior(state: state.copy(dataStore: dataStore))
            case .writeDelta(let id, let delta, let replyTo):
                // Change to mutable since we will update it
                var dataStore = state.dataStore

                // Update local store
                switch dataStore[id] {
                case .none:
                    // Can't do anything if delta (i.e., partial state) is sent and full CRDT is unknown.
                    // Full CRDT will be obtained through gossiping.
                    // TODO: or send reply requesting for the full CRDT?
                    replyTo.tell(.failed(.missingCRDTForDelta))
                    return .same
                case .some(let stored):
                    switch stored {
                    // Existing CRDT in store better be delta-CRDT
                    case var stored as AnyDeltaCRDT:
                        guard let delta = delta as? AnyCvRDT, stored.deltaMetaType.asHashable() == delta.metaType.asHashable() else {
                            replyTo.tell(.failed(.incorrectDeltaType(expected: stored.deltaMetaType)))
                            return .same
                        }
                        stored.mergeDelta(delta)
                        dataStore[id] = stored
                    // `writeDelta` should not be used for non-delta-CRDT
                    default:
                        replyTo.tell(.failed(.cannotWriteDeltaForNonDeltaCRDT))
                        return .same
                    }
                }

                replyTo.tell(.success)

                // Notify owners about the change
                self.sendUpdate(on: id, data: dataStore[id]!, to: state.owners[id, default: []]) // ! safe since write has just been performed

                return self.behavior(state: state.copy(dataStore: dataStore))
            case .read(let id, let replyTo):
                guard let stored = state.dataStore[id] else {
                    replyTo.tell(.failed(.notFound))
                    return .same
                }
                // Send full CRDT back
                replyTo.tell(.success(stored))

                // Read-only command; state doesn't change
                return .same
            case .delete(let id, let replyTo):
                // Change to mutable since we will update it
                var dataStore = state.dataStore
                var tombstones = state.tombstones

                // Update local store
                dataStore.removeValue(forKey: id)
                tombstones.insert(id)

                replyTo.tell(.success)

                // Notify owners about the deletion
                self.sendDeletion(of: id, to: state.owners[id, default: []])

                return self.behavior(state: state.copy(dataStore: dataStore, tombstones: tombstones))
            }
        }

        private func receiveQuery(_ context: ActorContext<ReplicationProtocol>, state: State, query: ReplicationProtocol.Query) -> Behavior<ReplicationProtocol> {
            return .same
        }

        private func sendUpdate(on id: Identity, data: ReplicatedData, to owners: Set<ActorRef<OwnerProtocol>>, triggeredBy ownerRef: ActorRef<OwnerProtocol>? = nil) {
            for owner in owners {
                owner.tell(.updated(data.underlying))
            }
        }

        private func sendDeletion(of id: Identity, to owners: Set<ActorRef<OwnerProtocol>>, triggeredBy ownerRef: ActorRef<OwnerProtocol>? = nil) {
            for owner in owners {
                owner.tell(.deleted)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Messages sent by replicator to CRDT owner

extension CRDT {
    internal enum ReplicatedDataOwnerProtocol {
        case updated(StateBasedCRDT)
        case deleted
    }
}
