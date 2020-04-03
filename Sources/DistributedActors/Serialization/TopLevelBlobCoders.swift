//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Foundation.Data
import struct NIO.ByteBuffer
import struct NIO.ByteBufferAllocator

internal protocol _TopLevelBlobEncoder: Encoder {
    func encode<T>(_ value: T) throws -> ByteBuffer where T: Encodable
}

internal protocol _TopLevelBlobDecoder: Decoder {
    func decode<T>(_ type: T.Type, from: ByteBuffer) throws -> T where T: Decodable
}
