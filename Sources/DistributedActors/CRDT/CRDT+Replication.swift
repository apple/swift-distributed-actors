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

// TODO: gossip. always send full CRDT, even for delta-CRDT. (https://github.com/apple/swift-distributed-actors/pull/787#issuecomment-4274783)
// TODO: when to call `resetDelta` on delta-CRDTs stored in Replicator? after gossip? (https://github.com/apple/swift-distributed-actors/pull/831#discussion_r1969174)
// TODO: reduce CRDT state size by pruning replicas associated with removed nodes; listen to membership changes
import Logging
import struct NIO.ByteBuffer

extension CRDT {
    internal enum Replication {
        // Replicator works with type-erased CRDTs (i.e., `AnyCvRDT`, `DeltaCRDTBox`) because protocols `CvRDT` and
        // `DeltaCRDT` can be used as generic constraint only due to `Self` or associated type requirements.
        typealias Data = StateBasedCRDT

        // Messages from replicator to CRDT instance owner
        internal enum DataOwnerMessage: NotTransportableActorMessage {
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
        static let name: String = "replicator"
        static let naming: ActorNaming = .unique(Replicator.name)

        enum Message: ActorMessage {
            // The API for CRDT instance owner (e.g., actor) to call local replicator
            case localCommand(LocalCommand)
            // Replication-related operations within the cluster and sent by local replicator to remote replicator
            case remoteCommand(RemoteCommand)
        }

        enum LocalCommand: NotTransportableActorMessage {
            // Register owner for CRDT instance
            case register(ownerRef: ActorRef<CRDT.Replication.DataOwnerMessage>, id: Identity, data: StateBasedCRDT, replyTo: ActorRef<RegisterResult>?)

            // Perform write to at least `consistency` members
            // `data` is expected to be the full CRDT. Do not send delta even if it is a delta-CRDT.
            case write(_ id: Identity, _ data: StateBasedCRDT, consistency: OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<WriteResult>)
            // Perform read from at least `consistency` members
            case read(_ id: Identity, consistency: OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<ReadResult>)
            // Perform delete to at least `consistency` members
            case delete(_ id: Identity, consistency: OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<DeleteResult>)

            enum RegisterResult: NotTransportableActorMessage {
                case success
                case failure(RegisterError)
            }

            enum RegisterError: Error, NotTransportableActorMessage {
                case inputAndStoredDataTypeMismatch(CRDT.MergeError)
                case unsupportedCRDT
            }

            enum WriteResult: NotTransportableActorMessage {
                case success
                case failure(WriteError)
            }

            enum WriteError: Error, NotTransportableActorMessage {
                case inputAndStoredDataTypeMismatch(CRDT.MergeError)
                case unsupportedCRDT
                case consistencyError(CRDT.OperationConsistency.Error)
            }

            enum ReadResult: NotTransportableActorMessage {
                // Returns the underlying CRDT
                case success(StateBasedCRDT)
                case failure(ReadError)
            }

            enum ReadError: Error, NotTransportableActorMessage {
                case notFound
                case consistencyError(CRDT.OperationConsistency.Error)
            }

            enum DeleteResult: NotTransportableActorMessage {
                case success
                case failure(DeleteError)
            }

            enum DeleteError: Error, NotTransportableActorMessage {
                case consistencyError(CRDT.OperationConsistency.Error)
            }
        }

        enum RemoteCommand: ActorMessage {
            // Sent from one replicator to another to write the given CRDT instance as part of `OwnerCommand.write` to meet consistency requirement
            case write(_ id: Identity, _ data: StateBasedCRDT, replyTo: ActorRef<WriteResult>)
            // Sent from one replicator to another to write the given delta of delta-CRDT instance as part of `OwnerCommand.write` to meet consistency requirement
            case writeDelta(_ id: Identity, delta: StateBasedCRDT, replyTo: ActorRef<WriteResult>) // TODO: can it be one replication write command instead?
            // Sent from one replicator to another to read CRDT instance with the given identity as part of `OwnerCommand.read` to meet consistency requirement
            case read(_ id: Identity, replyTo: ActorRef<ReadResult>)
            // Sent from one replicator to another to delete CRDT instance with the given identity as part of `OwnerCommand.delete` to meet consistency requirement
            case delete(_ id: Identity, replyTo: ActorRef<DeleteResult>)

