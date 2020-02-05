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
    /// A new timestamp is generated for each `value` update, which is used in `merge` to determine total ordering
    /// of the assignments. The greater timestamp "wins", hence the name last-writer-wins register.
    ///
    /// `WallTimeClock` is the default type for timestamps.
    ///
    /// - SeeAlso: [A comprehensive study of CRDTs](https://hal.inria.fr/file/index/docid/555588/filename/techreport.pdf)
    public struct LWWRegister<Value>: CvRDT, LWWRegisterOperations {
        public let replicaId: ReplicaId

        let defaultClock: () -> Clock
        let initialValue: Value

        public private(set) var value: Value
        private(set) var clock: Clock
        private(set) var updatedBy: ReplicaId

        init(replicaId: ReplicaId, initialValue: Value, defaultClock: @escaping () -> Clock = Clock.wallTimeNow) {
            self.init(replicaId: replicaId, initialValue: initialValue, clock: defaultClock(), defaultClock: defaultClock)
        }

        init(replicaId: ReplicaId, initialValue: Value, clock: Clock, defaultClock: @escaping () -> Clock = Clock.wallTimeNow) {
            self.replicaId = replicaId
            self.defaultClock = defaultClock
            self.initialValue = initialValue
            self.value = initialValue
            self.clock = clock
            self.updatedBy = self.replicaId
        }

        /// Assigns `value` to the register.
        public mutating func assign(_ value: Value) {
            self.value = value
            self.clock = self.defaultClock()
            self.updatedBy = self.replicaId
        }

        public mutating func merge(other: LWWRegister<Value>) {
            // The greater timestamp wins
            if self.clock < other.clock {
                self.value = other.value
                self.clock = other.clock
                self.updatedBy = other.updatedBy
            }
        }
    }
}

extension CRDT.LWWRegister where Value: ExpressibleByNilLiteral {
    init(replicaId: ReplicaId) {
        self.init(replicaId: replicaId, initialValue: nil)
    }
}

extension CRDT.LWWRegister: ResettableCRDT {
    public mutating func reset() {
        self = .init(replicaId: self.replicaId, initialValue: self.initialValue)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned LWWRegister

public protocol LWWRegisterOperations {
    associatedtype Value

    var value: Value { get }

    mutating func assign(_ value: Value)
}

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: LWWRegisterOperations {
    public var lastObservedValue: DataType.Value {
        self.data.value
    }

    public func assign(_ value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Assign value locally then propagate
        self.data.assign(value)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.LWWRegister {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String, initialValue: Value) -> CRDT.ActorOwned<CRDT.LWWRegister<Value>> {
        CRDT.ActorOwned<CRDT.LWWRegister>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.LWWRegister<Value>(replicaId: .actorAddress(owner.address), initialValue: initialValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias LastWriterWinsRegister = CRDT.LWWRegister
