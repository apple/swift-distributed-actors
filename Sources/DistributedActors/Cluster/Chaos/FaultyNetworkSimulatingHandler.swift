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

import Logging
import NIO

/// Handler which simulates selective messages being lost or delayed.
/// Can be used to simulate system operation on bad network; useful for testing re-deliveries,
/// eventually consistent data-structures or consensus algorithms in face of lost messages.
internal final class FaultyNetworkSimulatingHandler: ChannelDuplexHandler {
    typealias InboundIn = Wire.Envelope
    typealias InboundOut = TransportEnvelope
    typealias OutboundIn = TransportEnvelope
    typealias OutboundOut = TransportEnvelope

    private let log: Logger
    private let settings: FaultyNetworkSimulationSettings

    /// The gremlin is responsible for dropping or delaying messages as defined by the configured mode.
    // TODO: in the future it can get more stateful behaviors if we wanted to or separate inbound/outbound etc.
    ///
    /// "But the most important rule, [...] no matter how much he begs, never feed him after midnight."
    private let gremlin: Gremlin

    struct Gremlin {
        let settings: FaultyNetworkSimulationSettings

        func decide() -> GremlinDirective {
            let randomNumber = Double.random(in: 0.0 ... 1.0)

            switch self.settings.mode {
            case .drop(let p):
                return randomNumber < p ? .drop : .passThrough
            }
        }

        enum GremlinDirective {
            case drop // also known as 'eat' the message
            case passThrough
        }
    }

    init(log: Logger, settings: FaultyNetworkSimulationSettings) {
        self.log = log
        self.gremlin = Gremlin(settings: settings)
        self.settings = settings
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)

        switch self.gremlin.decide() {
        case .drop:
            self.log.log(level: self.settings.logLevel, "[faulty-network] IN  \(self.settings.effectiveLabel) \(self.settings.formatMessage(message))")
        case .passThrough:
            context.fireChannelRead(data)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        pprint("WRITE data = \(data)")
        let message = self.unwrapOutboundIn(data)

        switch self.gremlin.decide() {
        case .drop:
            self.log.log(level: self.settings.logLevel, "[faulty-network] OUT \(self.settings.effectiveLabel) \(self.settings.formatMessage(message))")
        case .passThrough:
            context.write(data, promise: promise)
        }
    }
}

internal struct FaultyNetworkSimulationSettings {
    enum Mode {
        /// Drop messages with given probability
        case drop(probability: Double)

        // case delay
        // TODO: When `delay`, we have to be careful not to change ordering of the messages, meaning that if delayed, then all following messages have to be delayed as well.
    }

    /// Mode in which the gremlin shall interfere with the communication.
    var mode: Mode

    /// Transform the message before logging it when it is being dropped or delayed.
    var formatMessage: (Any) -> Any = { any in
        any
    }

    /// String added before the output but after IN or OUT when a delay/drop is directed.
    var label: String?
    var effectiveLabel: String {
        if let l = self.label {
            return l
        }
        switch self.mode {
        case .drop:
            return "(DROP)"
        }
    }

    /// At what level should all DROP or similar operations be logged?
    var logLevel: Logger.Level?

    init(mode: Mode) {
        self.mode = mode
    }
}

internal final class TransportToWireInboundHandler: ChannelInboundHandler {
    typealias InboundIn = TransportEnvelope
    typealias InboundOut = Wire.Envelope

    let system: ActorSystem

    init(_ system: ActorSystem) {
        self.system = system
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let transportEnvelope = self.unwrapInboundIn(data)

        let (manifest, buffer) = try! self.system.serialization.serialize(transportEnvelope.underlyingMessage)
        let wireEnvelope = Wire.Envelope(recipient: transportEnvelope.recipient, payload: buffer, manifest: manifest)

        context.fireChannelRead(self.wrapInboundOut(wireEnvelope))
    }
}
