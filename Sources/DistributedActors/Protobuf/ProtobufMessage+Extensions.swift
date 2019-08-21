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
import NIO
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------

// MARK: Serialization with ByteBuf

extension SwiftProtobuf.Message {
    // FIXME: Avoid the copying, needs SwiftProtobuf changes
    /// Returns a `ByteBuffer` value containing the Protocol Buffer binary format serialization of the message.
    ///
    /// - Warning: Currently it is forced to perform an additional copy internally (so we double allocate the needed amount of space).
    ///
    /// - Parameters:
    ///   - partial: If `false` (the default), this method will check
    ///     `Message.isInitialized` before encoding to verify that all required
    ///     fields are present. If any are missing, this method throws
    ///     `BinaryEncodingError.missingRequiredFields`.
    /// - Returns: A `ByteBuffer` value containing the binary serialization of the message.
    /// - Throws: `BinaryEncodingError` if encoding fails.
    func serializedByteBuffer(allocator allocate: ByteBufferAllocator, partial: Bool = false) throws -> ByteBuffer {
        let data = try self.serializedData(partial: partial)
        // let data = try self.jsonString().data(using: .utf8)! // TODO allow a "debug mode with json payloads?"

        var buffer = allocate.buffer(capacity: data.count)
        buffer.writeBytes(data)

        return buffer
    }

    /// Initializes the message from a `ByteBuffer` while trying to avoid copying its contents
    init(bytes: inout ByteBuffer) throws {
        self.init()
        let bytesCount = bytes.readableBytes
        try bytes.withUnsafeMutableReadableBytes {
            // we are getting the pointer from a ByteBuffer, so it should be valid and force unwrap should be fine
            try self.merge(serializedData: Data(bytesNoCopy: $0.baseAddress!, count: bytesCount, deallocator: .none))
        }
    }
}
