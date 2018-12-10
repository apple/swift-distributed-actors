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

    /// Widens the given
    // FIXME this breaks in face of the recipient trying to watch this ref, we need to forward signals to the origin
    // FIXME see more details in: https://github.com/apple/swift-distributed-actors/issues/40
    public func adapt<From>(with converter: @escaping (From) -> Message) -> ActorRef<From> {
        return ActorRefAdapter(self, converter)
    }
}

// FIXME this is NOT a final solution, has subtle problems around watching and lifecycle (which MUST match the what is being proxied)
// FIXME see more details in: https://github.com/apple/swift-distributed-actors/issues/40
internal final class ActorRefAdapter<From, To>: ActorRef<From> {
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
}
