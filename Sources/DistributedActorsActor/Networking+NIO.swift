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
import struct Foundation.Data // would want to not have to use Data in our infra as it forces us to copy
import SwiftProtobuf

private final class PrintHandler: ChannelInboundHandler {
    typealias InboundIn = Network.Envelope
    
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

private final class EnvelopeParser: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    public typealias InboundOut = Network.Envelope

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)

        do {
            let envelope = try readEnvelope(&bytes, allocator: ctx.channel.allocator)
            ctx.fireChannelRead(self.wrapInboundOut(envelope))
        } catch {
            ctx.fireErrorCaught(error)
            ctx.close(promise: nil) // FIXME really?
        }
    }

    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }

}

private final class HandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)
        pprint("[handshake] INCOMING: \(bytes.formatHexDump())")

        do {
            try readAssertMagicHandshakeBytes(bytes: &bytes)
            let handshakeRequest = try readHandshakeRequest(bytes: &bytes)
        } catch {
            // TODO let network kernel know
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
        guard let leadingBytes = bytes.readInteger(as: UInt32.self) else  {
            fatalError("not enough bytes to see if magic bytes handshake prefix is present.")
        }

        if leadingBytes != NetworkHandshakeMagicBytes {
            throw Swift Distributed ActorsConnectionError.illegalHandshakeMagic(was: leadingBytes, expected: NetworkHandshakeMagicBytes)
        }
    }

    func readHandshakeRequest(bytes: inout ByteBuffer) throws -> Network.HandshakeOffer {
        guard let data = bytes.readData(length: bytes.readableBytes) else { // foundation inter-op
            fatalError() // FIXME
        }
        
        // TODO: Leading magic bytes
        
        var proto = ProtoHandshake()
        try proto.merge(serializedData: data)
        guard proto.hasFrom else { throw HandshakeError.missingField("from") }
        guard proto.hasTo else { throw HandshakeError.missingField("to") }
        guard proto.hasVersion else { throw HandshakeError.missingField("version") } // TODO put into extension on Proto and do validate()
        // TODO all those require calls where we insist on those fields being present :P
        
        return Network.HandshakeOffer(
            from: Network.UniqueAddress(proto.from),
            to: Network.Address(proto.to)
        ) // TODO: version too, since we negotiate about it
    }
}

// TODO: Todo maybe "wire format error"
enum HandshakeError: Error {
    case missingField(String)
}

extension EnvelopeParser {
    func readEnvelope(_ bytes: inout ByteBuffer, allocator: ByteBufferAllocator) throws -> Network.Envelope {
        guard let data = bytes.readData(length: bytes.readableBytes) else { // foundation inter-op
            fatalError() // FIXME
        }

        var proto = ProtoEnvelope()
        try proto.merge(serializedData: data)

        let payloadBytes = proto.payload._copyToByteBuffer(allocator: allocator)
        
        // proto.recipient // TODO
        let recipientPath = (try ActorPath._rootPath / ActorPathSegment("system") / ActorPathSegment("deadLetters")).makeUnique(uid: .init(0))

        // since we don't want to leak the Protobuf types too much
        let envelope = Network.Envelope(
            recipient: recipientPath, 
            serializerId: Int(proto.serializerID), // TODO sanity check values
            payload: payloadBytes
        ) // TODO think more about envelope

        return envelope
    }
}


// MARK: "Server side" / accepting connections

extension NetworkKernel {

    // TODO: abstract into `Transport`

    func bootstrapServerSide(log: Logger, bindAddress: Network.UniqueAddress, settings: NetworkSettings) -> EventLoopFuture<Channel> {
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
                    HandshakeHandler(),
                    EnvelopeParser(),
                    PrintHandler(log: log)
                ], first: true)
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        return bootstrap.bind(host: bindAddress.address.host, port: Int(bindAddress.address.port)) // TODO separate setup from using it
    }

    func bootstrapClientSide(targetAddress: Network.Address, settings: NetworkSettings) -> EventLoopFuture<Channel> {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) // TODO share pool with others

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
//                    HandshakeHandler(), // TODO mark it as client side, it should expect and Accept/Reject
//                    EnvelopeParser(),
//                    PrintHandler()
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
