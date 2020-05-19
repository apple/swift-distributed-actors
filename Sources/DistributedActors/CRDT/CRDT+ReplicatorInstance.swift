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

extension CRDT.Replicator {
    // TODO: make it Direct Replicator
    internal final class Instance {
        typealias Identity = CRDT.Identity
        typealias OwnerMessage = CRDT.Replication.DataOwnerMessage

        let settings: Settings

        // CRDT store
        private var dataStore: [Identity: StateBasedCRDT] = [:]

        // Tombstones for deleted CRDTs
        // TODO: tombstone should have TTL
        private var tombstones: Set<Identity> = []
        // CRDTs and their actor owners
        private var owners: [Identity: Set<ActorRef<OwnerMessage>>] = [:]

        init(_ settings: Settings) {
            self.settings = settings
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Register CRDT owner

        enum RegisterOwnerDirective {
            case registered
        }

        func registerOwner(dataId: Identity, owner: ActorRef<OwnerMessage>) -> RegisterOwnerDirective {
            // Avoid copy-on-write: remove entry from dictionary before mutating
            var ownersForId = self.owners.removeValue(forKey: dataId) ?? Set<ActorRef<OwnerMessage>>()
            ownersForId.insert(owner)
            self.owners[dataId] = ownersForId

            return .registered
        }

        func owners(for dataId: Identity) -> Set<ActorRef<OwnerMessage>>? {
            self.owners[dataId]
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Write CRDT

        enum WriteDirective {
            // Return the updated full CRDT
            case applied(_ updatedData: StateBasedCRDT, isNew: Bool)

            case inputAndStoredDataTypeMismatch(CRDT.MergeError)
            case unsupportedCRDT
        }

        enum WriteDeltaDirective {
            // Return the updated full CRDT
            case applied(_ updatedData: StateBasedCRDT)

            case missingCRDTForDelta
            case incorrectDeltaType(CRDT.MergeError)
            case cannotWriteDeltaForNonDeltaCRDT
        }

        /// Write full CvRDT or delta-CRDT. For delta-CRDT, this method provides an option to merge only the partial
        /// state (i.e., the delta), which might be used if mutations have been recorded incrementally.
        ///
        /// - Parameter id: Identity of the CRDT.
        /// - Parameter data: The full CRDT to write.
        /// - Parameter deltaMerge: True if merge can be done with the delta only; false if full state merge is required.
        /// - Returns: `WriteDirective` indicating if the write has succeeded or failed.
        func write(_ id: Identity, _ data: StateBasedCRDT, deltaMerge: Bool = true) -> WriteDirective {
            switch self.dataStore[id] {
            case .none: // New CRDT; just add to store

                // FIXME: how to replicate deltas here now that we changed the model
//                var data = data
//
//                // Delta should always be incorporated into CRDT state and therefore not required.
//                // Reset delta to ensure clean slate.
//                if var deltaCRDT = data as? AnyDeltaCRDT {
//                    deltaCRDT.resetDelta()
//                    data = deltaCRDT
//                }

                // TODO: check tombstone with same id
                self.dataStore[id] = data
                return .applied(data, isNew: true)

            case .some(let stored):
                switch stored._tryMerging(other: data) {
                case .success(let merged):
                    self.dataStore[id] = merged
                    return .applied(merged, isNew: false)
                case .failure(let error):
                    return .inputAndStoredDataTypeMismatch(error)
                }
//                switch stored {
//                case var stored as AnyCvRDT:
//                    guard let input = data as? AnyCvRDT, input.metaType.is(stored.metaType) else {
//                        return .inputAndStoredDataTypeMismatch(stored.metaType)
//                    }
//
//                    stored.merge(other: input)
//                    self.dataStore[id] = stored
//
//                    return .applied(stored, isNew: false)
//                case var stored as AnyDeltaCRDT:
//                    guard let input = data as? AnyDeltaCRDT, input.metaType.is(stored.metaType) else {
//                        return .inputAndStoredDataTypeMismatch(stored.metaType)
//                    }
//
//                    if deltaMerge, let delta = input.delta {
//                        stored.mergeDelta(delta)
//                    } else {
//                        // This includes deltaMerge == false, and if input.delta is nil.
//                        // A mutation to delta-CRDT should update both state and delta so `merge` would work as well.
//                        stored.merge(other: input)
//                    }
//                    self.dataStore[id] = stored
//
//                    return .applied(stored, isNew: false)
//                default:
//                    return .unsupportedCRDT
//                }
            }
        }

        /// Write the delta for a delta-CRDT.
        ///
        /// - Parameter id: Identity of the CRDT.
        /// - Parameter delta: The delta of the CRDT.
        /// - Returns: `WriteDeltaDirective` indicating if the write has succeeded or failed.
        func writeDelta(_ id: Identity, _ delta: StateBasedCRDT) -> WriteDeltaDirective {
            switch self.dataStore[id] {
            case .none:
                // Cannot do anything if delta (i.e., partial state) is sent and full CRDT is unknown.
                return .missingCRDTForDelta
            case .some(let stored):
                switch stored._tryMerging(other: delta) {
                case .success(let merged):
                    self.dataStore[id] = merged
                    return .applied(merged)
                case .failure(let error):
                    return .incorrectDeltaType(error)
                }

//                switch stored {
//                case var stored as AnyDeltaCRDT:
//                    // Existing CRDT in store better be delta-CRDT
//                    guard let delta = delta as? _DeltaCRDT, type(of: delta) == stored.deltaMetaType.underlying else {
//                        return .incorrectDeltaType(expected: stored.deltaMetaType)
//                    }
//
//                    stored.mergeDelta(delta as! AnyDeltaCRDT.Delta) // FIXME: THIS IS A HAAAAACK!!!!!!
//                    self.dataStore[id] = stored
//
//                    return .applied(stored)
//                default:
//                    // This method should not be used for non-delta-CRDT
//                    return .cannotWriteDeltaForNonDeltaCRDT
//                }
            }
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Read CRDT

        enum ReadDirective {
            case data(StateBasedCRDT)

            case notFound
        }

        func read(_ id: Identity) -> ReadDirective {
            guard let stored = self.dataStore[id] else {
                return .notFound
            }
            return .data(stored)
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Delete CRDT

        enum DeleteDirective {
            case applied
        }

        func delete(_ id: Identity) -> DeleteDirective {
            self.dataStore.removeValue(forKey: id)
            self.tombstones.insert(id)
            return .applied
        }
    }
}

extension CRDT.Replicator.Instance: CustomDebugStringConvertible {
    public var debugDescription: String {
        "CRDT.Replicator.Instance(dataStore: \(self.dataStore), owners: \(self.owners), tombstones: \(self.tombstones), settings: \(self.settings))"
    }
}
