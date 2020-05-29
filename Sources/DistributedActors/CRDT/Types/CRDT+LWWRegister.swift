//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
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
    public struct LWWRegister<Value: Codable & Equatable>: CvRDT, LWWRegisterOperations {
        public let replicaID: ReplicaID

        public let initialValue: Value

        public internal(set) var value: Value
        var clock: WallTimeClock
        var updatedBy: ReplicaID

        /// Creates a pure datatype that can be manually managed (passed around, merged, serialized), without involvement of the actor runtime.
        public init(replicaID: ReplicaID, initialValue: Value, clock: WallTimeClock = WallTimeClock()) {
            self.replicaID = replicaID
            self.initialValue = initialValue
            self.value = initialValue
            self.clock = clock
            self.updatedBy = self.replicaID
        }

        /// Assigns `value` to the register.
        public mutating func assign(_ value: Value) {
            self.value = value
            self.clock = WallTimeClock()
            self.updatedBy = self.replicaID
        }

        public mutating func _tryMerge(other: StateBasedCRDT) -> CRDT.MergeError? {
            let OtherType = type(of: other as Any)
            if let wellTypedOther = other as? Self {
                self.merge(other: wellTypedOther)
                return nil
            } else {
                return CRDT.MergeError(storedType: Self.self, incomingType: OtherType)
            }
        }

        public mutating func merge(other: LWWRegister<Value>) {
            // The greater timestamp wins
            if self.clock < other.clock {
                self.value = other.value
                self.clock = other.clock
                self.updatedBy = other.updatedBy
            }
        }

        public func equalState(to other: StateBasedCRDT) -> Bool {
            guard let other = other as? Self else {
                return false
            }

            return self.initialValue == other.initialValue &&
                self.value == other.value &&
                self.clock == self.clock &&
                self.updatedBy == self.updatedBy // TODO: is this correct?
        }
    }
}

extension CRDT.LWWRegister where Value: ExpressibleByNilLiteral {
    /// Creates a pure datatype that can be manually managed (passed around, merged, serialized), without involvement of the actor runtime.
    public init(replicaID: ReplicaID) {
        self.init(replicaID: replicaID, initialValue: nil)
    }
}

extension CRDT.LWWRegister: ResettableCRDT {
    public mutating func reset() {
        self = .init(replicaID: self.replicaID, initialValue: self.initialValue)
    }
}

public protocol LWWRegisterOperations {
    associatedtype Value

    var value: Value { get }

    mutating func assign(_ value: Value)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT String Descriptions

extension CRDT.LWWRegister: CustomStringConvertible, CustomPrettyStringConvertible {
    public var description: String {
        "\(Self.self)(\(self.value))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias LastWriterWinsRegister = CRDT.LWWRegister
