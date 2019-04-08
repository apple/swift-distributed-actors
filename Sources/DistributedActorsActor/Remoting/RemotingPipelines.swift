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
import NIOSSL
import NIOFoundationCompat
import class NIOExtras.LengthFieldBasedFrameDecoder
import class NIOExtras.LengthFieldPrepender

import struct Foundation.Data // FIXME: would want to not have to use Data in our infra as it forces us to copy
import SwiftProtobuf
import Logging

typealias Framing = LengthFieldBasedFrameDecoder

/// Error indicating that after an operation some unused bytes are left.
public struct LeftOverBytesError: Error {
    public let leftOverBytes: ByteBuffer
}

private final class HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let kernel: RemotingKernel.Ref
    private let role: HandlerRole
    private let serializationPool: SerializationPool
    private let system: ActorSystem

    init(system: ActorSystem, kernel: RemotingKernel.Ref, role: HandlerRole, serializationPool: SerializationPool) {
        self.kernel = kernel
        self.role = role
        self.serializationPool = serializationPool
        self.system = system
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)
        traceLog_Remote("[handshake-\(self.role)] INCOMING: \(bytes.formatHexDump())")

        do {
            switch self.role {
            case .server:
                // TODO formalize wire format...
                let offer = try self.readHandshakeOffer(bytes: &bytes)

                let promise = context.eventLoop.makePromise(of: ByteBuffer.self) // TODO trying to figure out nicest way...
                self.kernel.tell(.inbound(.handshakeOffer(offer, channel: context.channel, replyTo: promise)))

                promise.futureResult.onComplete { res in
                    switch res {
                    case .failure(let err):
                        context.fireErrorCaught(err)
                    case .success(let bytes):
                        context.writeAndFlush(NIOAny(bytes), promise: nil)
                        // we are done with the handshake, so we can remove it and add envelope and serialization handler to process actual messages
                        self.upgradePipeline(context: context)
                    }
                }

            case .client:
                let accept = try self.readHandshakeAccept(bytes: &bytes) // TODO must check reply types

                let promise = context.eventLoop.makePromise(of: Void.self) // TODO trying to figure out nicest way...
                self.kernel.tell(.inbound(.handshakeAccepted(accept, channel: context.channel, replyTo: promise)))

                // TODO once we write the response here, we can remove the handshake handler from the pipeline
                
                promise.futureResult.onComplete { res in
                    switch res {
                    case .failure(let err):
                        context.fireErrorCaught(err)
                    case .success:
                        self.upgradePipeline(context: context)
                    }
                }
            }


        } catch {
            self.kernel.tell(.inbound(.handshakeFailed(nil, error))) // FIXME this is to let the state machine know it should clear this handshake
            context.fireErrorCaught(error)
        }
    }

    // called after handshake is successfully completed to remove the handshake handler
    // and add the serialization related handlers
    private func upgradePipeline(context: ChannelHandlerContext) {
        context.pipeline.removeHandler(self, promise: nil)
        var envelopeHandlerLog = Logger(label: "envelopeHandler", factory: {
            let context = LoggingContext(identifier: $0, dispatcher: nil)
            context[metadataKey: "actorSystemAddress"] = .stringConvertible(self.system.settings.remoting.uniqueBindAddress)
            return ActorOriginLogHandler(context)
        })

        envelopeHandlerLog[metadataKey: "actorSystemAddress"] = .stringConvertible(self.system.settings.remoting.uniqueBindAddress)

        _ = context.channel.pipeline.addHandler(EnvelopeHandler(log: envelopeHandlerLog), name: "envelope handler", position: .last)
        _ = context.channel.pipeline.addHandler(SerializationHandler(system: self.system, serializationPool: self.serializationPool), name: "serialization handler", position: .last)
    }
}

enum HandlerRole {
    case client
    case server
}

