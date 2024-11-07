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
import Foundation
import NIO
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization with ByteBuf
extension SwiftProtobuf.Message {
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
    // FIXME: Avoid the copying, needs SwiftProtobuf changes
    func serializedByteBuffer(allocator allocate: ByteBufferAllocator, partial: Bool = false) throws -> ByteBuffer {
        // let data = try self.jsonString().data(using: .utf8)! // TODO allow a "debug mode with json payloads?"
        let data = try self.serializedData(partial: partial)
        var buffer = allocate.buffer(capacity: data.count)
        buffer.writeBytes(data)

        return buffer
    }
}
