//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension ClusterSystem {

    /// Version of the cluster system, as advertised to other nodes while joining the cluster.
    /// Can be used to determine wire of feature compatibility of nodes joining a cluster.
    public struct Version: Equatable, CustomStringConvertible {
        /// Exact semantics of the reserved field remain to be defined.
        public var reserved: UInt8
        public var major: UInt8
        public var minor: UInt8
        public var patch: UInt8

        init(reserved: UInt8, major: UInt8, minor: UInt8, patch: UInt8) {
            self.reserved = reserved
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public var description: String {
            "Version(\(self.major).\(self.minor).\(self.patch), reserved:\(self.reserved))"
        }

        public var versionString: String {
            "\(self.major).\(self.minor).\(self.patch)"
        }
    }
}
