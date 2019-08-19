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

import Foundation
@testable import DistributedActors

import DistributedActorsConcurrencyHelpers
import XCTest
import NIO
import NIOFoundationCompat

extension ByteBuffer {

    // For easier visual inspection of known utf8 data within a ByteBuffer, use with care (!)
    public func stringDebugDescription() -> String {
        return self.getString(at: 0, length: self.readableBytes)!
    }

}