            enum WriteResult: ActorMessage {
                case success
                case failure(WriteError)
            }

            enum WriteError: Error, ActorMessage {
                case missingCRDTForDelta
                case incorrectDeltaType(hint: String)
                case cannotWriteDeltaForNonDeltaCRDT
                case inputAndStoredDataTypeMismatch(hint: String)
                case unsupportedCRDT
            }

            enum ReadResult: ActorMessage {
                case success(StateBasedCRDT)
                case failure(ReadError)
            }

            enum ReadError: Error, ActorMessage {
                case notFound
            }

            enum DeleteResult: ActorMessage {
                case success
            }
        }
    }
}

extension CRDT.Replicator.LocalCommand.RegisterError: Equatable {
    public static func == (lhs: CRDT.Replicator.LocalCommand.RegisterError, rhs: CRDT.Replicator.LocalCommand.RegisterError) -> Bool {
        switch (lhs, rhs) {
        case (.inputAndStoredDataTypeMismatch(let lError), .inputAndStoredDataTypeMismatch(let rError)):
            return lError == rError
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
        case (.inputAndStoredDataTypeMismatch(let lError), .inputAndStoredDataTypeMismatch(let rError)):
            return lError == rError
        case (.unsupportedCRDT, .unsupportedCRDT):
            return true
        case (.consistencyError(let lError), .consistencyError(let rError)):
            return lError == rError
        default:
            return false
        }
    }
}

extension CRDT.Replicator.LocalCommand.ReadError: Equatable {
    public static func == (lhs: CRDT.Replicator.LocalCommand.ReadError, rhs: CRDT.Replicator.LocalCommand.ReadError) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound):
            return true
        case (.consistencyError(let lError), .consistencyError(let rError)):
            return lError == rError
        default:
            return false
        }
    }
}

extension CRDT.Replicator.LocalCommand.DeleteError: Equatable {
    public static func == (lhs: CRDT.Replicator.LocalCommand.DeleteError, rhs: CRDT.Replicator.LocalCommand.DeleteError) -> Bool {
        switch (lhs, rhs) {
        case (.consistencyError(let lError), .consistencyError(let rError)):
            return lError == rError
        }
    }
}

extension CRDT.Replicator.RemoteCommand.WriteResult: Equatable {
    public static func == (lhs: CRDT.Replicator.RemoteCommand.WriteResult, rhs: CRDT.Replicator.RemoteCommand.WriteResult) -> Bool {
        switch (lhs, rhs) {
        case (.success, .success):
            return true
        case (.failure(let lError), .failure(let rError)):
            return lError == rError
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
        case (.incorrectDeltaType(let lHint), .incorrectDeltaType(let rHint)):
            return lHint == rHint
        case (.cannotWriteDeltaForNonDeltaCRDT, .cannotWriteDeltaForNonDeltaCRDT):
            return true
        case (.inputAndStoredDataTypeMismatch(let lHint), .inputAndStoredDataTypeMismatch(let rHint)):
            return lHint == rHint
        case (.unsupportedCRDT, .unsupportedCRDT):
            return true
        default:
            return false
        }
    }
}

extension CRDT.Replicator.Message {
    init(context: Serialization.Context, from buffer: inout ByteBuffer, using manifest: Serialization.Manifest) throws {
        self = .remoteCommand(try CRDT.Replicator.RemoteCommand(context: context, from: &buffer, using: manifest))
    }

    func serialize(context: Serialization.Context, to buffer: inout ByteBuffer) throws {
        switch self {
        case .localCommand:
            return fatalErrorBacktrace("Attempted to serialize message: \(Self.self)! This should never happen.")
        case .remoteCommand(let remoteCommand):
            try remoteCommand.serialize(context: context, to: &buffer)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Replicator settings

extension CRDT.Replicator {
    public struct Settings {
        public static var `default`: Settings {
            .init()
        }

        public var gossipInterval: TimeAmount = .seconds(2)

        /// When enabled traces _all_ replicator messages.
        /// All logs will be prefixed using `[tracelog:replicator]`, for easier grepping and inspecting only logs related to the replicator.
        // TODO: how to make this nicely dynamically changeable during runtime
        #if SACT_TRACE_REPLICATOR
        var traceLogLevel: Logger.Level? = .warning
        #else
        var traceLogLevel: Logger.Level?
        #endif
    }
}
