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
import class NIOExtras.LengthFieldBasedFrameDecoder
import class NIOExtras.LengthFieldPrepender
import NIOFoundationCompat
import NIOSSL

import Foundation
import struct Foundation.Data // FIXME: would want to not have to use Data in our infra as it forces us to copy
import Logging
import SwiftProtobuf

typealias Framing = LengthFieldBasedFrameDecoder

/// Error indicating that after an operation some unused bytes are left.
public struct LeftOverBytesError: Error {
    public let leftOverBytes: ByteBuffer
}

private final class InitiatingHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let log: Logger
    private let handshakeOffer: Wire.HandshakeOffer
    private let cluster: ClusterShell.Ref

    init(log: Logger, handshakeOffer: Wire.HandshakeOffer, cluster: ClusterShell.Ref) {
        self.log = log
        self.handshakeOffer = handshakeOffer
        self.cluster = cluster
    }

    func channelActive(context: ChannelHandlerContext) {
        self.initiateHandshake(context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)

        do {
            let response = try self.readHandshakeResponse(bytes: &bytes)
            switch response {
            case .accept(let accept):
                self.log.debug("Received handshake accept from: [\(accept.from)]")
                self.cluster.tell(.inbound(.handshakeAccepted(accept, channel: context.channel)))

                // handshake is completed, so we remove the handler from the pipeline
                context.pipeline.removeHandler(self, promise: nil)

            case .reject(let reject):
                self.log.debug("Received handshake reject from: [\(reject.from)] reason: [\(reject.reason)]")
                self.cluster.tell(.inbound(.handshakeRejected(reject)))
                context.close(promise: nil)
            }
        } catch {
            self.cluster.tell(.inbound(.handshakeFailed(self.handshakeOffer.to, error)))
            context.fireErrorCaught(error)
        }
    }

    private func initiateHandshake(context: ChannelHandlerContext) {
        let proto = ProtoHandshakeOffer(self.handshakeOffer)
        self.log.debug("Offering handshake [\(proto)]")

        do {
            // TODO: allow allocating into existing buffer
            // FIXME: serialization SHOULD be on dedicated part... put it into ELF already?
            let bytes: ByteBuffer = try proto.serializedByteBuffer(allocator: context.channel.allocator)
            // TODO: should we use the serialization infra ourselves here? I guess so...

            // FIXME: make the promise dance here
            context.writeAndFlush(self.wrapOutboundOut(bytes), promise: nil)
        } catch {
            // TODO: change since serialization which can throw should be shipped of to a future
            // ---- since now we blocked the actor basically with the serialization
            context.fireErrorCaught(error)
        }
    }
}

