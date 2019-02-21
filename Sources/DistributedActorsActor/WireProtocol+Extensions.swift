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

extension ProtoProtocolVersion {
    var reserved: UInt8 {
        return UInt8(self.value >> 24)
    }

    var major: UInt8 {
        return UInt8((self.value >> 16) & 0b11111111)
    }

    var minor: UInt8 {
        return UInt8((self.value >> 8) & 0b11111111)
    }

    var patch: UInt8 {
        return UInt8(self.value & 0b11111111)
    }

    static func make(reserved: UInt8, major: UInt8, minor: UInt8, patch: UInt8) -> ProtoProtocolVersion {
        var version = ProtoProtocolVersion()
        version.value =
            (UInt32(reserved) << 24)    |
            (UInt32(major) << 16)       |
            (UInt32(minor) << 8)        |
            UInt32(patch)
        return version
    }
}