/// Will send `HandshakeMagicBytes` as the first two bytes for a new connection
/// and remove itself from the pipeline afterwards.
private final class ProtocolMagicBytesPrepender: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var b = context.channel.allocator.buffer(capacity: 2)
        b.writeInteger(HandshakeMagicBytes, endianness: .big) // first bytes MUST be magic when initiating connection
        context.write(self.wrapOutboundOut(b), promise: nil)
        traceLog_Remote("WRITE MAGIC")

        context.writeAndFlush(data, promise: promise)
        context.pipeline.removeHandler(self, promise: nil)
    }
}

/// Validates that the first two bytes for a new connection are equal to `HandshakeMagicBytes`
/// and removes itself from the pipeline afterwards.
private final class ProtocolMagicBytesValidator: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)
        do {
            guard let leadingBytes = bytes.readInteger(as: UInt16.self) else  {
                throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: 16 / 8, hint: "handshake magic bytes")
            }

            if leadingBytes != HandshakeMagicBytes {
                throw SwiftDistributedActorsProtocolError.illegalHandshake(reason: HandshakeError.illegalHandshakeMagic(was: leadingBytes, expected: HandshakeMagicBytes))
            }
            bytes.discardReadBytes()
            traceLog_Remote("READ MAGIC")
            context.fireChannelRead(self.wrapInboundOut(bytes))
            context.pipeline.removeHandler(self, promise: nil)
        } catch {
            context.fireErrorCaught(error)
        }
    }
}

private final class EnvelopeHandler: ChannelDuplexHandler {
    typealias OutboundIn = Wire.Envelope
    typealias OutboundOut = ByteBuffer
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Wire.Envelope

    let log: Logger

    init(log: Logger) {
        self.log = log
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let envelope = self.unwrapOutboundIn(data)

        let protoEnvelope = ProtoEnvelope(fromEnvelope: envelope)
        do {
            let bytes = try protoEnvelope.serializedByteBuffer(allocator: context.channel.allocator)
            context.writeAndFlush(NIOAny(bytes), promise: promise)
        } catch {
            context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)

        do {
            let protoEnvelope = try ProtoEnvelope(bytes: &bytes)
            bytes.discardReadBytes()
            let envelope = try Wire.Envelope(protoEnvelope, allocator: context.channel.allocator)
            context.fireChannelRead(self.wrapInboundOut(envelope))
        } catch {
            context.fireErrorCaught(error)
        }
    }
}

private final class SerializationHandler: ChannelDuplexHandler {
    typealias OutboundIn = SerializationEnvelope
    typealias OutboundOut = Wire.Envelope
    typealias InboundIn = Wire.Envelope
    typealias InboundOut = Never

    let log: Logger

    let system: ActorSystem
    let serializationPool: SerializationPool

