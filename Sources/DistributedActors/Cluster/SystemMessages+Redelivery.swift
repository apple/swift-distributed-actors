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

import Foundation
import Logging
import struct NIO.CircularBuffer

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Re-Delivery queues

/// Embedded inside a `MessageEnvelope` when pushing through the transport pipeline.
///
/// Carries increasing sequence number (generation of which is done by `OutboundSystemMessageRedelivery`),
/// which is used to drive re-delivery of system messages. System messages MUST NOT be dropped, and MUST
/// be delivered in order, thus the re-delivery and local-delivery to the target actors is always done in
/// sequence and without gaps. Redelivery also survives if a connection is borked and established anew with
/// the same `UniqueNode`.
///
/// Sequence numbers start from `1`, since zero is reserved for "no system messages were received/sent yet."
///
/// System Messages are wrapped like the following on the wire:
///
/// ```
/// +----------------------------------------------------------+
/// |  MessageEnvelope (Recipient, Baggage, ...)               |
/// |                                                          |
/// |+--------------------------------------------------------+|
/// ||  SystemMessageEnvelope (Seq. Nr)                       ||
/// ||+------------------------------------------------------+||
/// |||  System Message (Payload)                            |||
/// ||+------------------------------------------------------+||
/// |+--------------------------------------------------------+|
/// +----------------------------------------------------------+
/// ```
internal struct SystemMessageEnvelope: Equatable {
    typealias SequenceNr = UInt64

    // Actual messages start with sequence nr >= 1
    let sequenceNr: SequenceNr
    let message: _SystemMessage
    // TODO: association id for logging?

    init(sequenceNr: SequenceNr, message: _SystemMessage) {
        self.sequenceNr = sequenceNr
        self.message = message
    }

    init(sequenceNr: Int, message: _SystemMessage) {
        assert(sequenceNr > 0, "sequenceNr MUST be > 0")
        self.init(sequenceNr: SequenceNr(sequenceNr), message: message)
    }
}

extension SystemMessageEnvelope {
    internal static let metaType: MetaType<SystemMessageEnvelope> = MetaType(SystemMessageEnvelope.self)
}

extension _SystemMessage {
    /// ACKnowledgement -- sent by the receiving end for every (or coalesced) received system message.
    ///
    /// The carried `sequenceNr` indicates the "last correctly observed message"
    struct ACK: Equatable {
        typealias SequenceNr = SystemMessageEnvelope.SequenceNr
        let sequenceNr: SequenceNr

        init(sequenceNr: SequenceNr) {
            self.sequenceNr = sequenceNr
        }

        init(sequenceNr: Int) {
            assert(sequenceNr > 0, "sequenceNr MUST BE > 0")
            self.sequenceNr = SequenceNr(sequenceNr)
        }

        /// Coalesce ("merge") two ACKs into one cumulative ACK up until the larger sequence number carried by either of them.
        func coalesce(_ other: ACK) -> ACK {
            return .init(sequenceNr: max(self.sequenceNr, other.sequenceNr))
        }
    }

    /// Negative ACKnowledgement -- sent by receiving end when it notices a gap in communication
    ///
    /// The carried `sequenceNr` indicates the "last correctly observed message" (inclusive),
    /// and is used to request all subsequent messages to be redelivered by the sender.
    struct NACK: Equatable {
        internal static let metaType: MetaType<NACK> = MetaType(NACK.self)

        typealias SequenceNr = SystemMessageEnvelope.SequenceNr
        let sequenceNr: SequenceNr

        init(sequenceNr: SequenceNr) {
            self.sequenceNr = sequenceNr
        }

