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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

final class SystemMessagesRedeliveryTests: ActorSystemTestBase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: OutboundSystemMessageRedelivery

    func test_sysMsg_outbound_passThroughWhenNoGapsReported() {
        let outbound = OutboundSystemMessageRedelivery()

        for i in 1 ... (outbound.settings.redeliveryBatchSize + 5) {
            switch outbound.offer(.start, recipient: ._deadLetters) {
            case .send(let envelope):
                envelope.sequenceNr.shouldEqual(self.seqNr(i))

            case let other:
                XCTFail("Expected [.send], was: [\(other)] on i:\(i)")
            }
        }
    }

    func test_sysMsg_outbound_ack_shouldCumulativelyAcknowledge() {
        let outbound = OutboundSystemMessageRedelivery()

        _ = outbound.offer(.start, recipient: ._deadLetters) // 1
        _ = outbound.offer(.start, recipient: ._deadLetters) // 2
        _ = outbound.offer(.start, recipient: ._deadLetters) // 3

        outbound.messagesPendingAcknowledgement.count.shouldEqual(3)

        let res = outbound.acknowledge(self.ack(2))
        guard case .acknowledged = res else {
            XCTFail("Expected [.acknowledged], was: [\(res)]")
            return
        }
        outbound.messagesPendingAcknowledgement.count.shouldEqual(1)
    }

    func test_sysMsg_outbound_ack_shouldIgnoreDuplicateACK() {
        let outbound = OutboundSystemMessageRedelivery()

        _ = outbound.offer(.start, recipient: ._deadLetters) // 1
        _ = outbound.offer(.start, recipient: ._deadLetters) // 2
        _ = outbound.offer(.start, recipient: ._deadLetters) // 3

        let res1 = outbound.acknowledge(self.ack(2))
        guard case .acknowledged = res1 else {
            XCTFail("Expected [.acknowledged], was: [\(res1)]")
            return
        }
        let res2 = outbound.acknowledge(self.ack(2))
        guard case .acknowledged = res2 else {
            XCTFail("Expected [.acknowledged], was: [\(res2)]")
            return
        }
        outbound.messagesPendingAcknowledgement.count.shouldEqual(1)
    }

    func test_sysMsg_outbound_ack_shouldRejectACKAboutFutureSeqNrs() {
        let outbound = OutboundSystemMessageRedelivery()

        _ = outbound.offer(.start, recipient: ._deadLetters) // 1
        _ = outbound.offer(.start, recipient: ._deadLetters) // 2
        _ = outbound.offer(.start, recipient: ._deadLetters) // 3

        let res = outbound.acknowledge(self.ack(4)) // 4 was not sent yet (!)
        guard case .ackWasForFutureSequenceNr(let highestKnownSeqNr) = res else {
            XCTFail("Expected [.ackWasForFutureSequenceNr], was: [\(res)]")
            return
        }
        highestKnownSeqNr.shouldEqual(self.seqNr(3))
        // TODO: expose .metrics which are actual Metrics and write tests against them
        outbound.messagesPendingAcknowledgement.count.shouldEqual(3) // still 3, the ACK was ignored, good
    }

    func test_sysMsg_outbound_ack_thenOfferMore_shouldContinueAtRightSequenceNr() {
        let outbound = OutboundSystemMessageRedelivery()

        _ = outbound.offer(.start, recipient: ._deadLetters) // 1
        _ = outbound.offer(.start, recipient: ._deadLetters) // 2
        _ = outbound.offer(.start, recipient: ._deadLetters) // 3

        _ = outbound.acknowledge(self.ack(1))

        switch outbound.offer(.start, recipient: ._deadLetters) {
        case .send(let envelope):
            envelope.sequenceNr.shouldEqual(SystemMessageEnvelope.SequenceNr(4)) // continue from where we left off
        case let other:
            XCTFail("Expected [.send], was: \(other)")
        }

        _ = outbound.acknowledge(self.ack(4))

        switch outbound.offer(.start, recipient: ._deadLetters) {
        case .send(let envelope):
            envelope.sequenceNr.shouldEqual(SystemMessageEnvelope.SequenceNr(5)) // continue from where we left off
        case let other:
            XCTFail("Expected [.send], was: \(other)")
        }
    }

    func test_sysMsg_outbound_nack_shouldCauseAppropriateRedelivery() {
        let outbound = OutboundSystemMessageRedelivery()

        _ = outbound.offer(.start, recipient: ._deadLetters) // 1
        _ = outbound.offer(.start, recipient: ._deadLetters) // 2
        _ = outbound.offer(.start, recipient: ._deadLetters) // 3

        let res = outbound.negativeAcknowledge(self.nack(1)) // we saw 3 but not 2
        guard case .ensureRedeliveryTick = res else {
            XCTFail("Expected [.ensureRedeliveryTick], was: [\(res)]")
            return
        }
        // TODO: expose .metrics which are actual Metrics and write tests against them
        outbound.messagesPendingAcknowledgement.count.shouldEqual(2) // 2, since 1 was implicitly ACKed by the NACK
    }

    func test_sysMsg_outbound_redeliveryTick_shouldRedeliverPendingMessages() {
        let outbound = OutboundSystemMessageRedelivery()

        _ = outbound.offer(.start, recipient: ._deadLetters) // 1
        _ = outbound.offer(.start, recipient: ._deadLetters) // 2
        _ = outbound.offer(.start, recipient: ._deadLetters) // 3
        // none are ACKed

        switch outbound.onRedeliveryTick() {
        case .redeliver(let envelopes, _):
            envelopes.count.shouldEqual(3)
        case let other:
            XCTFail("Expected [.redeliver], was: \(other)")
        }

        _ = outbound.acknowledge(self.ack(2))
        switch outbound.onRedeliveryTick() {
        case .redeliver(let envelopes, _):
            envelopes.count.shouldEqual(1)
        case let other:
            XCTFail("Expected [.redeliver], was: \(other)")
        }

        _ = outbound.offer(.start, recipient: ._deadLetters) // 4
        switch outbound.onRedeliveryTick() {
        case .redeliver(let envelopes, _):
            envelopes.count.shouldEqual(2)
        case let other:
            XCTFail("Expected [.redeliver], was: \(other)")
        }
    }

    func test_sysMsg_outbound_redelivery_shouldBeLimitedToConfiguredBatchAtMost() {
        var settings: OutboundSystemMessageRedeliverySettings = .default
        settings.redeliveryBatchSize = 3
        let outbound = OutboundSystemMessageRedelivery(settings: settings)

        _ = outbound.offer(.nodeTerminated(.init(systemName: "S", host: "127.0.0.1", port: 111, nid: .random())), recipient: ._deadLetters) // 1
        _ = outbound.offer(.nodeTerminated(.init(systemName: "S", host: "127.0.0.1", port: 222, nid: .random())), recipient: ._deadLetters) // 2
        _ = outbound.offer(.nodeTerminated(.init(systemName: "S", host: "127.0.0.1", port: 333, nid: .random())), recipient: ._deadLetters) // 3
        _ = outbound.offer(.nodeTerminated(.init(systemName: "S", host: "127.0.0.1", port: 444, nid: .random())), recipient: ._deadLetters) // 4
        _ = outbound.offer(.nodeTerminated(.init(systemName: "S", host: "127.0.0.1", port: 555, nid: .random())), recipient: ._deadLetters) // 5
        _ = outbound.offer(.nodeTerminated(.init(systemName: "S", host: "127.0.0.1", port: 666, nid: .random())), recipient: ._deadLetters) // 6
        _ = outbound.offer(.nodeTerminated(.init(systemName: "S", host: "127.0.0.1", port: 777, nid: .random())), recipient: ._deadLetters) // 7
        // none are ACKed

        switch outbound.onRedeliveryTick() {
        case .redeliver(let envelopes, _):
            envelopes.count.shouldEqual(settings.redeliveryBatchSize)
            "\(envelopes.first, orElse: "")".shouldContain("@127.0.0.1:111)")
            "\(envelopes.dropFirst(1).first, orElse: "")".shouldContain("@127.0.0.1:222)")
            "\(envelopes.dropFirst(2).first, orElse: "")".shouldContain("@127.0.0.1:333)")
        case let other:
            XCTFail("Expected [.redeliver], was: \(other)")
        }
    }

    func test_sysMsg_outbound_exceedSendBufferLimit() {
        var settings = OutboundSystemMessageRedeliverySettings()
        settings.redeliveryBufferLimit = 5
        let outbound = OutboundSystemMessageRedelivery(settings: settings)

        _ = outbound.offer(.start, recipient: ._deadLetters) // 1
        _ = outbound.acknowledge(.init(sequenceNr: 1))
        _ = outbound.offer(.start, recipient: ._deadLetters) // buffered: 1
        _ = outbound.offer(.start, recipient: ._deadLetters) // buffered: 2
        _ = outbound.offer(.start, recipient: ._deadLetters) // buffered: 3
        _ = outbound.offer(.start, recipient: ._deadLetters) // buffered: 4
        _ = outbound.offer(.start, recipient: ._deadLetters) // buffered: 5
        let res = outbound.offer(.start, recipient: ._deadLetters) // buffered: 6; oh oh! we'd be over 5 buffered

        guard case .bufferOverflowMustAbortAssociation(let limit) = res else {
            XCTFail("Expected [.bufferOverflowMustAbortAssociation], was: [\(res)]")
            return
        }

        limit.shouldEqual(settings.redeliveryBufferLimit)
    }

    // TODO: test when we exceed the redelivery attempts limit

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: InboundSystemMessages

    func test_inbound_shouldAcceptMessagesInOrder() throws {
        let inboundSystemMessages = InboundSystemMessages()

        for i in 1 ... 32 {
            inboundSystemMessages.onDelivery(self.msg(seqNr: i)).shouldEqual(.accept(self.ack(i)))
        }
    }

    func test_inbound_shouldDetectGap() throws {
        let inbound = InboundSystemMessages()

        inbound.onDelivery(self.msg(seqNr: 1)).shouldEqual(.accept(self.ack(1)))
        inbound.onDelivery(self.msg(seqNr: 2)).shouldEqual(.accept(self.ack(2)))
        // missing 3
        inbound.onDelivery(self.msg(seqNr: 4)).shouldEqual(.gapDetectedRequestRedelivery(self.nack(2))) // missing 3
        inbound.onDelivery(self.msg(seqNr: 5)).shouldEqual(.gapDetectedRequestRedelivery(self.nack(2))) // still missing 3

        // re-deliver the missing 3
        inbound.onDelivery(self.msg(seqNr: 3)).shouldEqual(.accept(self.ack(3))) // accepted 3

        inbound.onDelivery(self.msg(seqNr: 4)).shouldEqual(.accept(self.ack(4))) // accepted 4
    }

    func test_inbound_shouldacceptRedeliveriesOfAlreadyAcceptedSeqNr() throws {
        let inbound = InboundSystemMessages()

        inbound.onDelivery(self.msg(seqNr: 1)).shouldEqual(.accept(self.ack(1)))
        inbound.onDelivery(self.msg(seqNr: 2)).shouldEqual(.accept(self.ack(2)))
        // re-deliver the already accepted 2
        inbound.onDelivery(self.msg(seqNr: 2)).shouldEqual(.acceptRedelivery(self.ack(2)))
        inbound.onDelivery(self.msg(seqNr: 2)).shouldEqual(.acceptRedelivery(self.ack(2)))
        inbound.onDelivery(self.msg(seqNr: 2)).shouldEqual(.acceptRedelivery(self.ack(2)))
        inbound.onDelivery(self.msg(seqNr: 2)).shouldEqual(.acceptRedelivery(self.ack(2)))
        inbound.onDelivery(self.msg(seqNr: 3)).shouldEqual(.accept(self.ack(3)))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Serialization

    func test_redelivery_systemMessage_serialization() throws {
        let system = ActorSystem("\(type(of: self))")
        defer {
            system.shutdown().wait()
        }

        func validateRoundTrip<T: Equatable>(_ value: T) throws {
            try shouldNotThrow {
                var (manifest, bytes) = try system.serialization.serialize(value)
                let back = try system.serialization.deserialize(as: T.self, from: &bytes, using: manifest)

                back.shouldEqual(value)
            }
        }

        try validateRoundTrip(_SystemMessage.ACK(sequenceNr: 1337))
        try validateRoundTrip(_SystemMessage.NACK(sequenceNr: 1337))
        let ref = system.deadLetters.asAddressable()
        try validateRoundTrip(SystemMessageEnvelope(sequenceNr: 1337, message: .watch(watchee: ref, watcher: ref)))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Utilities

    private func msg(seqNr: Int) -> SystemMessageEnvelope {
        // Note: in reality .start would NEVER be sent around and we do not define any serialization for it on purpose
        // but it is a nice simple message to use as our payload for tests here; the queues don't mind.
        return .init(sequenceNr: seqNr, message: .start)
    }

    private func ack(_ seqNr: Int) -> _SystemMessage.ACK {
        return _SystemMessage.ACK(sequenceNr: seqNr)
    }

    private func nack(_ seqNr: Int) -> _SystemMessage.NACK {
        return _SystemMessage.NACK(sequenceNr: seqNr)
    }

    private func seqNr(_ i: Int) -> SystemMessageEnvelope.SequenceNr {
        return SystemMessageEnvelope.SequenceNr(i)
    }
}

extension OutboundSystemMessageRedelivery {
    convenience init() {
        self.init(settings: .default)
    }
}

extension InboundSystemMessages {
    convenience init() {
        self.init(settings: .default)
    }
}