    init(system: ActorSystem, serializationPool: SerializationPool) {
        self.log = ActorLogger.make(system: system, identifier: "serialization-handler")
        self.system = system
        self.serializationPool = serializationPool
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let envelope = self.unwrapOutboundIn(data)
        let serializationPromise: EventLoopPromise<(Serialization.SerializerId, ByteBuffer)> = context.eventLoop.makePromise()
        self.serializationPool.serialize(message: envelope.message, metaType: envelope.metaType, recepientPath: envelope.recipient.path, promise: serializationPromise)
        serializationPromise.futureResult.whenComplete {
            switch $0 {
            case .success((let serializerId, let bytes)):
                // force unwrapping here is safe because we read exactly the amount of readable bytes
                let wireEnvelope = Wire.Envelope(recipient: envelope.recipient, serializerId: serializerId, payload: bytes)
                context.write(self.wrapOutboundOut(wireEnvelope), promise: promise)
            case .failure(let error):
                self.log.error("Error: \(error)")
                // TODO: drop message when it fails to be serialized?
                promise?.fail(error)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let wireEnvelope = self.unwrapInboundIn(data)
        let deserializationPromise: EventLoopPromise<Any> = context.eventLoop.makePromise()

        serializationPool.deserialize(serializerId: wireEnvelope.serializerId, from: wireEnvelope.payload, recepientPath: wireEnvelope.recipient.path, promise: deserializationPromise)

        // TODO: ensure message ordering. See comment in `write`.
        deserializationPromise.futureResult.whenComplete {
            switch $0 {
            case .success(let message):
                // TODO: Should this be in a separate stage?
                let envelope = SerializationEnvelope(message: message, recipient: wireEnvelope.recipient)
                let resolveContext = ResolveContext<Any>(path: envelope.recipient, deadLetters: self.system.deadLetters)
                let ref = self.system._resolveUntyped(context: resolveContext)
                ref._tellUnsafe(message: envelope.message)
            case .failure(let error):
                self.log.error("Error: \(error)")
            }
        }
    }
}

// MARK: Protobuf read... implementations

extension HandshakeHandler {
    /// Read length prefixed data
    func readHandshakeOffer(bytes: inout ByteBuffer) throws -> Wire.HandshakeOffer {
        guard let data = bytes.readData(length: bytes.readableBytes) else {
            throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: bytes.readableBytes, hint: "handshake offer")
        }
        let proto = try ProtoHandshakeOffer(serializedData: data)
        return try Wire.HandshakeOffer(proto) // TODO: version too, since we negotiate about it
    }

    // length prefixed
    func readHandshakeAccept(bytes: inout ByteBuffer) throws -> Wire.HandshakeAccept {
        guard let data = bytes.readData(length: bytes.readableBytes) else {
            throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: bytes.readableBytes, hint: "handshake accept")
        }
        let proto = try ProtoHandshakeAccept(serializedData: data)
        return try Wire.HandshakeAccept(proto)
    }
}

enum WireFormatError: Error {
    case missingField(String)
    case notEnoughBytes(expectedAtLeastBytes: Int, hint: String?)
}

private final class DumpRawBytesDebugHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let role: HandlerRole
    var log: Logger

    init(role: HandlerRole, log: Logger) {
        self.role = role
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.setLoggerMetadata(context)

        let event = self.unwrapInboundIn(data)
        self.log.debug("[dump-\(self.role)] Received: \(event.formatHexDump)")
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.setLoggerMetadata(context)

        log.error("Caught error: [\(error)]:\(type(of: error))")
        context.fireErrorCaught(error)
    }

    private func setLoggerMetadata(_ context: ChannelHandlerContext) {
        if let remoteAddress = context.remoteAddress { log.metadata["remoteAddress"] = .string("\(remoteAddress)") }
        if let localAddress = context.localAddress { log.metadata["localAddress"] = .string("\(localAddress)") }
    }
}

// MARK: "Server side" / accepting connections

extension RemotingKernel {

    // TODO: abstract into `Transport`

