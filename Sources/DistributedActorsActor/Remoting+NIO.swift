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

typealias Framing = NIOExtras.LengthFieldBasedFrameDecoder

private final class EnvelopeParser: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    public typealias InboundOut = Wire.Envelope

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)

        do {
            let envelope = try self.readEnvelope(&bytes, allocator: ctx.channel.allocator)
            ctx.fireChannelRead(self.wrapInboundOut(envelope))
        } catch {
            // TODO notify the kernel?
            ctx.fireErrorCaught(error)
            ctx.close(promise: nil)
        }
    }

    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }

}

private final class HandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let kernel: RemotingKernel.Ref

    init(kernel: RemotingKernel.Ref) {
        self.kernel = kernel
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)
        pprint("[handshake] INCOMING: \(bytes.formatHexDump())")

        do {
            // TODO formalize wire format...
            let offer = try self.readHandshakeOffer(bytes: &bytes)
            self.kernel.tell(.handshakeOffer(offer))
            bytes.discardReadBytes()
        } catch {
            self.kernel.tell(.handshakeFailed(with: ctx.remoteAddress, error))
            ctx.fireErrorCaught(error)
        }
    }

    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }
}

private final class WriteHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
}

// MARK: Protobuf read... implementations

extension HandshakeHandler {

    func readAssertMagicHandshakeBytes(bytes: inout ByteBuffer) throws {
        guard let leadingBytes = bytes.readInteger(as: UInt16.self) else  {
            throw SwiftDistributedActorsProtocolError.notEnoughBytes(expectedAtLeastBytes: 16 / 8, hint: "handshake magic bytes")
        }

        if leadingBytes != HandshakeMagicBytes {
            throw Swift Distributed ActorsConnectionError.illegalHandshake(reason: HandshakeError.illegalHandshakeMagic(was: leadingBytes, expected: HandshakeMagicBytes))
        }
    }

    /// Read length prefixed data
    func readHandshakeOffer(bytes: inout ByteBuffer) throws -> Wire.HandshakeOffer {
        try self.readAssertMagicHandshakeBytes(bytes: &bytes)

        let bytesToReadAsData = bytes.readableBytes
        guard let data = bytes.readData(length: bytesToReadAsData) else {
            throw SwiftDistributedActorsProtocolError.notEnoughBytes(expectedAtLeastBytes: bytesToReadAsData, hint: "handshake offer")
        }
        
        var proto = try ProtoHandshakeOffer(serializedData: data)
        // TODO all those require calls where we insist on those fields being present :P
        
        return Wire.HandshakeOffer(
            version: Wire.Version(reserved: UInt8(proto.version.reserved), major: UInt8(proto.version.major), minor: UInt8(proto.version.minor), patch: UInt8(proto.version.patch)),
            from: Remote.UniqueAddress(proto.from),
            to: Remote.Address(proto.to)
        ) // TODO: version too, since we negotiate about it
    }
}

// TODO: Todo maybe "wire format error"
enum HandshakeError: Error {
    /// The first handshake bytes did not match the expected "magic bytes";
    /// It is very likely the other side attempting to connect to our port is NOT a Swift Distributed Actors system,
    /// thus we should reject it immediately. This can happen due to misconfiguration, e.g. mixing
    /// up ports and attempting to send HTTP or other data to a Swift Distributed Actors networking port.
    case illegalHandshakeMagic(was: UInt16, expected: UInt16) // TODO: Or [UInt8]...
    case missingField(String)
}
extension HandshakeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .illegalHandshakeMagic(let was, let expected):
            return ".illegalHandshakeMagic(was: \(was.hexString), expected: \(expected.hexString))"
        case .missingField(let field):
            return ".missingField(\(field))"
        }
    }
}

enum SwiftDistributedActorsProtocolError: Error {
    case notEnoughBytes(expectedAtLeastBytes: Int?, hint: String?)
}

enum DeserializationError: Error {
    case missingField(String)
}

extension EnvelopeParser {
    func readEnvelope(_ bytes: inout ByteBuffer, allocator: ByteBufferAllocator) throws -> Wire.Envelope {
        guard let data = bytes.readData(length: bytes.readableBytes) else { // foundation inter-op
            fatalError() // FIXME
        }

        let proto = try ProtoEnvelope(serializedData: data)
        let payloadBytes = proto.payload._copyToByteBuffer(allocator: allocator)
        
        // proto.recipient // TODO recipient from envelope
        let recipientPath = (try ActorPath._rootPath / ActorPathSegment("system") / ActorPathSegment("deadLetters")).makeUnique(uid: .init(0))

        // since we don't want to leak the Protobuf types too much
        let envelope = Wire.Envelope(
            version: Wire.Version(reserved: 0, major: 0, minor: 0, patch: 1),
            recipient: recipientPath, 
            serializerId: Int(proto.serializerID), // TODO sanity check values
            payload: payloadBytes
        ) // TODO think more about envelope

        return envelope
    }
}

private final class DumpRawBytesDebugHandler: ChannelInboundHandler {
    typealias InboundIn = Wire.Envelope

    var log: Logger

    init(log: Logger) {
        self.log = log
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        self.setLoggerMetadata(ctx)

        let event = self.unwrapInboundIn(data)
        log.info("Received: \(event)")
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

    func bootstrapServerSide(kernel: RemotingKernel.Ref, log: Logger, bindAddress: Remote.UniqueAddress, settings: RemotingSettings) -> EventLoopFuture<Channel> {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) // TODO share pool with others

        let bootstrap = ServerBootstrap(group: group)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.addHandlers([
                    // BackPressureHandler(),
                    HandshakeHandler(kernel: kernel),
                    Framing(lengthFieldLength: .four, lengthFieldEndianness: .big), // currently just a length encoded one, we alias to the one from NIOExtras
                    EnvelopeParser(),
                    DumpRawBytesDebugHandler(log: log) // FIXME only include for debug -DSACT_TRACE_NIO things?
                ], first: true)
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        return bootstrap.bind(host: bindAddress.address.host, port: Int(bindAddress.address.port)) // TODO separate setup from using it
    }

    func bootstrapClientSide(targetAddress: Remote.Address, settings: RemotingSettings) -> EventLoopFuture<Channel> {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) // TODO share pool with others

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
//                    HandshakeHandler(), // TODO mark it as client side, it should expect and Accept/Reject
//                    EnvelopeParser(),
//                    DumpRawBytesDebugHandler()
                    WriteHandler()
                ], first: true)
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
