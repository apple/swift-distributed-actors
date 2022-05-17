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

@testable import DistributedActors
import Foundation

import DistributedActorsConcurrencyHelpers
import NIO
import NIOFoundationCompat
import XCTest

// TODO: probably remove those?

public extension Serialization.Buffer {
    // For easier visual inspection of known utf8 data within a Buffer, use with care (!)
    func stringDebugDescription() -> String {
        switch self {
        case .data(let data):
            return data.stringDebugDescription()
        case .nioByteBuffer(let buffer):
            return buffer.stringDebugDescription()
        }
    }
}

public extension Data {
    // For easier visual inspection of known utf8 data within a Data, use with care (!)
    func stringDebugDescription() -> String {
        if let string = String(data: self, encoding: .utf8) {
            return string
        } else {
            return "<<NOT UTF8 ENCODED: \(self)>>"
        }
    }
}

public extension ByteBuffer {
    // For easier visual inspection of known utf8 data within a ByteBuffer, use with care (!)
    func stringDebugDescription() -> String {
        self.getString(at: 0, length: self.readableBytes)!
    }
}
