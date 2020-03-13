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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Specialized ActorMessage: Protocol Buffers

// TODO: Is this doable?
//extension SwiftProtobuf.Message where Self: ActorMessage {
//}

extension InternalProtobufRepresentable where Self: ActorMessage {
    init(context: Serialization.Context, from buffer: inout NIO.ByteBuffer, using manifest: Serialization.Manifest) throws {
        let proto = try ProtobufRepresentation(buffer: &buffer)
        try self.init(fromProto: proto, context: context)
    }

    func serialize(context: Serialization.Context, to buffer: inout NIO.ByteBuffer) throws {
        try self.toProto(context: context).writeSerializedBytes(to: &buffer)
    }
}

extension ProtobufRepresentable where Self: ActorMessage {
    public init(context: Serialization.Context, from buffer: inout NIO.ByteBuffer, using manifest: Serialization.Manifest) throws {
        let proto = try ProtobufRepresentation(buffer: &buffer)
        try self.init(fromProto: proto, context: context)
    }

    public func serialize(context: Serialization.Context, to buffer: inout NIO.ByteBuffer) throws {
        try self.toProto(context: context).writeSerializedBytes(to: &buffer)
    }
}
