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

import Foundation // for Date

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LWWRegister as pure CRDT

extension CRDT {
    /// Last-Writer-Wins Register described in [A comprehensive study of CRDTs](https://hal.inria.fr/file/index/docid/555588/filename/techreport.pdf).
    ///
    /// By default LWWRegister does not have a `value` until `assign` is called. A new `timestamp` is generated each
    /// `value` update, which is used in `merge` to determine total ordering of the assignments. The maximum timestamp
    /// "wins", hence the name last-writer-wins register.
    ///
    /// In this implementation `timestamp`'s type is `Date`, but that can be enhanced to support custom clock instead,
    /// as some of the other implementations have done.
    ///
    /// - SeeAlso: [A comprehensive study of CRDTs](https://hal.inria.fr/file/index/docid/555588/filename/techreport.pdf)
    public struct LWWRegister<Value>: CvRDT, LWWRegisterOperations {
        public let replicaId: ReplicaId

        public private(set) var value: Value?
        private(set) var timestamp: Date = Date.distantPast
        private(set) var updatedBy: ReplicaId?

        init(replicaId: ReplicaId) {
            self.replicaId = replicaId
        }

        public mutating func assign(_ value: Value, timestamp: Date = Date()) {
            if self.timestamp < timestamp {
                self.value = value
                self.timestamp = timestamp
                self.updatedBy = self.replicaId
            }
        }

        public mutating func merge(other: LWWRegister<Value>) {
            if self.timestamp < other.timestamp {
                self.value = other.value
                self.timestamp = other.timestamp
                self.updatedBy = other.updatedBy
            }
        }
    }
}

extension CRDT.LWWRegister: ResettableCRDT {
    public mutating func reset() {
        self = .init(replicaId: self.replicaId)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned LWWRegister

public protocol LWWRegisterOperations {
    associatedtype Value

    var value: Value? { get }

    mutating func assign(_ value: Value, timestamp: Date)
}

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: LWWRegisterOperations {
    public var lastObservedValue: DataType.Value? {
        return self.data.value
    }

    public func assign(_ value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Assign value locally then propagate
        self.data.assign(value, timestamp: Date())
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.LWWRegister {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String) -> CRDT.ActorOwned<CRDT.LWWRegister<Value>> {
        return CRDT.ActorOwned<CRDT.LWWRegister>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.LWWRegister<Value>(replicaId: .actorAddress(owner.address)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias LastWriterWinsRegister = CRDT.LWWRegister
