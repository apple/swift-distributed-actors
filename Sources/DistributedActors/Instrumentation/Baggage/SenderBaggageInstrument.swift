////===----------------------------------------------------------------------===//
////
//// This source file is part of the Swift Distributed Actors open source project
////
//// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
//// Licensed under Apache License v2.0
////
//// See LICENSE.txt for license information
//// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
////
//// SPDX-License-Identifier: Apache-2.0
////
////===----------------------------------------------------------------------===//
//
// import Baggage
// import Instrumentation
//
// final class SenderBaggageInstrument: InstrumentProtocol {
//    typealias InjectInto = MessageEnvelope
//    typealias ExtractFrom = MessageEnvelope
//
//    // FIXME: do we need branch and merge?
//
//    func extract(from envelope: ExtractFrom, into baggage: inout BaggageContext) {
//        baggage.actorSender = envelope.baggage.actorSender
//    }
//
//    func inject(from baggage: BaggageContext, into envelope: inout InjectInto) {
//        envelope.baggage.actorSender = baggage.actorSender
//    }
// }
