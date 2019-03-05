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

import NIO
import NIOFoundationCompat
import class NIOExtras.LengthFieldBasedFrameDecoder

import struct Foundation.Data // FIXME: would want to not have to use Data in our infra as it forces us to copy
import SwiftProtobuf

// TODO: Implement our own EnvelopeParser, basically similar to the NIOExtras.LengthFieldBasedFrameDecoder
typealias Framing = LengthFieldBasedFrameDecoder

/// Error indicating that after an operation some unused bytes are left.
public struct LeftOverBytesError: Error {
    public let leftOverBytes: ByteBuffer
}

// TODO: actually make use of this
//private final class EnvelopeParser: ByteToMessageDecoder, ChannelInboundHandler {
//    typealias InboundIn = ByteBuffer
//    public typealias InboundOut = Wire.Envelope
//
////    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
////        var bytes = self.unwrapInboundIn(data)
////
////        do {
////            let envelope = try self.readEnvelope(&bytes, allocator: ctx.channel.allocator)
////            ctx.fireChannelRead(self.wrapInboundOut(envelope))
////        } catch {
////            // TODO notify the kernel?
////            ctx.fireErrorCaught(error)
////            ctx.close(promise: nil)
////        }
////    }
//
////    func channelReadComplete(ctx: ChannelHandlerContext) {
////        ctx.flush()
////    }
//
//    public var cumulationBuffer: ByteBuffer?
//
//    func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
//        fatalError("BOOOOOOM 1")
//        let readBytes: Int? = buffer.withUnsafeReadableBytes { bytes in
//            fatalError("BOOOOOOM 2")
//        }
//
//        guard let _ = readBytes else {
//            return .needMoreData
//        }
//
//        fatalError("BOOOOOOM 3")
//
//    }
//}

private final class HandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let kernel: RemotingKernel.Ref
    private let role: HandlerRole
    
    private var magicSeen = false

    init(kernel: RemotingKernel.Ref, role: HandlerRole) {
        self.kernel = kernel
        self.role = role
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)
        traceLog_Remote("[handshake-\(self.role)] INCOMING: \(bytes.formatHexDump())")

        do {
            switch self.role {
            case .server:

                if !self.magicSeen {
                    try self.readAssertMagicHandshakeBytes(bytes: &bytes)
                    self.magicSeen = true // TODO we dont want this flag
                }
                // TODO formalize wire format...
                let offer = try self.readHandshakeOffer(bytes: &bytes)

                let promise = ctx.eventLoop.newPromise(of: ByteBuffer.self) // TODO trying to figure out nicest way...
                self.kernel.tell(.inbound(.handshakeOffer(offer, replyTo: promise)))

                // TODO once we write the response here, we can remove the handshake handler from the pipeline

                promise.futureResult.onComplete { res in
                    switch res {
                    case .failure(let err):
                        ctx.fireErrorCaught(err)
                    case .success(let bytes): // TODO this will be a domain object, since we'll serialize in the next handler
                        ctx.writeAndFlush(NIOAny(bytes), promise: nil)
                    }
                }

            case .client:
                let accept = try self.readHandshakeAccept(bytes: &bytes) // TODO must check reply types

                let promise = ctx.eventLoop.newPromise(of: ByteBuffer.self) // TODO trying to figure out nicest way...
                self.kernel.tell(.inbound(.handshakeAccepted(accept, replyTo: promise)))

                // TODO once we write the response here, we can remove the handshake handler from the pipeline
                
                promise.futureResult.onComplete { res in
                    switch res {
                    case .failure(let err):
                        ctx.fireErrorCaught(err)
                    case .success(let bytes): // TODO this will be a domain object, since we'll serialize in the next handler
                        ctx.writeAndFlush(NIOAny(bytes), promise: nil)
                    }
                }
            }


        } catch {
            self.kernel.tell(.inbound(.handshakeFailed(nil, error))) // FIXME this is to let the state machine know it should clear this handshake
            ctx.fireErrorCaught(error)
        }
    }
}

enum HandlerRole {
    case client
    case server
} 

