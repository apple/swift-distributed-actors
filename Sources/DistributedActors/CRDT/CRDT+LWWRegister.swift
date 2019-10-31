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
    public struct LWWRegister<Value>: CvRDT {
        public let replicaId: ReplicaId

        private(set) var value: Value?
        private(set) var timestamp: Date = Date.distantPast
        private(set) var updatedBy: ReplicaId?

        init(replicaId: ReplicaId) {
            self.replicaId = replicaId
        }

        mutating func assign(_ value: Value, timestamp: Date = Date()) {
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
// MARK: Aliases

// TODO: find better home for these type aliases

typealias LastWriterWinsRegister = CRDT.LWWRegister
