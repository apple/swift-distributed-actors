//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Baggage
import Instrumentation

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: baggage.senderActorAddress

enum SenderActorAddressKey: BaggageContextKey {
    typealias Value = ActorAddress
    static let name = "actor/sender"
}

extension BaggageContext {
    /// When handling an actor message, indicates the sender of that message.
    /// Can be used to debug and track simple 1:1 interactions between actors, including ask messages and Actorable calls.
    public var actorSender: ActorAddress? {
        get {
            self[SenderActorAddressKey.self]
        }
        set {
            self[SenderActorAddressKey.self] = newValue
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: baggage.actorContext

enum ActorContextKey: BaggageContextKey {
    typealias Value = AnyActorContext
    static let name = "actor/context"
}

extension BaggageContext {
    var actorContext: AnyActorContext? {
        get {
            self[ActorContextKey.self]
        }
        set {
            self[ActorContextKey.self] = newValue
        }
    }
}
