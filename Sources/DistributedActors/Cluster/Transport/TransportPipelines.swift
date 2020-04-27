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
        self.log.trace("Offering handshake [\(proto)]")

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
            self.cluster.tell(.inbound(.handshakeOffer(offer, channel: context.channel, replyInto: promise)))

            promise.futureResult.whenComplete { res in
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
            let data = bytes.readData(length: bytes.readableBytes)! // safe since using readableBytes
            let protoEnvelope = try ProtoEnvelope(serializedData: data)
            bytes.discardReadBytes()
            let envelope = try Wire.Envelope(protoEnvelope)
            context.fireChannelRead(self.wrapInboundOut(envelope))
        } catch {
            context.fireErrorCaught(error)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Outbound Message handler

final class OutboundSerializationHandler: ChannelOutboundHandler {
    typealias OutboundIn = TransportEnvelope
    typealias OutboundOut = Wire.Envelope

    let log: Logger
    let serializationPool: SerializationPool

    init(log: Logger, serializationPool: SerializationPool) {
        self.log = log
        self.serializationPool = serializationPool
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.serializeThenWrite(context, envelope: self.unwrapOutboundIn(data), promise: promise)
    }

    private func serializeThenWrite(_ context: ChannelHandlerContext, envelope transportEnvelope: TransportEnvelope, promise: EventLoopPromise<Void>?) {
        let serializationPromise: EventLoopPromise<Serialization.Serialized> = context.eventLoop.makePromise()

        self.serializationPool.serialize(
            message: transportEnvelope.underlyingMessage,
            recipientPath: transportEnvelope.recipient.path,
            promise: serializationPromise
        )

        serializationPromise.futureResult.whenComplete {
            switch $0 {
            case .success(let serialized):
                // force unwrapping here is safe because we read exactly the amount of readable bytes
                let wireEnvelope = Wire.Envelope(
                    recipient: transportEnvelope.recipient,
                    payload: serialized.buffer,
                    manifest: serialized.manifest
                )
                context.write(self.wrapOutboundOut(wireEnvelope), promise: promise)

            case .failure(let error):
                self.log.error(
                    "Serialization of outgoing message failed: \(error)",
                    metadata: [
                        "recipient": "\(transportEnvelope.recipient)",
                    ]
                )
                // TODO: drop message when it fails to be serialized?
                promise?.fail(error)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: System Message Redelivery

/// Handles `SystemMessage` re-delivery, by exchanging sequence numbered envelopes and (N)ACKs.
///
/// It follows the "Shell" pattern, all actual logic is implemented in the `OutboundSystemMessageRedelivery`
/// and `InboundSystemMessages`
internal final class SystemMessageRedeliveryHandler: ChannelDuplexHandler {
    // we largely pass-through messages, however if they are system messages we keep them buffered for potential re-delivery
    typealias OutboundIn = TransportEnvelope
    typealias OutboundOut = TransportEnvelope

    typealias InboundIn = Wire.Envelope // we handle deserialization in case it is about a system message (since message == system message envelope)
    typealias InboundOut = Wire.Envelope // we pass along user messages; all system messages are handled in-place here (ack, nack), or delivered directly to the recipient from this handler

    private let log: Logger
    private let system: ActorSystem
    private let clusterShell: ClusterShell.Ref

    private let serializationPool: SerializationPool

    internal let outboundSystemMessages: OutboundSystemMessageRedelivery
    internal let inboundSystemMessages: InboundSystemMessages

    struct RedeliveryTick {}
    private var redeliveryScheduled: Scheduled<RedeliveryTick>?

    init(
        log: Logger,
        system: ActorSystem,
        cluster: ClusterShell.Ref,
        serializationPool: SerializationPool,
        outbound: OutboundSystemMessageRedelivery,
        inbound: InboundSystemMessages
    ) {
        self.log = log
        self.system = system
        self.clusterShell = cluster
        self.serializationPool = serializationPool

        self.outboundSystemMessages = outbound
        self.inboundSystemMessages = inbound

        self.redeliveryScheduled = nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Outbound: Store System messages for re-delivery, pass along all other ones

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
            self.log.error("Outbound system message queue overflow! MUST abort association, system state integrity cannot be ensured (e.g. terminated signals may have been lost).")
            if let node = transportEnvelope.recipient.node {
                self.clusterShell.tell(.command(.downCommand(node.node)))
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Inbound: If the message is definitely a system message (we know thanks to the manifests serializerID) decode and handle it

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let wireEnvelope = self.unwrapInboundIn(data)

        // TODO: optimize by carrying ID in envelope of if we need to special handle this as system message
        let Type = try? self.serializationPool.serialization.summonType(from: wireEnvelope.manifest)
        if Type == SystemMessageEnvelope.self {
            self.deserializeThenHandle(type: SystemMessageEnvelope.self, wireEnvelope: wireEnvelope) { envelope in
                self.onInboundSystemMessage(context, systemEnvelope: envelope, wireEnvelope: wireEnvelope)
            }
        } else if Type == _SystemMessage.ACK.self {
            self.deserializeThenHandle(type: _SystemMessage.ACK.self, wireEnvelope: wireEnvelope) { ack in
                self.onInboundACK(ack: ack)
            }
        } else if Type == _SystemMessage.NACK.self {
            self.deserializeThenHandle(type: _SystemMessage.NACK.self, wireEnvelope: wireEnvelope) { nack in
                self.onInboundNACK(context, nack: nack)
            }
        } else if Type == _SystemMessage.self {
            log.error("""
            Received _SystemMessage manifest! This should never happen, as system messages should ALWAYS travel in `SystemMessageEnvelope`s. \
            Remote: \(reflecting: context.remoteAddress), manifest: \(wireEnvelope.manifest)
            """)
        } else {
            // it's a normal message, so we should directly pass it along
            context.fireChannelRead(self.wrapInboundOut(wireEnvelope))
        }
    }

    private func deserializeThenHandle<T>(type: T.Type, wireEnvelope: Wire.Envelope, callback: @escaping (T) -> Void) {
        self.serializationPool.deserializeAny(
            from: wireEnvelope.payload, using: wireEnvelope.manifest,
            recipientPath: wireEnvelope.recipient.path, // TODO: use addresses
            callback: .init { result in
                self.tracelog(.inbound, message: wireEnvelope)
                switch result {
                case .success(.message(let message as T)):
                    callback(message)
                case .success(.message(let message)):
                    self.log.error("Unable to cast system message \(message) as \(T.self)!")
                case .success(.deadLetter(let message)):
                    self.log.error("Deserialized as system message dead letter, this is highly suspect; Type \(type), wireEnvelope: \(wireEnvelope), message: \(message)")
                case .failure(let error):
                    self.log.error("Failed to deserialize \(type), wireEnvelope: \(wireEnvelope), error: \(error)")
                }
            }
        )
    }

    private func onInboundSystemMessage(_ context: ChannelHandlerContext, systemEnvelope: SystemMessageEnvelope, wireEnvelope: Wire.Envelope) {
        let recipient = wireEnvelope.recipient

        switch self.inboundSystemMessages.onDelivery(systemEnvelope) {
        case .accept(let ack):
            // unwrap and immediately deliver the message; we do not need to forward it to the user-message handler
            let ref = self.system._resolveUntyped(context: .init(address: wireEnvelope.recipient, system: self.system))
            ref._sendSystemMessage(systemEnvelope.message)

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

    private func onInboundACK(ack: _SystemMessage.ACK) {
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

    private func onInboundNACK(_ context: ChannelHandlerContext, nack: _SystemMessage.NACK) {
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
        self.redeliveryScheduled?.futureResult.whenComplete { _ in
            self.redeliveryScheduled = nil
            self.onRedeliveryTick(context)
        }
    }
}

extension SystemMessageRedeliveryHandler {
    /// Optional "dump all messages" logging.
    private func tracelog(
        _ type: TraceLogType, message: Any,
        file: String = #file, function: String = #function, line: UInt = #line
    ) {
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

/// Deserializes and delivers user messages (i.e. anything that is not a system message).
private final class UserMessageHandler: ChannelInboundHandler {
    typealias InboundIn = Wire.Envelope
    typealias InboundOut = Never // we terminate here, by sending messages off to local actors

    let log: Logger

    let system: ActorSystem
    let serializationPool: SerializationPool

    init(log: Logger, system: ActorSystem, serializationPool: SerializationPool) {
        self.log = log
        self.system = system
        self.serializationPool = serializationPool
    }

    /// This ends the processing chain for incoming messages.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.deserializeThenDeliver(context, wireEnvelope: self.unwrapInboundIn(data))
    }

    private func deserializeThenDeliver(_ context: ChannelHandlerContext, wireEnvelope: Wire.Envelope) {
        // It is OF CRUCIAL IMPORTANCE that we do not accidentally attempt to deserialize an `Any.Type`.
        // We must ensure that we deserialize using the actual type that was expected by the destination actor.
        // This can be done by obtaining the serializer that is bound to a specific type by using the Manifest.
        //
        // Since we are receiving a message:
        // 1. We must have spawned an actor of this type -- it must have ensured a serializer for this manifest
        // 2. We have ensured a serializer for it otherwise
        // X. We never spawned or registered the serializer and the message shall be dropped

        // 1. Resolve the actor, it MUST be local and MUST contain the actual Message type it expects
        let ref = self.system._resolveUntyped(
            context: .init(address: wireEnvelope.recipient, system: self.system)
        )
        // We resolved "untyped" meaning that we did not take into account the Type of the actor when looking for it.
        // However, the actor ref "inside" has strict knowledge about what specific Message type it is about (!).

        // all other messages are "normal" and should be delivered to the target actor normally
        ref._deserializeDeliver(
            wireEnvelope.payload, using: wireEnvelope.manifest,
            on: self.serializationPool
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
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

                let log = ActorLogger.make(system: system, identifier: "/system/transport.server")

                // FIXME: PASS IN FROM ASSOCIATION SINCE MUST SURVIVE CONNECTIONS! // TODO: tests about killing connections the hard way
                let outboundSysMsgs = OutboundSystemMessageRedelivery(settings: .default)
                let inboundSysMsgs = InboundSystemMessages(settings: .default)

                // TODO: Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                let otherHandlers: [(String?, ChannelHandler)] = [
                    // reads go this way: vvv
                    ("magic validator", ProtocolMagicBytesValidator()),
                    ("framing writer", LengthFieldPrepender(lengthFieldLength: .four, lengthFieldEndianness: .big)),
                    ("framing reader", ByteToMessageHandler(Framing(lengthFieldLength: .four, lengthFieldEndianness: .big))),
                    ("receiving handshake handler", ReceivingHandshakeHandler(log: log, cluster: shell, localNode: bindAddress)),
                    // ("bytes dumper", DumpRawBytesDebugHandler(role: .server, log: log)), // FIXME only include for debug -DSACT_TRACE_NIO things?
                    ("wire envelope handler", WireEnvelopeHandler(log: log)),
                    ("outbound serialization handler", OutboundSerializationHandler(log: log, serializationPool: serializationPool)),
                    ("system message re-delivery", SystemMessageRedeliveryHandler(log: log, system: system, cluster: shell, serializationPool: serializationPool, outbound: outboundSysMsgs, inbound: inboundSysMsgs)),
                    ("actor message handler", UserMessageHandler(log: log, system: system, serializationPool: serializationPool)),
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

                let log = ActorLogger.make(system: system, identifier: "/system/transport.client")

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
                    ("outbound serialization handler", OutboundSerializationHandler(log: log, serializationPool: serializationPool)),
                    ("system message re-delivery", SystemMessageRedeliveryHandler(log: log, system: system, cluster: shell, serializationPool: serializationPool, outbound: outboundSysMsgs, inbound: inboundSysMsgs)),
                    ("actor message handler", UserMessageHandler(log: log, system: system, serializationPool: serializationPool)),
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
        case systemMessage(_SystemMessage)
        // ~~ inbound only ~~
        case systemMessageEnvelope(SystemMessageEnvelope)
        case systemMessageDelivery(SystemMessageDelivery)
    }

    // TODO: we could merge ACK and NACK if NACKs were to carry "the gap"
    enum SystemMessageDelivery {
        case ack(_SystemMessage.ACK)
        case nack(_SystemMessage.NACK)
    }

    let recipient: ActorAddress

    // TODO: carry same data as Envelope -- baggage etc

    init(envelope: Envelope, recipient: ActorAddress) {
        assert(recipient.node != nil, "Attempted to send remote message, though recipient is local! Was envelope: \(envelope), recipient: \(recipient)")
        switch envelope.payload {
        case .message(let message):
            self.storage = .message(message)
        case .closure:
            fatalError("Attempted to send .closure to remote actor, this is illegal and can not be made to work. Envelope: \(envelope), recipient: \(recipient)")
        case .adaptedMessage:
            fatalError("Attempted to send .adaptedMessage to remote actor, this is illegal and can not be made to work. Envelope: \(envelope), recipient: \(recipient)")
        case .subMessage:
            fatalError("Attempted to send .subMessage to remote actor, this is illegal and can not be made to work. Envelope: \(envelope), recipient: \(recipient)")
        }
        self.recipient = recipient
        // TODO: carry metadata from Envelope
    }

    init<Message>(message: Message, recipient: ActorAddress) {
        // assert(Message.self != Any.self)
        self.storage = .message(message)
        self.recipient = recipient
    }

    init(systemMessage: _SystemMessage, recipient: ActorAddress) {
        self.storage = .systemMessage(systemMessage)
        self.recipient = recipient
    }

    init(systemMessageEnvelope: SystemMessageEnvelope, recipient: ActorAddress) {
        self.storage = .systemMessageEnvelope(systemMessageEnvelope)
        self.recipient = recipient
    }

    init(ack: _SystemMessage.ACK, recipient: ActorAddress) {
        self.storage = .systemMessageDelivery(.ack(ack))
        self.recipient = recipient
    }

    init(nack: _SystemMessage.NACK, recipient: ActorAddress) {
        self.storage = .systemMessageDelivery(.nack(nack))
        self.recipient = recipient
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
        "TransportEnvelope(\(storage), recipient: \(String(reflecting: recipient)))"
    }

    var debugDescription: String {
        "TransportEnvelope(_storage: \(storage), recipient: \(String(reflecting: recipient)))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

enum WireFormatError: Error {
    case notEnoughBytes(expectedAtLeastBytes: Int, hint: String?)
}