// TODO: This should receive Wire.Envelope and write it.
private final class WriteHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    let role: HandlerRole
    private var magicSent = false
    
    init(role: HandlerRole) {
        self.role = role
    }

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = self.unwrapOutboundIn(data)

        if self.role == .client && !self.magicSent { // FIXME LAZY HACK
            var b = ctx.channel.allocator.buffer(capacity: 4)
            b.write(integer: HandshakeMagicBytes, endianness: .big) // first bytes MUST be magic when initiating connection
            _ = ctx.write(NIOAny(b))
            traceLog_Remote("[WRITE-\(self.role)] WRITE MAGIC")
            self.magicSent = true
        }

        // TODO this is the simple prefix length for which we have Framing on the other end; we'll want this to be envelope
        var lenBuf = ctx.channel.allocator.buffer(capacity: 4)
        traceLog_Remote("[WRITE-\(self.role)] WRITE LENGTH: \(bytes.readableBytes)")
        lenBuf.write(integer: UInt32(bytes.readableBytes), endianness: .big)
        _ = ctx.write(NIOAny(lenBuf))

        traceLog_Remote("[WRITE-\(self.role)] WRITE BYTES: \(bytes.formatHexDump())")
        ctx.writeAndFlush(data, promise: promise)
    }

}

// MARK: Protobuf read... implementations

extension HandshakeHandler {

    func readAssertMagicHandshakeBytes(bytes: inout ByteBuffer) throws {
        guard let leadingBytes = bytes.readInteger(as: UInt16.self) else  {
            throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: 16 / 8, hint: "handshake magic bytes")
        }

        if leadingBytes != HandshakeMagicBytes {
            throw SwiftDistributedActorsProtocolError.illegalHandshake(reason: HandshakeError.illegalHandshakeMagic(was: leadingBytes, expected: HandshakeMagicBytes))
        }
    }

    /// Read length prefixed data
    func readHandshakeOffer(bytes: inout ByteBuffer) throws -> Wire.HandshakeOffer {
        let data = try readLengthPrefixedData(bytes: &bytes)

        let proto = try ProtoHandshakeOffer(serializedData: data)
        return try Wire.HandshakeOffer(proto) // TODO: version too, since we negotiate about it
    }

    // length prefixed
    func readHandshakeAccept(bytes: inout ByteBuffer) throws -> Wire.HandshakeAccept {
        let data = try readLengthPrefixedData(bytes: &bytes)

        let proto = try ProtoHandshakeAccept(serializedData: data)
        return try Wire.HandshakeAccept(proto)
    }

    private func readLengthPrefixedData(bytes: inout ByteBuffer) throws -> Data {
        guard let bytesToReadAsData = (bytes.readInteger(endianness: .big, as: UInt32.self).map { Int($0) }) else {
            throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: 32 / 8, hint: "length prefix")
        }
        guard let data = bytes.readData(length: bytesToReadAsData) else {
            throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: bytesToReadAsData, hint: "handshake offer")
        }
        bytes.discardReadBytes()
        return data
    }
}

enum WireFormatError: Error {
    case missingField(String)
    case notEnoughBytes(expectedAtLeastBytes: Int, hint: String?)
}

//extension EnvelopeParser {
//    func readEnvelope(_ bytes: inout ByteBuffer, allocator: ByteBufferAllocator) throws -> Wire.Envelope {
//        guard let data = bytes.readData(length: bytes.readableBytes) else { // foundation inter-op
//            fatalError() // FIXME
//        }
//
//        let proto = try ProtoEnvelope(serializedData: data)
//        let payloadBytes = proto.payload._copyToByteBuffer(allocator: allocator)
//
//        // proto.recipient // TODO recipient from envelope
//        let recipientPath = (try ActorPath._rootPath / ActorPathSegment("system") / ActorPathSegment("deadLetters")).makeUnique(uid: .init(0))
//
//        // since we don't want to leak the Protobuf types too much
//        let envelope = Wire.Envelope(
//            version: DistributedActorsProtocolVersion,
//            recipient: recipientPath,
//            serializerId: Int(proto.serializerID), // TODO sanity check values
//            payload: payloadBytes
//        ) // TODO think more about envelope
//
//        return envelope
//    }
//}

