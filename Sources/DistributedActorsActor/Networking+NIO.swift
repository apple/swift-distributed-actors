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
import SwiftProtobuf

private final class PrintHandler<Message>: ChannelInboundHandler {
    typealias InboundIn = Message

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let event = self.unwrapInboundIn(data)
        pprint("Received: \(event)")
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        fputs("Caught error: \(error)\n", stderr)
    }
}

private final class EnvelopeParser: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    public typealias InboundOut = Network.Envelope

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)

        do {
            let envelope = try readEnvelope(&bytes)
            _ = ctx.fireChannelRead(self.wrapInboundOut(envelope))
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

// MARK: Protobuf read... implementations 

extension EnvelopeParser {
    func readEnvelope(_ bytes: inout ByteBuffer) throws -> Network.Envelope {
        guard let data = bytes.readData(length: bytes.readableBytes) else { // foundation inter-op
            fatalError() // FIXME
        }

        var proto = ProtoEnvelope()
        try proto.merge(serializedData: data)
        
        // proto.recipient // TODO
        let recipientPath = (try ActorPath._rootPath / ActorPathSegment("system") / ActorPathSegment("deadLetters")).makeUnique(uid: .init(0))

        
        // since we don't want to leak the Protobuf types too much
        var envelope = Network.Envelope(
            recipient: recipientPath, 
            serializerId: Int(proto.serializerID), // TODO sanity check values
            payload: proto.payload.byt        // TODO: really really don't want Data in our core types like Envelope...!
        ) // TODO think more about envelope
    }
}


// MARK: "Server side" / accepting connections

extension NetworkKernel {

    // TODO: abstract into `Transport`

    func bootstrapServer(settings: NetworkSettings) -> EventLoopFuture<Channel> {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let bootstrap = ServerBootstrap(group: group)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.add(handler: BackPressureHandler()).then { _ in
                    channel.pipeline.add(handler: EnvelopeParser()).then { _ in
                        channel.pipeline.add(handler: PrintHandler())
                    }
                }
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let channel: EventLoopFuture<Channel> = bootstrap.bind(host: "localhost", port: 8080)
        return channel
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
    }
}
