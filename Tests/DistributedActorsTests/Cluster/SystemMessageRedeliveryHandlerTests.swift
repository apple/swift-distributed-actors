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
import DistributedActorsTestTools
import Foundation
@testable import Logging
import NIO
import XCTest

final class SystemMessageRedeliveryHandlerTests: XCTestCase {
    var system: ActorSystem!
    var testTools: ActorTestTools!
    var logCaptureHandler: LogCapture!

    var handler: SystemMessageRedeliveryHandler!

    let printLossyNetworkTestLogs = false

    var eventLoop: EmbeddedEventLoop!
    var channel: EmbeddedChannel!
    var remoteControl: AssociationRemoteControl!
    var readRecorder: ReadRecorder!
    var writeRecorder: WriteRecorder!

    let targetAddress = ActorAddress._deadLetters
    let serEnvelope = TransportEnvelope(systemMessage: .start, recipient: ActorAddress._deadLetters)

    override func setUp() {
        self.logCaptureHandler = LogCapture()
        self.system = ActorSystem(String(describing: type(of: self))) { settings in
            settings.overrideLogger = Logger(label: "mock", self.logCaptureHandler)
        }
        self.testTools = ActorTestTools(self.system)

        self.eventLoop = EmbeddedEventLoop()
        self.channel = EmbeddedChannel(loop: self.eventLoop)
        self.readRecorder = ReadRecorder()
        self.writeRecorder = WriteRecorder()

        let outbound = OutboundSystemMessageRedelivery()
        let inbound = InboundSystemMessages()
        if self.printLossyNetworkTestLogs {
            self.handler = SystemMessageRedeliveryHandler(log: self.system.log, cluster: self.system.deadLetters.adapted(), outbound: outbound, inbound: inbound)
        } else {
            self.handler = SystemMessageRedeliveryHandler(log: Logger(label: "mock", self.logCaptureHandler), cluster: self.system.deadLetters.adapted(), outbound: outbound, inbound: inbound)
        }
        /// reads go this way: vvv
        try! shouldNotThrow { try self.channel.pipeline.addHandler(self.writeRecorder).wait() }
        try! shouldNotThrow { try self.channel.pipeline.addHandler(self.handler).wait() }
        try! shouldNotThrow { try self.channel.pipeline.addHandler(self.readRecorder).wait() }
        /// writes go this way: ^^^

        self.remoteControl = AssociationRemoteControl(channel: self.channel, remoteNode: .init(node: .init(systemName: "sys", host: "127.0.0.1", port: 8228), nid: .random()))
    }

    override func tearDown() {
        if let channel = self.channel {
            XCTAssertNoThrow(try channel.finish())
            self.channel = nil
        }
        self.remoteControl = nil
        self.readRecorder = nil
        self.writeRecorder = nil
        self.handler = nil

        self.system.shutdown().wait()
        self.system = nil
        self.testTools = nil
    }

    // NOTE: Most of the re-logic is tested in isolation in `SystemMessagesRedeliveryTests`,
    //      these tests here just make sure we embed it properly in its Shell / Handler.

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: outbound

