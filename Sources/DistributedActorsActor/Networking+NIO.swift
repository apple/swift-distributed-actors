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

    var log = Logging.make("network") // TODO logger should be initially passed in

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if let remoteAddress = ctx.remoteAddress { log.metadata["remoteAddress"] = .string("\(remoteAddress)") }
        let event = self.unwrapInboundIn(data)
        log.info("Received: \(event)")
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        if let remoteAddress = ctx.remoteAddress { log.metadata["remoteAddress"] = .string("\(remoteAddress)") }
        log.error("Caught error: \(error)") 
        ctx.fireErrorCaught(error)
    }
}

//private final class PipeInboundToKernelHandler: ChannelInboundHandler {
//    typealias InboundIn = Network.Envelope
//
//    private let kernel: NetworkKernel.Ref
//    init(kernel: NetworkKernel.Ref) {
//        self.kernel = kernel
//    }
//
//    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
//        let event = self.unwrapInboundIn(data)
//        kernel.tell(.)
//    }
//
//    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
//        fputs("Caught error: \(error)\n", stderr)
//        // TODO: send to kernel
//    }
//}

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

    private func readVersion(_ buffer: inout ByteBuffer) throws -> Network.Version {
//        if buffer.readableBytes < 4 {
//            return false
//        }
        let versionBytes = buffer.readBytes(length: 4)!
        return Network.Version(
            reserved: versionBytes[0],
            major: versionBytes[1],
            minor: versionBytes[2],
            patch: versionBytes[3]
        )
    }

}

private final class HandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)
        pprint("[handshake] INCOMING: \(bytes)")

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
        guard proto.hasVersion else { throw HandshakeError.missingField("version") }
        // TODO all those require calls where we insist on those fields being present :P
        
        return Network.HandshakeOffer(
            from: Network.UniqueAddress(proto.from),
            to: Network.Address(proto.to)
        ) // TODO: version too, since we negotiate about it
    }
}
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

    func bootstrapServer(bindAddress: Network.Address, settings: NetworkSettings) -> EventLoopFuture<Channel> {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
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
                    PrintHandler()
                ], first: true)
                
                // channel.pipeline.add(handler: BackPressureHandler()).then { _ in
                //     channel.pipeline.add(handler: HandshakeHandler()).then { _ in
                //         channel.pipeline.add(handler: EnvelopeParser()).then { _ in
                //             channel.pipeline.add(handler: PrintHandler())
                //         }
                //     }
                // }
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        return bootstrap.bind(host: bindAddress.host, port: Int(bindAddress.port))
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