final class ReceivingHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Never

    private let log: Logger
    private let cluster: ClusterShell.Ref
    private let localNode: UniqueNode

    init(log: Logger, cluster: ClusterShell.Ref, localNode: UniqueNode) {
        self.log = log
        self.cluster = cluster
        self.localNode = localNode
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            var bytes = self.unwrapInboundIn(data)
            // TODO: formalize wire format...
            let offer = try self.readHandshakeOffer(bytes: &bytes)

            self.log.debug("Received handshake offer from: [\(offer.from)] with protocol version: [\(offer.version)]")

            let promise = context.eventLoop.makePromise(of: Wire.HandshakeResponse.self)
            self.cluster.tell(.inbound(.handshakeOffer(offer, channel: context.channel, replyTo: promise)))

            promise.futureResult.onComplete { res in
                switch res {
                case .failure(let err):
                    context.fireErrorCaught(err)
                case .success(.accept(let accept)):
                    self.log.debug("Accepting handshake offer from: [\(offer.from)]")
                    let acceptProto = ProtoHandshakeAccept(accept)
                    var proto = ProtoHandshakeResponse()
                    proto.accept = acceptProto
                    do {
                        let bytes = try proto.serializedByteBuffer(allocator: context.channel.allocator)
                        context.writeAndFlush(NIOAny(bytes), promise: nil)
                        // we are done with the handshake, so we can remove it and add envelope and serialization handler to process actual messages
                        context.pipeline.removeHandler(self, promise: nil)
                    } catch {
                        context.fireErrorCaught(error)
                    }
                case .success(.reject(let reject)):
                    self.log.debug("Rejecting handshake offer from: [\(offer.from)] reason: [\(reject.reason)]")
                    let rejectProto = ProtoHandshakeReject(reject)
                    var proto = ProtoHandshakeResponse()
                    proto.reject = rejectProto
                    do {
                        let bytes = try proto.serializedByteBuffer(allocator: context.channel.allocator)
                        context.writeAndFlush(NIOAny(bytes), promise: nil)
                        // we are done with the handshake, so we can remove it and add envelope and serialization handler to process actual messages
                        context.pipeline.removeHandler(self, promise: nil)
                    } catch {
                        context.fireErrorCaught(error)
                    }
                }
            }
        } catch {
            context.fireErrorCaught(error)
        }
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
            guard let leadingBytes = bytes.readInteger(as: UInt16.self) else {
                throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: 16 / 8, hint: "handshake magic bytes")
            }

            if leadingBytes != HandshakeMagicBytes {
                throw ActorsProtocolError.illegalHandshake(reason: HandshakeError.illegalHandshakeMagic(was: leadingBytes, expected: HandshakeMagicBytes))
            }
            bytes.discardReadBytes()
            context.fireChannelRead(self.wrapInboundOut(bytes))
            context.pipeline.removeHandler(self, promise: nil)
        } catch {
            context.fireErrorCaught(error)
        }
    }
}

private final class WireEnvelopeHandler: ChannelDuplexHandler {
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
        let protoEnvelope = ProtoEnvelope(envelope)
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
    typealias OutboundIn = TransportEnvelope
    typealias OutboundOut = Wire.Envelope
    typealias InboundIn = Wire.Envelope
    typealias InboundOut = TransportEnvelope

    let log: Logger

    let serializationPool: SerializationPool