private final class DumpRawBytesDebugHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let role: HandlerRole
    var log: Logger

    init(role: HandlerRole, log: Logger) {
        self.role = role
        self.log = log
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        self.setLoggerMetadata(ctx)

        let event = self.unwrapInboundIn(data)
        log.info("[dump-\(self.role)] Received: \(event.formatHexDump)")
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        self.setLoggerMetadata(ctx)

        log.error("Caught error: [\(error)]:\(type(of: error))")
        ctx.fireErrorCaught(error)
    }

    private func setLoggerMetadata(_ ctx: ChannelHandlerContext) {
        if let remoteAddress = ctx.remoteAddress { log.metadata["remoteAddress"] = .string("\(remoteAddress)") }
        if let localAddress = ctx.localAddress { log.metadata["localAddress"] = .string("\(localAddress)") }
    }
}

// MARK: "Server side" / accepting connections

extension RemotingKernel {

    // TODO: abstract into `Transport`

    func bootstrapServerSide(kernel: RemotingKernel.Ref, log: Logger, bindAddress: UniqueNodeAddress, settings: RemotingSettings) -> EventLoopFuture<Channel> {
        let group: EventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup() // TODO share the loop with client side?

        // TODO: Implement "setup" inside settings, so that parts of bootstrap can be done there, e.g. by end users without digging into remoting internals

        let bootstrap = ServerBootstrap(group: group)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline
                        .add(name: "server-write", handler: WriteHandler(role: .server))
                    // Handshake MUST be the first thing in the pipeline
                    .then { _ in  channel.pipeline
                        .add(name: "handshake", handler: HandshakeHandler(kernel: kernel, role: .server)) 
                    }
                    // .then { channel.pipeline.add(BackPressureHandler()) }
//                    .then { _ in
//                        // currently just a length encoded one, we alias to the one from NIOExtras
//                        channel.pipeline.add(name: "framing", handler: Framing(lengthFieldLength: .four, lengthFieldEndianness: .big))
//                    }
//                    .then { _ in // TODO Do the envelope parser instead of the simple framing
//                        channel.pipeline.add(name: "envelope-parser", handler: EnvelopeParser())
//                    }
                    .then { _ in
                        // FIXME only include for debug -DSACT_TRACE_NIO things?
                        channel.pipeline.add(name: "dump-raw-bytes-debug", handler: DumpRawBytesDebugHandler(role: .server, log: log))
                    }
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        return bootstrap.bind(host: bindAddress.address.host, port: Int(bindAddress.address.port)) // TODO separate setup from using it
    }

    func bootstrapClientSide(kernel: RemotingKernel.Ref, log: Logger, targetAddress: NodeAddress, settings: RemotingSettings) -> EventLoopFuture<Channel> {
        let group: EventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()

        // TODO: Implement "setup" inside settings, so that parts of bootstrap can be done there, e.g. by end users without digging into remoting internals

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline
                    .add(name: "client-write", handler: WriteHandler(role: .client))
                    .then { _ in channel.pipeline
                        .add(name: "handshake", handler: HandshakeHandler(kernel: kernel, role: .client))
                    }
//                    .then { _ in
//                        // currently just a length encoded one, we alias to the one from NIOExtras
//                        channel.pipeline.add(name: "framing", handler: Framing(lengthFieldLength: .four, lengthFieldEndianness: .big))
//                    }
                    .then { _ in
                        // FIXME only include for debug -DSACT_TRACE_NIO things?
                        channel.pipeline.add(name: "dump-raw-bytes-debug", handler: DumpRawBytesDebugHandler(role: .client, log: log))
                    }
            }


        return bootstrap.connect(host: targetAddress.host, port: Int(targetAddress.port)) // TODO separate setup from using it
    }
}

// MARK: Parsing utilities

// Note: Since we don't want to necessarily bind everything into protobuf just yet
extension UniqueActorPath {
    // TODO optimize or replace with other mechanism
    func _parse(_ buf: inout ByteBuffer) throws -> UniqueActorPath? {
        guard let string = buf.readString(length: buf.readableBytes) else { // TODO meh
            return nil
        }

        var path = ActorPath._rootPath
        for part in string.split(separator: "/") {
            path = try path / ActorPathSegment(part)
        }

        // TODO take the UID as well

        return path.makeUnique(uid: .random()) // FIXME
    }
}
