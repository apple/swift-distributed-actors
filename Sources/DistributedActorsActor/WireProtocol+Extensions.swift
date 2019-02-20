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
import SwiftProtobuf
import NIO

// MARK: Serialization with ByteBuf // TODO is forced to allocate more than it would have to normally (due to hop through Data)
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

        var buffer = allocate.buffer(capacity: data.count)
        buffer.write(bytes: data)

        return buffer
    }
}


// MARK:
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

// MARK: Conversions
extension Network.UniqueAddress {
    init(_ proto: ProtoUniqueAddress) {
        let address = Network.Address(proto.address)
        let uid = Network.NodeUID(proto.uid)
        self.init(address: address, uid: uid)
    }
}
extension ProtoUniqueAddress {
    init(_ address: Network.UniqueAddress) {
        var proto = ProtoUniqueAddress()
        proto.address = ProtoAddress(address.address)
        self = proto
    }
}

extension Network.Address {
    init(_ proto: ProtoAddress) {
        self.systemName = proto.system
        self.host = proto.hostname
        self.port = UInt(proto.port) // FIXME
    }
}
extension ProtoAddress{
    init(_ address: Network.Address) {
        var proto = ProtoAddress()
        proto.system = address.systemName
        proto.hostname = address.host
        proto.port = UInt32(address.port) // FIXME
        self = proto
    }
}

extension ProtoHandshake {
    init(_ offer: Network.HandshakeOffer) {
        var proto = ProtoHandshake()
        proto.from = ProtoUniqueAddress(offer.from)
        proto.to = ProtoAddress(offer.to)
        // proto.version = ProtoVersion
        self = proto
    }
}