    init(log: Logger, serializationPool: SerializationPool) {
        self.log = log
        self.serializationPool = serializationPool
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let transportEnvelope: TransportEnvelope = self.unwrapOutboundIn(data)
        let serializationPromise: EventLoopPromise<(Serialization.SerializerId, ByteBuffer)> = context.eventLoop.makePromise()

        self.serializationPool.serialize(
            message: transportEnvelope.underlyingMessage, metaType: transportEnvelope.underlyingMessageMetaType,
            recipientPath: transportEnvelope.recipient.path,
            promise: serializationPromise
        )

        serializationPromise.futureResult.whenComplete {
            switch $0 {
            case .success((let serializerId, let bytes)):
                // force unwrapping here is safe because we read exactly the amount of readable bytes
                let wireEnvelope = Wire.Envelope(recipient: transportEnvelope.recipient, serializerId: serializerId, payload: bytes)
                context.write(self.wrapOutboundOut(wireEnvelope), promise: promise)
            case .failure(let error):
                self.log.error("Serialization of outgoing message failed: \(error)",
                               metadata: [
                                   "recipient": "\(transportEnvelope.recipient)",
                                   "serializerId": "\(self.serializationPool.serialization.serializerIdFor(metaType: transportEnvelope.underlyingMessageMetaType), orElse: "<no-serializer>")",
                               ])
                // TODO: drop message when it fails to be serialized?
                promise?.fail(error)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let wireEnvelope = self.unwrapInboundIn(data)

        let deserializationPromise: EventLoopPromise<Any> = context.eventLoop.makePromise()
        serializationPool.deserialize(
            serializerId: wireEnvelope.serializerId,
            from: wireEnvelope.payload, recipientPath: wireEnvelope.recipient.path,
            promise: deserializationPromise
        )

        // TODO: ensure message ordering. See comment in `write`.
        deserializationPromise.futureResult.whenComplete { deserializedResult in
            switch deserializedResult {
            case .success(let message) where wireEnvelope.serializerId == Serialization.SystemMessageEnvelopeSerializerId:
                context.fireChannelRead(self.wrapInboundOut(TransportEnvelope(systemMessageEnvelope: message as! SystemMessageEnvelope, recipient: wireEnvelope.recipient)))

            case .success(let message) where wireEnvelope.serializerId == Serialization.SystemMessageACKSerializerId:
                context.fireChannelRead(self.wrapInboundOut(TransportEnvelope(ack: message as! SystemMessage.ACK, recipient: wireEnvelope.recipient)))
            case .success(let message) where wireEnvelope.serializerId == Serialization.SystemMessageNACKSerializerId:
                context.fireChannelRead(self.wrapInboundOut(TransportEnvelope(nack: message as! SystemMessage.NACK, recipient: wireEnvelope.recipient)))

            case .success(let message) where wireEnvelope.serializerId == Serialization.SystemMessageSerializerId:
                context.fireChannelRead(self.wrapInboundOut(TransportEnvelope(systemMessage: message as! SystemMessage, recipient: wireEnvelope.recipient)))

            case .success(let message):
                context.fireChannelRead(self.wrapInboundOut(TransportEnvelope(message: message, recipient: wireEnvelope.recipient)))

            case .failure(let error):
                self.log.error("Deserialization error: \(error)", metadata: ["recipient": "\(wireEnvelope.recipient)"])
            }
        }
    }
}

/// Handles `SystemMessage` re-delivery, by exchanging sequence numbered envelopes and (N)ACKs.
///
/// It follows the "Shell" pattern, all actual logic is implemented in the `OutboundSystemMessageRedelivery`
/// and `InboundSystemMessages`
internal final class SystemMessageRedeliveryHandler: ChannelDuplexHandler {
    typealias OutboundIn = TransportEnvelope
    typealias OutboundOut = TransportEnvelope
    typealias InboundIn = TransportEnvelope
    typealias InboundOut = TransportEnvelope

    private let log: Logger
    private let clusterShell: ClusterShell.Ref

    internal let outboundSystemMessages: OutboundSystemMessageRedelivery
    internal let inboundSystemMessages: InboundSystemMessages

    struct RedeliveryTick {}
    private var redeliveryScheduled: Scheduled<RedeliveryTick>?

    init(log: Logger, cluster: ClusterShell.Ref, outbound: OutboundSystemMessageRedelivery, inbound: InboundSystemMessages) {
        self.log = log
        self.clusterShell = cluster

        self.outboundSystemMessages = outbound
        self.inboundSystemMessages = inbound

        self.redeliveryScheduled = nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Outbound

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let transportEnvelope: TransportEnvelope = self.unwrapOutboundIn(data)

        guard case .systemMessage(let systemMessage) = transportEnvelope.storage else {
            // pass along any other messages
            context.write(data, promise: promise)
            return
        }

        switch self.outboundSystemMessages.offer(systemMessage, recipient: transportEnvelope.recipient) {
        case .send(let systemEnvelope):
            // message was additionally wrapped in redelivery system envelope, we shall push this rather than the
            // original serialization envelope;
            let redeliveryEnvelope = TransportEnvelope(systemMessageEnvelope: systemEnvelope, recipient: transportEnvelope.recipient)

            self.tracelog(.outbound, message: redeliveryEnvelope)
            context.writeAndFlush(self.wrapOutboundOut(redeliveryEnvelope), promise: promise)
        case .bufferOverflowMustAbortAssociation:
            if let node = transportEnvelope.recipient.node {
                // TODO: use ClusterControl once implemented
                self.clusterShell.tell(.command(.downCommand(node.node)))
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let transportEnvelope: TransportEnvelope = self.unwrapInboundIn(data)
        switch transportEnvelope.storage {
        case .message:
            // pass through, the happy path for all user messages
            context.fireChannelRead(self.wrapInboundOut(transportEnvelope))

        case .systemMessageEnvelope(let systemMessageEnvelope):
            self.tracelog(.inbound, message: transportEnvelope)
            self.onInboundSystemMessage(context, systemEnvelope: systemMessageEnvelope, recipient: transportEnvelope.recipient)

        case .systemMessageDelivery(.ack(let ack)):
            self.tracelog(.inbound, message: transportEnvelope)
            self.onInboundACK(ack: ack)

        case .systemMessageDelivery(.nack(let nack)):
            self.tracelog(.inbound, message: transportEnvelope)
            self.onInboundNACK(context, nack: nack)

        case .systemMessage(let message):
            fatalError("\(self) should only receive system messages wrapped in SystemMessage envelope from the wire! This is a bug. Got: \(message)")
        }
    }

    private func onInboundSystemMessage(_ context: ChannelHandlerContext, systemEnvelope: SystemMessageEnvelope, recipient: ActorAddress) {
        switch self.inboundSystemMessages.onDelivery(systemEnvelope) {
        case .accept(let ack):
            // we unwrap the system envelope, as the ActorDelivery handler does not need to care about any sequence numbers anymore
            context.fireChannelRead(self.wrapInboundOut(TransportEnvelope(systemMessage: systemEnvelope.message, recipient: recipient)))

            // TODO: potential for coalescing some ACKs here; schedule "lets write back in 300ms"
            let ackEnvelope = TransportEnvelope(ack: ack, recipient: recipient)
            self.tracelog(.outbound, message: ackEnvelope)
            context.writeAndFlush(self.wrapOutboundOut(ackEnvelope), promise: nil)

        case .gapDetectedRequestRedelivery(let nack):
            let nackEnvelope = TransportEnvelope(nack: nack, recipient: recipient)
            self.tracelog(.outbound, message: nackEnvelope)
            context.writeAndFlush(self.wrapOutboundOut(nackEnvelope), promise: nil)

        case .acceptRedelivery(let ack):
            self.log.trace("Received harmless re-delivery of already accepted message at [sequenceNr: \(systemEnvelope.sequenceNr)]. Sending back [\(ack)].")

            // TODO: potential for coalescing some ACKs here; schedule "lets write back in 300ms"
            let ackEnvelope = TransportEnvelope(ack: ack, recipient: recipient)
            self.tracelog(.outbound, message: ackEnvelope)
            context.writeAndFlush(self.wrapOutboundOut(ackEnvelope), promise: nil)
        }
    }

    private func onInboundACK(ack: SystemMessage.ACK) {
        switch self.outboundSystemMessages.acknowledge(ack) {
        case .acknowledged:
            return // good, and do not pass the ACK through the pipeline, we handled it completely just now

        case .ackWasForFutureSequenceNr(let highestKnownSeqNr):
            self.log.warning("""
            Received unexpected system message [ACK(\(ack.sequenceNr))], while highest known (sent) \
            system message was [sequenceNr:\(highestKnownSeqNr)]. \
            Ignoring as harmless, however peer might be misbehaving.
            """) // TODO: metadata: self.outboundSystemMessages.metadata
        }
    }

    private func onInboundNACK(_ context: ChannelHandlerContext, nack: SystemMessage.NACK) {
        switch self.outboundSystemMessages.negativeAcknowledge(nack) {
        case .ensureRedeliveryTick(let nextRedeliveryTickDelay):
            self.scheduleNextRedeliveryTick(context, in: nextRedeliveryTickDelay)
        case .nothingToReDeliver:
            self.log.trace("Received NACK however no messages to redeliver.")

        case .nackWasForFutureSequenceNr(let highestKnownSeqNr):
            self.log.warning("""
            Received unexpected system message [NACK(\(nack.sequenceNr))], while highest known (sent) \
            system message was [sequenceNd:\(highestKnownSeqNr)]. \
            Ignoring as harmless, however peer migh be misbehaving.
            """) // TODO: metadata: self.outboundSystemMessages.metadata
        }
    }

    private func onRedeliveryTick(_ context: ChannelHandlerContext) {
        switch self.outboundSystemMessages.onRedeliveryTick() {
        case .redeliver(let envelopes, let nextRedeliveryTickDelay):
            for redelivery in envelopes {
                self.tracelog(.outboundRedelivery, message: redelivery)
                context.write(self.wrapOutboundOut(redelivery), promise: nil)
            }
            context.flush()

            self.scheduleNextRedeliveryTick(context, in: nextRedeliveryTickDelay)

        case .giveUpAndSeverTies:
            // FIXME: implement this once we have the Kill or Down command on cluster shell
            // cluster.tell(Down(that node))
            fatalError("TODO; kill the connection notify the membership!!!!")
        }
    }

    private func scheduleNextRedeliveryTick(_ context: ChannelHandlerContext, in nextRedeliveryDelay: TimeAmount) {
        guard self.redeliveryScheduled == nil else {
            return // already a tick scheduled, we'll ride on that one rather than kick off a new one
        }

        self.redeliveryScheduled = context.eventLoop.scheduleTask(in: nextRedeliveryDelay.toNIO) {
            RedeliveryTick()
        }
        self.redeliveryScheduled?.futureResult.onComplete { _ in
            self.redeliveryScheduled = nil
            self.onRedeliveryTick(context)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: tracelog: System Redelivery [tracelog:sys-msg-redelivery]

extension SystemMessageRedeliveryHandler {
    /// Optional "dump all messages" logging.
    private func tracelog(_ type: TraceLogType, message: Any,
                          file: String = #file, function: String = #function, line: UInt = #line) {
        let level: Logger.Level?
        switch type {
        case .outbound, .outboundRedelivery:
            level = self.outboundSystemMessages.settings.tracelogLevel
        case .inbound:
            level = self.inboundSystemMessages.settings.tracelogLevel
        }

        if let level = level {
            self.log.log(
                level: level,
                "[tracelog:sys-msg-redelivery] \(type.description): \(message)",
                file: file, function: function, line: line
            )
        }
    }

    internal enum TraceLogType: CustomStringConvertible {
        case inbound
        case outbound
        case outboundRedelivery

        var description: String {
            switch self {
            case .inbound:
                return "IN    "
            case .outbound:
                return "OUT   "
            case .outboundRedelivery:
                return "OUT-RE"
            }
        }
    }
}

private final class ActorDeliveryHandler: ChannelInboundHandler {
    typealias InboundIn = TransportEnvelope
    typealias InboundOut = Never // we terminate here, by sending messages off to local actors

    let log: Logger
    let system: ActorSystem

    init(system: ActorSystem) {
        self.log = ActorLogger.make(system: system, identifier: "message-delivery")
        self.system = system
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let transportEnvelope: TransportEnvelope = self.unwrapInboundIn(data)

        let resolveContext = ResolveContext<Any>(address: transportEnvelope.recipient, system: self.system)
        let ref = self.system._resolveUntyped(context: resolveContext)

        switch transportEnvelope.storage {
        case .message(let message):
            ref._tellOrDeadLetter(message)
        case .systemMessage(let message):
            ref.sendSystemMessage(message)
        case .systemMessageEnvelope(let systemMessageEnvelope):
            fatalError("""
            .systemMessageEnvelope should not be allowed through to the \(self) handler! \
            The \(SystemMessageRedeliveryHandler.self) should have peeled off the system envelope. \
            This is a bug in pipeline construction! Was: \(systemMessageEnvelope)
            """)
        case .systemMessageDelivery(let delivery):
            fatalError("""
            .systemMessageDelivery should not be allowed through to the \(self) handler! 
            The \(SystemMessageRedeliveryHandler.self) should have stopped the propagation of delivery confirmations. \
            This is a bug in pipeline construction! Was: \(delivery)
            """)
        }
    }
}

// MARK: Protobuf read... implementations

extension InitiatingHandshakeHandler {
    // length prefixed
    func readHandshakeResponse(bytes: inout ByteBuffer) throws -> Wire.HandshakeResponse {
        guard let data = bytes.readData(length: bytes.readableBytes) else {
            throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: bytes.readableBytes, hint: "handshake accept")
        }
        let proto = try ProtoHandshakeResponse(serializedData: data)
        return try Wire.HandshakeResponse(proto)
    }
}

extension ReceivingHandshakeHandler {
    /// Read length prefixed data
    func readHandshakeOffer(bytes: inout ByteBuffer) throws -> Wire.HandshakeOffer {
        guard let data = bytes.readData(length: bytes.readableBytes) else {
            throw WireFormatError.notEnoughBytes(expectedAtLeastBytes: bytes.readableBytes, hint: "handshake offer")
        }
        let proto = try ProtoHandshakeOffer(serializedData: data)
        return try Wire.HandshakeOffer(fromProto: proto)
    }
}

enum WireFormatError: Error {
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
        self.log.debug("[dump-\(self.role)] Received: \(event.formatHexDump(maxBytes: 10000))")
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.setLoggerMetadata(context)

        log.error("Caught error: [\(error)]:\(type(of: error))")
        context.fireErrorCaught(error)
    }

    private func setLoggerMetadata(_ context: ChannelHandlerContext) {
        if let remoteAddress = context.remoteAddress { log[metadataKey: "remoteAddress"] = .string("\(remoteAddress)") }
        if let localAddress = context.localAddress { log[metadataKey: "localAddress"] = .string("\(localAddress)") }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: "Server side" / accepting connections

extension ClusterShell {
    // TODO: abstract into `Transport`?

    internal func bootstrapServerSide(system: ActorSystem, shell: ClusterShell.Ref, bindAddress: UniqueNode, settings: ClusterSettings, serializationPool: SerializationPool) -> EventLoopFuture<Channel> {
        let group: EventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup() // TODO: share the loop with client side?

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

                let log = ActorLogger.make(system: system, identifier: "server")

                // FIXME: PASS IN FROM ASSOCIATION SINCE MUST SURVIVE CONNECTIONS !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                let outboundSysMsgs = OutboundSystemMessageRedelivery(settings: .default)
                let inboundSysMsgs = InboundSystemMessages(settings: .default)
                // FIXME: PASS IN FROM ASSOCIATION SINCE MUST SURVIVE CONNECTIONS !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

                // TODO: Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                let otherHandlers: [(String?, ChannelHandler)] = [
                    // reads go this way: vvv
                    ("magic validator", ProtocolMagicBytesValidator()),
                    ("framing writer", LengthFieldPrepender(lengthFieldLength: .four, lengthFieldEndianness: .big)),
                    ("framing reader", ByteToMessageHandler(Framing(lengthFieldLength: .four, lengthFieldEndianness: .big))),
                    ("receiving handshake handler", ReceivingHandshakeHandler(log: log, cluster: shell, localNode: bindAddress)),
                    // ("bytes dumper", DumpRawBytesDebugHandler(role: .server, log: log)), // FIXME only include for debug -DSACT_TRACE_NIO things?
                    ("wire envelope handler", WireEnvelopeHandler(log: log)),
                    ("serialization handler", SerializationHandler(log: log, serializationPool: serializationPool)),
                    ("system message re-delivery", SystemMessageRedeliveryHandler(log: log, cluster: shell, outbound: outboundSysMsgs, inbound: inboundSysMsgs)),
                    ("message delivery", ActorDeliveryHandler(system: system)),
                    // writes go this way: ^^^
                ]

                channelHandlers.append(contentsOf: otherHandlers)

                return self.addChannelHandlers(channelHandlers, to: channel.pipeline)
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        return bootstrap.bind(host: bindAddress.node.host, port: Int(bindAddress.node.port)) // TODO: separate setup from using it
    }

    internal func bootstrapClientSide(system: ActorSystem, shell: ClusterShell.Ref, targetNode: Node, handshakeOffer: Wire.HandshakeOffer, settings: ClusterSettings, serializationPool: SerializationPool) -> EventLoopFuture<Channel> {
        let group: EventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()

        // TODO: Implement "setup" inside settings, so that parts of bootstrap can be done there, e.g. by end users without digging into remoting internals

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: settings.connectTimeout.toNIO)
            .channelInitializer { channel in
                var channelHandlers: [(String?, ChannelHandler)] = []

                if let tlsConfig = settings.tls {
                    do {
                        let targetHost: String?
                        if tlsConfig.certificateVerification == .fullVerification {
                            targetHost = targetNode.host
                        } else {
                            targetHost = nil
                        }

                        let sslContext = try self.makeSSLContext(fromConfig: tlsConfig, passphraseCallback: settings.tlsPassphraseCallback)
                        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: targetHost)
                        channelHandlers.append(("ssl", sslHandler))
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                let log = ActorLogger.make(system: system, identifier: "client")

                // FIXME: PASS IN FROM ASSOCIATION SINCE MUST SURVIVE CONNECTIONS !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                let outboundSysMsgs = OutboundSystemMessageRedelivery(settings: .default)
                let inboundSysMsgs = InboundSystemMessages(settings: .default)
                // FIXME: PASS IN FROM ASSOCIATION SINCE MUST SURVIVE CONNECTIONS !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

                let otherHandlers: [(String?, ChannelHandler)] = [
                    // reads go this way: vvv
                    ("magic prepender", ProtocolMagicBytesPrepender()),
                    ("framing writer", LengthFieldPrepender(lengthFieldLength: .four, lengthFieldEndianness: .big)),
                    ("framing reader", ByteToMessageHandler(Framing(lengthFieldLength: .four, lengthFieldEndianness: .big))),
                    ("initiating handshake handler", InitiatingHandshakeHandler(log: log, handshakeOffer: handshakeOffer, cluster: shell)),
                    // ("bytes dumper", DumpRawBytesDebugHandler(role: .client, log: log)), // FIXME make available via compilation flag
                    ("envelope handler", WireEnvelopeHandler(log: log)),
                    ("serialization handler", SerializationHandler(log: log, serializationPool: serializationPool)),
                    ("system message re-delivery", SystemMessageRedeliveryHandler(log: log, cluster: shell, outbound: outboundSysMsgs, inbound: inboundSysMsgs)),
                    ("message delivery", ActorDeliveryHandler(system: system)),
                    // writes go this way: ^^^
                ]

                channelHandlers.append(contentsOf: otherHandlers)

                return self.addChannelHandlers(channelHandlers, to: channel.pipeline)
            }

        return bootstrap.connect(host: targetNode.host, port: Int(targetNode.port)) // TODO: separate setup from using it
    }

    private func addChannelHandlers(_ handlers: [(String?, ChannelHandler)], to pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        let res = pipeline.eventLoop.traverseIgnore(over: handlers) { name, handler in
            pipeline.addHandler(handler, name: name)
        }

        // uncomment to print pipeline visualization:
        // pprint("PIPELINE: \(pipeline)")

        return res
    }

    private func makeSSLContext(fromConfig tlsConfig: TLSConfiguration, passphraseCallback: NIOSSLPassphraseCallback<[UInt8]>?) throws -> NIOSSLContext {
        if let tlsPassphraseCallback = passphraseCallback {
            return try NIOSSLContext(configuration: tlsConfig, passphraseCallback: tlsPassphraseCallback)
        } else {
            return try NIOSSLContext(configuration: tlsConfig)
        }
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: TransportEnvelope

/// Mirrors `Envelope` however ensures that the payload is a message; i.e. it cannot be a closure.
internal struct TransportEnvelope: CustomStringConvertible, CustomDebugStringConvertible {
    let storage: Storage
    enum Storage {
        /// Note: MAY contain SystemMessageEnvelope
        case message(Any)
        // ~~ outbound ~~
        case systemMessage(SystemMessage)
        // ~~ inbound only ~~
        case systemMessageEnvelope(SystemMessageEnvelope)
        case systemMessageDelivery(SystemMessageDelivery)
    }

    // TODO: we could merge ACK and NACK if NACKs were to carry "the gap"
    enum SystemMessageDelivery {
        case ack(SystemMessage.ACK)
        case nack(SystemMessage.NACK)
    }

    let recipient: ActorAddress

    let underlyingMessageMetaType: AnyMetaType

    // TODO: carry same data as Envelope -- baggage etc

    init<UnderlyingMessage>(envelope: Envelope, underlyingMessageType: UnderlyingMessage.Type, recipient: ActorAddress) {
        switch envelope.payload {
        case .message(let message):
            self.storage = .message(message)
        case .closure:
            fatalError("Attempted to send .closure to remote actor, this is illegal and can not be made to work. Envelope: \(envelope), recipient: \(recipient)")
        }
        self.recipient = recipient
        self.underlyingMessageMetaType = MetaType(underlyingMessageType)
        // TODO: carry metadata from Envelope
    }

    init<Message>(message: Message, recipient: ActorAddress) {
        // assert(Message.self != Any.self)
        self.storage = .message(message)
        self.recipient = recipient
        self.underlyingMessageMetaType = MetaType(Message.self)
    }

    init(systemMessage: SystemMessage, recipient: ActorAddress) {
        self.storage = .systemMessage(systemMessage)
        self.recipient = recipient
        self.underlyingMessageMetaType = MetaType(SystemMessage.self)
    }

    init(systemMessageEnvelope: SystemMessageEnvelope, recipient: ActorAddress) {
        self.storage = .systemMessageEnvelope(systemMessageEnvelope)
        self.recipient = recipient
        self.underlyingMessageMetaType = MetaType(SystemMessageEnvelope.self)
    }

    init(ack: SystemMessage.ACK, recipient: ActorAddress) {
        self.storage = .systemMessageDelivery(.ack(ack))
        self.recipient = recipient
        self.underlyingMessageMetaType = MetaType(SystemMessage.ACK.self)
    }

    init(nack: SystemMessage.NACK, recipient: ActorAddress) {
        self.storage = .systemMessageDelivery(.nack(nack))
        self.recipient = recipient
        self.underlyingMessageMetaType = MetaType(SystemMessage.NACK.self)
    }

    /// Unwraps *ONE* layer of envelope
    ///
    /// I.e. if this envelope contained the system envelope -- the system envelope will be returned,
    /// for other messages, the actual message is returned.
    var underlyingMessage: Any {
        switch self.storage {
        case .message(let message):
            return message
        case .systemMessage(let message):
            return message
        case .systemMessageEnvelope(let systemEnvelope):
            return systemEnvelope
        case .systemMessageDelivery(.ack(let ack)):
            return ack
        case .systemMessageDelivery(.nack(let nack)):
            return nack
        }
    }

    var description: String {
        return "TransportEnvelope(\(storage), recipient: \(recipient), messageMetaType: \(underlyingMessageMetaType))"
    }

    var debugDescription: String {
        return "TransportEnvelope(_storage: \(storage), recipient: \(recipient), messageMetaType: \(underlyingMessageMetaType))"
    }
}
