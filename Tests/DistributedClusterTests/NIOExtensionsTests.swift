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

@testable import DistributedCluster
@testable import DistributedActorsTestKit
import NIO
import XCTest

class NIOExtensionTests: XCTestCase {
    func test_ByteBuf_formatHexDump_shouldPrettyPrintAsExpected() {
        let allocator = ByteBufferAllocator()
        var b = allocator.buffer(capacity: 512)
        b.writeString("Lorem Ipsum is simply dummy text of the printing and typesetting industry.")

        let expected = """
        ByteBuffer(readableBytes: 74), formatHexDump:
            4C 6F 72 65 6D 20 49 70  73 75 6D 20 69 73 20 73  | Lorem Ipsum is s
            69 6D 70 6C 79 20 64 75  6D 6D 79 20 74 65 78 74  | imply dummy text
            20 6F 66 20 74 68 65 20  70 72 69 6E 74 69 6E 67  |  of the printing
            20 61 6E 64 20 74 79 70  65 73 65 74 74 69 6E 67  |  and typesetting
            20 69 6E 64 75 73 74 72  79 2E                    |  industry.
        """
        b.formatHexDump().shouldEqual(expected)
    }

    func test_ByteBuf_formatHexDump_truncating_shouldPrettyPrintAsExpected() {
        let allocator = ByteBufferAllocator()
        var b = allocator.buffer(capacity: 512)
        b.writeString("Lorem Ipsum is simply dummy text of the printing and typesetting industry.")

        let expected = """
        ByteBuffer(readableBytes: 74, shown: 20), formatHexDump:
            4C 6F 72 65 6D 20 49 70  73 75 6D 20 69 73 20 73  | Lorem Ipsum is s
            69 6D 70 6C                                       | impl
            [ 54 bytes truncated ... ]
        """
        b.formatHexDump(maxBytes: 20).shouldEqual(expected)
    }
}
