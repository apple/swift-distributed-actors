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
// TODO: gossip. always send full CRDT, even for delta-CRDT. (https://github.com/apple/swift-distributed-actors/pull/787#issuecomment-4274783)
// TODO: when to call `resetDelta` on delta-CRDTs stored in Replicator? after gossip? (https://github.com/apple/swift-distributed-actors/pull/831#discussion_r1969174)
// TODO: reduce CRDT state size by pruning replicas associated with removed nodes; listen to membership changes
import Logging

extension CRDT {
    internal enum Replication {
        // Replicator works with type-erased CRDTs (i.e., `AnyCvRDT`, `AnyDeltaCRDT`) because protocols `CvRDT` and
        // `DeltaCRDT` can be used as generic constraint only due to `Self` or associated type requirements.
        typealias Data = AnyStateBasedCRDT

        // Messages from replicator to CRDT instance owner
        internal enum DataOwnerMessage {
            /// Sent when the CRDT instance has been updated. The update could have been issued locally by the same or
            /// another owner, or remotely then synchronized to this replicator.
            case updated(StateBasedCRDT)

            /// Sent when the CRDT instance has been deleted. The delete could have been issued locally by the same or
            /// another owner, or remotely then synchronized to this replicator.
            case deleted
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Message protocol for interacting with replicator

extension CRDT {
    internal enum Replicator {
        static let naming: ActorNaming = "replicator"

        enum Message {
            // The API for CRDT instance owner (e.g., actor) to call local replicator
            case localCommand(LocalCommand)
            // Replication-related operations within the cluster and sent by local replicator to remote replicator
            case remoteCommand(RemoteCommand)
        }

        enum LocalCommand: NoSerializationVerification {
            // Register owner for CRDT instance
            case register(ownerRef: ActorRef<CRDT.Replication.DataOwnerMessage>, id: Identity, data: AnyStateBasedCRDT, replyTo: ActorRef<RegisterResult>?)

            // Perform write to at least `consistency` members
            // `data` is expected to be the full CRDT. Do not send delta even if it is a delta-CRDT.
            case write(_ id: Identity, _ data: AnyStateBasedCRDT, consistency: OperationConsistency, replyTo: ActorRef<WriteResult>)
            // Perform read from at least `consistency` members
            case read(_ id: Identity, consistency: OperationConsistency, replyTo: ActorRef<ReadResult>)
            // Perform delete to at least `consistency` members
            case delete(_ id: Identity, consistency: OperationConsistency, replyTo: ActorRef<DeleteResult>)

            enum RegisterResult {
                case success
                case failed(RegisterError)
            }

            enum RegisterError: Error {
                case inputAndStoredDataTypeMismatch(stored: AnyMetaType)
                case unsupportedCRDT
            }

            enum WriteResult {
                case success
                case failed(WriteError)
            }

            enum WriteError: Error {
                case inputAndStoredDataTypeMismatch(stored: AnyMetaType)
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

            enum DeleteError: Error {}
        }

        enum RemoteCommand {
            // Sent from one replicator to another to write the given CRDT instance as part of `OwnerCommand.write` to meet consistency requirement
            case write(_ id: Identity, _ data: AnyStateBasedCRDT, replyTo: ActorRef<WriteResult>)
            // Sent from one replicator to another to write the given delta of delta-CRDT instance as part of `OwnerCommand.write` to meet consistency requirement
            case writeDelta(_ id: Identity, delta: AnyStateBasedCRDT, replyTo: ActorRef<WriteResult>)
            // Sent from one replicator to another to read CRDT instance with the given identity as part of `OwnerCommand.read` to meet consistency requirement
            case read(_ id: Identity, replyTo: ActorRef<ReadResult>)
            // Sent from one replicator to another to delete CRDT instance with the given identity as part of `OwnerCommand.delete` to meet consistency requirement
            case delete(_ id: Identity, replyTo: ActorRef<DeleteResult>)

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
                case success(AnyStateBasedCRDT)
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
    }
}

extension CRDT.Replicator.LocalCommand.RegisterError: Equatable {
    public static func == (lhs: CRDT.Replicator.LocalCommand.RegisterError, rhs: CRDT.Replicator.LocalCommand.RegisterError) -> Bool {
        switch (lhs, rhs) {
        case (.inputAndStoredDataTypeMismatch(let lt), .inputAndStoredDataTypeMismatch(let rt)):
            return lt.asHashable() == rt.asHashable()
        case (.unsupportedCRDT, .unsupportedCRDT):
            return true
        default:
            return false
        }
    }
}

extension CRDT.Replicator.LocalCommand.WriteError: Equatable {
    public static func == (lhs: CRDT.Replicator.LocalCommand.WriteError, rhs: CRDT.Replicator.LocalCommand.WriteError) -> Bool {
        switch (lhs, rhs) {
        case (.inputAndStoredDataTypeMismatch(let lt), .inputAndStoredDataTypeMismatch(let rt)):
            return lt.asHashable() == rt.asHashable()
        case (.unsupportedCRDT, .unsupportedCRDT):
            return true
        default:
            return false
        }
    }
}

extension CRDT.Replicator.RemoteCommand.WriteError: Equatable {
    public static func == (lhs: CRDT.Replicator.RemoteCommand.WriteError, rhs: CRDT.Replicator.RemoteCommand.WriteError) -> Bool {
        switch (lhs, rhs) {
        case (.missingCRDTForDelta, .missingCRDTForDelta):
            return true
        case (.incorrectDeltaType(let lt), .incorrectDeltaType(let rt)):
            return lt.asHashable() == rt.asHashable()
        case (.cannotWriteDeltaForNonDeltaCRDT, .cannotWriteDeltaForNonDeltaCRDT):
            return true
        case (.inputAndStoredDataTypeMismatch(let lt), .inputAndStoredDataTypeMismatch(let rt)):
            return lt.asHashable() == rt.asHashable()
        case (.unsupportedCRDT, .unsupportedCRDT):
            return true
        default:
            return false
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Replicator settings

extension CRDT.Replicator {
    public struct Settings {
        /// When enabled traces _all_ replicator messages.
        /// All logs will be prefixed using `[tracelog:replicator]`, for easier grepping and inspecting only logs related to the replicator.
        // TODO: how to make this nicely dynamically changeable during runtime
        #if SACT_TRACE_REPLICATOR
        var traceLogLevel: Logger.Level? = .warning
        #else
        var traceLogLevel: Logger.Level?
        #endif

        // TODO: gossip settings
        public static var `default`: Settings {
            return .init()
        }
    }
}