        init(sequenceNr: Int) {
            assert(sequenceNr > 0, "sequenceNr MUST be > 0")
            self.sequenceNr = SequenceNr(sequenceNr)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Outbound Re-Delivery

internal final class OutboundSystemMessageRedelivery {
    typealias ACK = _SystemMessage.ACK
    typealias NACK = _SystemMessage.NACK
    typealias SequenceNr = SystemMessageEnvelope.SequenceNr

    // guaranteed to contain SystemMessageEnvelope but we also need the recipients which are in MessageEnvelope
    var messagesPendingAcknowledgement: NIO.CircularBuffer<TransportEnvelope> = .init(initialCapacity: 8)

    // TODO: metrics

    // highest ACK we got back from the receiving end
    var highestAcknowledgedSeqNr: SequenceNr = 0 // 0 == no ACKs at all so far.

    // what is the highest SeqNr we have sent?
    var outgoingSequenceNr: SequenceNr = 0

    var redeliveryTicksSinceLastACK = 0

    let settings: OutboundSystemMessageRedeliverySettings

    var redeliveryIntervalBackoff: ConstantBackoffStrategy

    init(settings: OutboundSystemMessageRedeliverySettings) {
        self.settings = settings
        self.redeliveryIntervalBackoff = settings.makeRedeliveryBackoff
    }

    func offer(_ message: _SystemMessage, recipient: ActorAddress) -> OfferedDirective {
        // Are we able to buffer this message?
        let nrOfMessagesPendingAcknowledgement = self.messagesPendingAcknowledgement.count
        guard nrOfMessagesPendingAcknowledgement < self.settings.redeliveryBufferLimit else {
            return .bufferOverflowMustAbortAssociation(nrOfMessagesPendingAcknowledgement)
        }

        self.outgoingSequenceNr += 1
        let systemEnvelope = SystemMessageEnvelope(sequenceNr: self.outgoingSequenceNr, message: message)
        let messageEnvelope = TransportEnvelope(systemMessageEnvelope: systemEnvelope, recipient: recipient)

        self.messagesPendingAcknowledgement.append(messageEnvelope)
        self.outgoingSequenceNr = systemEnvelope.sequenceNr
        return .send(systemEnvelope)
    }

    enum OfferedDirective {
        /// Send the following envelope
        case send(SystemMessageEnvelope)
        /// CRITICAL ISSUE: The outgoing system message buffer has overflown and we are not able to ensure system message consistency anymore!
        case bufferOverflowMustAbortAssociation(Int)
    }

    func acknowledge(_ ack: ACK) -> AcknowledgeDirective {
        guard ack.sequenceNr <= self.outgoingSequenceNr else {
            // this is weird; we got an ACK for a higher sequence number than we ever sent to the node;
            return .ackWasForFutureSequenceNr(highestKnownSeqNr: self.outgoingSequenceNr)
        }

        let previouslyACKedToSeqNr = highestAcknowledgedSeqNr
        self.highestAcknowledgedSeqNr = ack.sequenceNr

        // realistically this diff will always be in Int range:
        let nrOfMessagesAckedByThisAck = Int(self.highestAcknowledgedSeqNr - previouslyACKedToSeqNr)

        self.messagesPendingAcknowledgement.removeFirst(nrOfMessagesAckedByThisAck)

        return .acknowledged
    }

    enum AcknowledgeDirective {
        // ACKed and nothing else to do; nothing to re-send
        case acknowledged
        case ackWasForFutureSequenceNr(highestKnownSeqNr: SequenceNr)
    }

    func negativeAcknowledge(_ nack: NACK) -> NegativeAcknowledgeDirective {
        guard nack.sequenceNr <= self.outgoingSequenceNr else {
            // this is weird; we got an NACK for a higher sequence number than we ever sent to the node;
            return .nackWasForFutureSequenceNr(highestKnownSeqNr: self.outgoingSequenceNr)
        }

        if self.messagesPendingAcknowledgement.isEmpty {
            return .nothingToReDeliver
        }

        // a NACK has the same effect as an ACK, in the sense that it acks all messages until the "last seen" sequence number.
        // we reuse the acknowledge implementation as it will do the right thing.
        let fakeAck = ACK(sequenceNr: nack.sequenceNr)
        _ = self.acknowledge(fakeAck)

        // TODO: we COULD aggressively re-deliver right now here though this is only an optimization
        // and would be nicer to do if we knew exactly what messages got lost perhaps;
        // rather for now we simply kick off redelivery which is correct and good enough

        return .ensureRedeliveryTick(self.settings.redeliveryInterval)
    }

    enum NegativeAcknowledgeDirective {
        /// We got a NACK however we don't have anything to send
        /// Realistically this should not happen, as a node that sent a NACK even if it tried to send more ACKs would do so
        /// after the NACK, so it would still take effect and cause us to redeliver here; Though if for some message drop reason it were
        /// to happen, we are safe to ignore it if we have received other ACKs for pending messages already.
        case nothingToReDeliver
        case nackWasForFutureSequenceNr(highestKnownSeqNr: SequenceNr)
        /// Ensure that we'll do a redelivery soon; we could also push messages here directly but choose not to:
        /// all redelivered are done on the redelivery tick based intervals.
        case ensureRedeliveryTick(TimeAmount)
    }

    func onRedeliveryTick() -> RedeliveryTickDirective {
        if let error = self.shouldGiveUp() {
            return .giveUpAndSeverTies(error)
        }

        guard let nextTickIn = self.redeliveryIntervalBackoff.next() else {
            // technically we could avoid redelivery timers if we wanted to but it's not realistically worth it, the timers will appear all the time
            fatalError("redeliveryIntervalBackoff yielded no next redelivery time, this MUST NOT happen; re-deliveries must be kept running")
        }

        let redeliveryBatch = self.messagesPendingAcknowledgement.prefix(self.settings.redeliveryBatchSize)
        // TODO: is this a change to coalesce some system messages? what if someone did some silly watching the same exact thing many times?

        return .redeliver(redeliveryBatch, nextTickIn: nextTickIn)
    }

    enum RedeliveryTickDirective {
        /// Redeliver the following redelivery batch and schedule another redelivery tick (if more
        /// Number of elements in the exposed buffer is guaranteed to be <= `settings.redeliveryBatchSize`.
        case redeliver(CircularBuffer<TransportEnvelope>, nextTickIn: TimeAmount)
        /// This is BAD, if we give up on redelivers we HAVE TO sever the association with the remote node (!)
        case giveUpAndSeverTies(Error)
    }

    private func shouldGiveUp() -> GiveUpRedeliveringSystemMessagesError? {
        // ./' ./' ./' Never gonna give you up, never gonna let you down ./' ./' ./'
        // we currently never give up

        //        if self.redeliveryTicksSinceLastACK > self.maxRedeliveryTicksWithoutACK {
        //            return GiveUpRedeliveringSystemMessagesError()
        //        } else {
        return nil
        //        }
    }

    func onReconnected(newAssociationID: Association.AssociatedState) {
        // TODO: redeliver everything
    }

    // We are DONE with this remote node and will never again talk to it again, we shall drop all pending messages.
    func onAssociationRemoved() {
        // FIXME: implement once cluster.down() is available issue #848
    }

    enum AssociationDroppedDirective {
        /// Drain all pending messages as dead letters
        case deadLetter([SystemMessageEnvelope])
    }
}

// TODO: should expose metrics on redeliveries, times and gauges
final class OutboundSystemMessageRedeliveryMetrics {}

struct GiveUpRedeliveringSystemMessagesError: Error {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Inbound

/// Each association has one inbound system message queue.
@usableFromInline
internal class InboundSystemMessages {
    typealias ACK = _SystemMessage.ACK
    typealias NACK = _SystemMessage.NACK
    typealias SequenceNr = SystemMessageEnvelope.SequenceNr

    // TODO: we do not keep any "future" messages and rely on them being re-sent, this is most likely fine (and is in reality in other impls),
    // although we could keep a small buffer in case we'd get single missing msgs.

    /// we expect the first incoming message to be of sequence nr == 1.
    var expectedSequenceNr: SequenceNr = 1

    let settings: InboundSystemMessageRedeliverySettings

    // TODO: accept association id?
    init(settings: InboundSystemMessageRedeliverySettings) {
        self.settings = settings
    }

    func onDelivery(_ envelope: SystemMessageEnvelope) -> InboundSystemMessageArrivalDirective {
        if envelope.sequenceNr == self.expectedSequenceNr {
            // good, just what we expected!
            return self.accept()
        } else if envelope.sequenceNr < self.expectedSequenceNr {
            // neutral, we have already seen this message; it seems to have been re-delivered again
            // perhaps the other side did not receive our previous Ack?
            // Let's let it know again up-until which seqNr we know about already:
            return .acceptRedelivery(ACK(sequenceNr: self.expectedSequenceNr - 1))
        } else {
            assert(envelope.sequenceNr > self.expectedSequenceNr)
            // bad, we're missing a message (!)
            return .gapDetectedRequestRedelivery(NACK(sequenceNr: self.expectedSequenceNr - 1))
        }
    }

    enum InboundSystemMessageArrivalDirective: Equatable {
        case accept(ACK)
        case acceptRedelivery(ACK)
        case gapDetectedRequestRedelivery(NACK)
    }

    private func accept() -> InboundSystemMessageArrivalDirective {
        let ack = ACK(sequenceNr: expectedSequenceNr)
        self.expectedSequenceNr += 1
        return .accept(ack)
    }
}

extension InboundSystemMessages.InboundSystemMessageArrivalDirective {
    static func == (lhs: InboundSystemMessages.InboundSystemMessageArrivalDirective, rhs: InboundSystemMessages.InboundSystemMessageArrivalDirective) -> Bool {
        switch (lhs, rhs) {
        case (.accept(let lack), .accept(let rack)):
            return lack == rack
        case (.acceptRedelivery(let lack), .acceptRedelivery(let rack)):
            return lack == rack
        case (.gapDetectedRequestRedelivery(let lnack), .gapDetectedRequestRedelivery(let rnack)):
            return lnack == rnack
        default:
            return false
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Settings

public struct OutboundSystemMessageRedeliverySettings {
    public static let `default` = OutboundSystemMessageRedeliverySettings()

    /// When enabled, logs all outbound messages using the tracelog facility.
    /// Logs lines will be marked with: [tracelog:sys-msg-redelivery]
    let tracelogLevel: Logger.Level? = nil

    /// Configures the interval at which system messages will be re-delivered if no acknowledgement
    /// is received for them within that timeout.
    ///
    /// A single redelivery "burst" is limited by `redeliveryBurstMax`.
    var redeliveryInterval: TimeAmount = .seconds(1)

    internal var makeRedeliveryBackoff: ConstantBackoffStrategy {
        return Backoff.constant(self.redeliveryInterval)
    }

    /// Configures the maximum number (per association)
    var redeliveryBufferLimit = 10000

    /// Limits the maximum number of messages pushed out on one redelivery tick.
    var redeliveryBatchSize: Int = 500 {
        willSet {
            precondition(newValue > 0, "redeliveryBurstMax MUST be > 0")
        }
    }

    // TODO: not used
    // var maxRedeliveryTicksWithoutACK = 10_000 // TODO settings
}

public struct InboundSystemMessageRedeliverySettings {
    public static let `default` = InboundSystemMessageRedeliverySettings()

    /// When enabled, logs all outbound messages using the tracelog facility.
    /// Logs lines will be marked with: [tracelog:sys-msg-redelivery]
    let tracelogLevel: Logger.Level? = nil
}