    // TODO do we need this ON kernel? could be pure function really hm
    internal func bootstrapServerSide(system: ActorSystem, kernel: RemotingKernel.Ref, log: Logger, bindAddress: UniqueNodeAddress, settings: RemotingSettings, serializationPool: SerializationPool) -> EventLoopFuture<Channel> {
        let group: EventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup() // TODO share the loop with client side?

        // TODO: Implement "setup" inside settings, so that parts of bootstrap can be done there, e.g. by end users without digging into remoting internals

        let bootstrap = ServerBootstrap(group: group)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { channel in

                // If SSL is enabled, we need to add the SSLServerHandler to the connection
                var channelHandlers: [(String?, ChannelHandler)] = []
                if var tlsConfig = settings.tls {
                    // We don't know who will try to talk to us, so we can't verify the hostname here
                    if tlsConfig.certificateVerification == .fullVerification {
                        tlsConfig.certificateVerification = .noHostnameVerification
                    }
                    do {
                        let sslContext = try self.makeSSLContext(fromConfig: tlsConfig, passphraseCallback: settings.tlsPassphraseCallback)
                        let sslHandler = try NIOSSLServerHandler(context: sslContext)
                        channelHandlers.append(("ssl", sslHandler))
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.

                let otherHandlers: [(String?, ChannelHandler)] = [
                    ("magic validator", ProtocolMagicBytesValidator()),
                    ("framing writer", LengthFieldPrepender(lengthFieldLength: .four, lengthFieldEndianness: .big)),
                    ("framing reader", ByteToMessageHandler(Framing(lengthFieldLength: .four, lengthFieldEndianness: .big))),
                    ("handshake handler", HandshakeHandler(system: system, kernel: kernel, role: .server, serializationPool: serializationPool)),
                    // FIXME only include for debug -DSACT_TRACE_NIO things?
                    ("bytes dumper", DumpRawBytesDebugHandler(role: .server, log: log)),
                ]

                channelHandlers.append(contentsOf: otherHandlers)

                return self.addChannelHandlers(channelHandlers, to: channel.pipeline)
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        return bootstrap.bind(host: bindAddress.address.host, port: Int(bindAddress.address.port)) // TODO separate setup from using it
    }

    internal func bootstrapClientSide(system: ActorSystem, kernel: RemotingKernel.Ref, log: Logger, targetAddress: NodeAddress, settings: RemotingSettings, serializationPool: SerializationPool) -> EventLoopFuture<Channel> {
        let group: EventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()

        // TODO: Implement "setup" inside settings, so that parts of bootstrap can be done there, e.g. by end users without digging into remoting internals

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                var channelHandlers: [(String?, ChannelHandler)] = []

                if let tlsConfig = settings.tls {
                    do {
                        let targetHost: String?
                        if tlsConfig.certificateVerification == .fullVerification {
                            targetHost = targetAddress.host
                        } else {
                            targetHost = nil
                        }

                        let sslContext = try self.makeSSLContext(fromConfig: tlsConfig, passphraseCallback: settings.tlsPassphraseCallback)
                        let sslHandler = try NIOSSLClientHandler.init(context: sslContext, serverHostname: targetHost)
                        channelHandlers.append(("ssl", sslHandler))
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                let otherHandlers: [(String?, ChannelHandler)] = [
                    ("magic prepender", ProtocolMagicBytesPrepender()),
                    ("framing writer", LengthFieldPrepender(lengthFieldLength: .four, lengthFieldEndianness: .big)),
                    ("framing reader", ByteToMessageHandler(Framing(lengthFieldLength: .four, lengthFieldEndianness: .big))),
                    ("handshake handler", HandshakeHandler(system: system, kernel: kernel, role: .client, serializationPool: serializationPool)),
                    ("bytes dumper", DumpRawBytesDebugHandler(role: .client, log: log)),
                ]

                channelHandlers.append(contentsOf: otherHandlers)

                return self.addChannelHandlers(channelHandlers, to: channel.pipeline)
            }

        return bootstrap.connect(host: targetAddress.host, port: Int(targetAddress.port)) // TODO separate setup from using it
    }

    private func addChannelHandlers(_ handlers: [(String?, ChannelHandler)], to pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        return pipeline.eventLoop.traverseIgnore(over: handlers) { (name, handler) in
            return pipeline.addHandler(handler, name: name)
        }
    }

    private func makeSSLContext(fromConfig tlsConfig: TLSConfiguration, passphraseCallback: NIOSSLPassphraseCallback<[UInt8]>?) throws -> NIOSSLContext {
        if let tlsPassphraseCallback = passphraseCallback {
            return try NIOSSLContext(configuration: tlsConfig, passphraseCallback: tlsPassphraseCallback)
        } else {
            return try NIOSSLContext(configuration: tlsConfig)
        }

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

internal extension EventLoop {

    /// Traverses over a collection and applies the given closure to all elements, while maintaining sequential execution order,
    /// i.e. each element will only be processed once the future returned from the previous call is completed. A failed future
    /// will cause the processing to end and the returned future will be failed.
    func traverseIgnore<T>(over elements: [T], _ closure: @escaping (T) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        guard let first = elements.first else {
            return self.makeSucceededFuture(())
        }

        var acc = closure(first)

        for element in elements.dropFirst() {
            acc = acc.flatMap { _ in
               closure(element)
            }
        }

        return acc
    }
}
