//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
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
import NIO
import NIOFoundationCompat

// FIXME: this is obviously not a good idea
private let testOnlyAllocator = ByteBufferAllocator()

extension Data {
    /// For easier testing, as we want all our assertions etc on ByteBuffers
    public func copyToNewByteBuffer() -> ByteBuffer {
        self._copyToByteBuffer(allocator: testOnlyAllocator)
    }
}
