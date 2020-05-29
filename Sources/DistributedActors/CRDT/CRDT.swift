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

import Logging
import NIO

/// Namespace for CRDT types.
public enum CRDT {
    public enum Status: String, ActorMessage {
        case active
        case deleted
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Identity

extension CRDT {
    public struct Identity: Hashable, Codable {
        public let id: String

        public init(_ id: String) {
            self.id = id
        }
    }
}

extension CRDT.Identity: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

extension CRDT.Identity: CustomStringConvertible {
    public var description: String {
        "CRDT.Identity(\(id))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: OperationConsistency

extension CRDT {
    public enum OperationConsistency: Codable {
        /// Perform operation in the local replica only.
        case local
        /// Perform operation in `.atLeast` replicas, including the local replica.
        case atLeast(Int)
        /// Perform operation in at least `n/2 + 1` replicas, where `n` is the total number of replicas in the
        /// cluster (at the moment the operation is issued), including the local replica.
        /// For example, when `n` is `4`, quorum would be `4/2 + 1 = 3`; when `n` is `5`, quorum would be `5/2 + 1 = 3`.
        case quorum
        /// Perform operation in all replicas.
        case all
    }
}

extension CRDT.OperationConsistency {
    enum DiscriminatorKeys: Int, Codable {
        case local
        case atLeast
        case quorum
        case all
    }

    enum CodingKeys: String, CodingKey {
        case _case
        case atLeast_value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .local:
            self = .local
        case .atLeast:
            let value = try container.decode(Int.self, forKey: .atLeast_value)
            self = .atLeast(value)
        case .quorum:
            self = .quorum
        case .all:
            self = .all
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(DiscriminatorKeys.local.rawValue, forKey: ._case)
        case .atLeast(let n):
            try container.encode(DiscriminatorKeys.atLeast, forKey: ._case)
            try container.encode(n, forKey: .atLeast_value)
        case .quorum:
            try container.encode(DiscriminatorKeys.quorum, forKey: ._case)
        case .all:
            try container.encode(DiscriminatorKeys.all, forKey: ._case)
        }
    }
}

extension CRDT.OperationConsistency: Equatable {
    public static func == (lhs: CRDT.OperationConsistency, rhs: CRDT.OperationConsistency) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local):
            return true
        case (.atLeast(let ln), .atLeast(let rn)):
            return ln == rn
        case (.quorum, .quorum):
            return true
        case (.all, .all):
            return true
        default:
            return false
        }
    }
}

extension CRDT.OperationConsistency {
    public enum Error: Swift.Error {
        case invalidNumberOfReplicasRequested(Int)
        case unableToFulfill(consistency: CRDT.OperationConsistency, localConfirmed: Bool, required: Int, remaining: Int, obtainable: Int)
        case tooManyFailures(allowed: Int, actual: Int)
        case remoteReplicasRequired
        indirect case unexpectedError(Swift.Error)

        public static func wrap(_ error: Swift.Error) -> Error {
            if let consistencyError = error as? CRDT.OperationConsistency.Error {
                return consistencyError
            } else {
                return .unexpectedError(error)
            }
        }
    }
}

extension CRDT.OperationConsistency.Error: Equatable {
    public static func == (lhs: CRDT.OperationConsistency.Error, rhs: CRDT.OperationConsistency.Error) -> Bool {
        switch (lhs, rhs) {
        case (.invalidNumberOfReplicasRequested(let lNum), .invalidNumberOfReplicasRequested(let rNum)):
            return lNum == rNum
        case (.unableToFulfill(let lConsistency, let lLocal, let lRequired, let lRemaining, let lObtainable), .unableToFulfill(let rConsistency, let rLocal, let rRequired, let rRemaining, let rObtainable)):
            return lConsistency == rConsistency && lLocal == rLocal && lRequired == rRequired && lRemaining == rRemaining && lObtainable == rObtainable
        case (.tooManyFailures(let lAllowed, let lActual), .tooManyFailures(let rAllowed, let rActual)):
            return lAllowed == rAllowed && lActual == rActual
        case (.remoteReplicasRequired, .remoteReplicasRequired):
            return true
        default:
            return false
        }
    }
}

extension CRDT {
    public struct MergeError: Error, CustomStringConvertible, Equatable {
        let storedType: Any.Type
        let incomingType: Any.Type

        public var description: String {
            "MergeError(Unable to merge \(reflecting: self.storedType) with incoming \(reflecting: self.incomingType)"
        }

        public static func == (lhs: MergeError, rhs: MergeError) -> Bool {
            ObjectIdentifier(lhs.storedType) == ObjectIdentifier(rhs.storedType) &&
                ObjectIdentifier(lhs.incomingType) == ObjectIdentifier(rhs.incomingType)
        }
    }
}
