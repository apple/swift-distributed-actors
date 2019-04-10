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

extension ActorRef {

    /// Adapts this `ActorRef` to accept messages of another type by applying the conversion function
    public func adapt<From>(with converter: @escaping (From) -> Message) -> ActorRef<From> {
        return ActorRefAdapter(self, converter)
    }

    /// Adapts this `ActorRef` to accept messages of another type by applying the conversion function
    public func adapt<From>(from: From.Type, with converter: @escaping (From) -> Message) -> ActorRef<From> {
        return ActorRefAdapter(self, converter)
    }
}

internal final class ActorRefAdapter<From, To>: ActorRef<From>, AdaptedActorRef {
    private let ref: ActorRef<To>
    private let converter: (From) -> To

    init(_ ref: ActorRef<To>, _ converter: @escaping (From) -> To) {
        self.ref = ref
        self.converter = converter
    }

    override var path: UniqueActorPath {
        return ref.path
    }

    override func tell(_ message: From) {
        ref.tell(converter(message))
    }

    var _receivesSystemMessages: BoxedHashableAnyReceivesSystemMessages {
        return ref._boxAnyReceivesSystemMessages()
    }
}

internal protocol AdaptedActorRef {
    var _receivesSystemMessages: BoxedHashableAnyReceivesSystemMessages { get }
}
