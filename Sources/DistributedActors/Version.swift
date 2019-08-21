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

/// Version of wire protocol used by the given node.
///
// TODO: Exact semantics remain to be defined. Reserved likely to be used for flags "connection modes" etc "don't connect me, I just send 1 message" etc?
public struct Version: Equatable, CustomStringConvertible {
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
        return "Version(\(self.major).\(self.minor).\(self.patch), reserved:\(self.reserved))"
    }
}