    func test_systemMessageRedeliveryHandler_sendWithIncreasingSeqNrs() throws {
        for i in 1 ... 5 {
            self.remoteControl.sendSystemMessage(.start, recipient: ._deadLetters)
            let write = try self.expectWrite()

            switch write.storage {
            case .systemMessageEnvelope(let envelope):
                envelope.sequenceNr.shouldEqual(SystemMessageEnvelope.SequenceNr(i))
            case let other:
                XCTFail("Expected .systemMessageEnvelope, but got: \(other)")
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: inbound

    func test_systemMessageRedeliveryHandler_sendACKUponDelivery() throws {
        try self.channel.writeInbound(TransportEnvelope(systemMessageEnvelope: SystemMessageEnvelope(sequenceNr: 1, message: .start), recipient: ._deadLetters))

        let write: TransportEnvelope = try self.expectWrite()
        "\(write)".shouldContain("ACK(") // silly but effective way to check without many lines of unwrapping
    }

    func test_systemMessageRedeliveryHandler_receiveAnACK() throws {
        try self.channel.writeInbound(TransportEnvelope(ack: SystemMessage.ACK(sequenceNr: 1), recipient: ._localRoot))

        // no errors; nothing to assert really
        try self.expectNoWrite()
    }

    func test_systemMessageRedeliveryHandler_receiveAnACKFromFuture() throws {
        try self.channel.writeInbound(TransportEnvelope(ack: SystemMessage.ACK(sequenceNr: 1337), recipient: ._localRoot))

        // should log at trace, but generally considered harmless
        try self.logCaptureHandler.shouldContain(prefix: "Received unexpected system message [ACK(1337)]", at: .warning)
    }

    func test_systemMessageRedeliveryHandler_receiveNACK() throws {
        self.remoteControl.sendSystemMessage(.start, recipient: ._deadLetters) // 1
        self.remoteControl.sendSystemMessage(.start, recipient: ._deadLetters) // 2
        self.remoteControl.sendSystemMessage(.start, recipient: ._deadLetters) // 3

        // we act as if we somehow didn't get the 2 but got the 3:
        try self.channel.writeInbound(TransportEnvelope(nack: SystemMessage.NACK(sequenceNr: 2), recipient: ._localRoot))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Lossy Network

    // Note: realistically on reliable transports such as TCP such aggressive dropping is rather unlikely,
    // however the protocol has to be robust and survive even the worst conditions.
    func test_sysMsgs_onSimulatedLossyNetwork() throws {
        let partnerChannel = EmbeddedChannel(loop: self.eventLoop)
        let partnerReadRecorder = ReadRecorder()
        let partnerWriteRecorder = WriteRecorder()

        let settings = OutboundSystemMessageRedeliverySettings()
        let outbound = OutboundSystemMessageRedelivery(settings: settings)
        let inbound = InboundSystemMessages()
        let system = ActorSystem("                        OtherSystem") // formatting is such specific to align names in printout
        defer { system.shutdown().wait() }
        let handler: SystemMessageRedeliveryHandler
        if self.printLossyNetworkTestLogs {
            handler = SystemMessageRedeliveryHandler(log: system.log, cluster: system.deadLetters.adapted(), outbound: outbound, inbound: inbound)
        } else {
            handler = SystemMessageRedeliveryHandler(log: Logger(label: "mock", self.logCaptureHandler), cluster: system.deadLetters.adapted(), outbound: outbound, inbound: inbound)
        }

        var lossySettings = FaultyNetworkSimulationSettings(mode: .drop(probability: 0.25))
        lossySettings.label = "    (DROP)    :" // formatting is such specific to align names in printout
        let lossyNetwork = FaultyNetworkSimulatingHandler<TransportEnvelope>(log: system.log, settings: lossySettings)

        try! shouldNotThrow { try partnerChannel.pipeline.addHandler(partnerWriteRecorder).wait() }
        try! shouldNotThrow { try partnerChannel.pipeline.addHandler(lossyNetwork).wait() }
        try! shouldNotThrow { try partnerChannel.pipeline.addHandler(handler).wait() }
        try! shouldNotThrow { try partnerChannel.pipeline.addHandler(partnerReadRecorder).wait() }

        var lastDelivered: SystemMessageEnvelope.SequenceNr = 0

        let rounds = 20
        for round in 1 ... rounds {
            self.remoteControl.sendSystemMessage(.start, recipient: ._deadLetters)
            self.interactInMemory(self.channel, partnerChannel)
            if round % 2 == 0 {
                self.eventLoop.advanceTime(by: settings.redeliveryInterval.toNIO)
                self.eventLoop.advanceTime(by: settings.redeliveryInterval.toNIO)
            }
            self.handler.outboundSystemMessages.highestAcknowledgedSeqNr.shouldBeGreaterThanOrEqual(lastDelivered)
            if self.handler.outboundSystemMessages.highestAcknowledgedSeqNr > lastDelivered {
                lastDelivered = self.handler.outboundSystemMessages.highestAcknowledgedSeqNr
                pinfo("Last delivered now at: \(self.handler.outboundSystemMessages.highestAcknowledgedSeqNr)")
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------

    func expectWrite(file: StaticString = #file, line: UInt = #line) throws -> TransportEnvelope {
        guard let write = self.writeRecorder.writes.first else {
            throw self.testTools.fail(file: file, line: line)
        }
        _ = self.writeRecorder.writes.removeFirst()
        return write
    }

    func expectNoWrite(file: StaticString = #file, line: UInt = #line) throws {
        guard self.writeRecorder.writes.isEmpty else {
            throw self.testTools.fail(file: file, line: line)
        }
    }
}

extension XCTestCase {
    /// Have two `EmbeddedChannel` objects send and receive data from each other until they make no forward progress.
    ///
    /// Copied from: https://github.com/apple/swift-nio-http2/blob/0d153b56a43d183dcd9a86108457bec53ec9a9a6/Tests/NIOHTTP2Tests/TestUtilities.swift#L35-L62
    func interactInMemory(_ first: EmbeddedChannel, _ second: EmbeddedChannel, file: StaticString = #file, line: UInt = #line) {
        var operated: Bool

        func readFromChannel(_ channel: EmbeddedChannel) -> TransportEnvelope? {
            return try! channel.readOutbound(as: TransportEnvelope.self)
        }

        repeat {
            operated = false

            if let envelope = readFromChannel(first) {
                operated = true
                XCTAssertNoThrow(try second.writeInbound(envelope), file: file, line: line)
            }

            if let envelope = readFromChannel(second) {
                operated = true
                XCTAssertNoThrow(try first.writeInbound(envelope), file: file, line: line)
            }
        } while operated
    }
}
