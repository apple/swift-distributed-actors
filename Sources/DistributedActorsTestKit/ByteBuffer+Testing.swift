//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedCluster
import Foundation

import DistributedActorsConcurrencyHelpers
import NIO
import NIOFoundationCompat
import XCTest

// TODO: probably remove those?

extension Serialization.Buffer {
    // For easier visual inspection of known utf8 data within a Buffer, use with care (!)
    public func stringDebugDescription() -> String {
        switch self {
        case .data(let data):
            return data.stringDebugDescription()
        case .nioByteBuffer(let buffer):
            return buffer.stringDebugDescription()
        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            return "\(self)"
        }
    }
}

extension Data {
    // For easier visual inspection of known utf8 data within a Data, use with care (!)
    public func stringDebugDescription() -> String {
        if let string = String(data: self, encoding: .utf8) {
            return string
        } else {
            return "<<NOT UTF8 ENCODED: \(self)>>"
        }
    }
}

extension ByteBuffer {
    // For easier visual inspection of known utf8 data within a ByteBuffer, use with care (!)
    public func stringDebugDescription() -> String {
        self.getString(at: 0, length: self.readableBytes)!
    }
}
