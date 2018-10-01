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

/// An `ActorSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ActorSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
public final class ActorSystem {

    private let name: String

    /// Creates a named ActorSystem; The name is useful for debugging cross system communication
    // TODO /// - throws: when configuration requirements can not be fulfilled (e.g. use of OS specific dispatchers is requested on not-matching OS)
    public init(_ name: String) {
        self.name = name
    }

    public convenience init() {
        self.init("ActorSystem")
    }

}

public protocol ActorRefFactory {

    func spawn<Message>(_ behavior: Behavior<Message>, named name: String, props: Props) -> ActorRef<Message>
}

extension ActorSystem: ActorRefFactory {

    public func spawn<Message>(_ behavior: Behavior<Message>, named name: String, props: Props = Props()) -> ActorRef<Message> {
        return FIXME("implement this")
    }
}

