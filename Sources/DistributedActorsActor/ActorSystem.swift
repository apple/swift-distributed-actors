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

public final class ActorSystem {

    private let name: String

    public init(_ name: String) {
        self.name = name
    }

    public convenience init() {
        self.init("UnnamedActorSystem")
    }

}

protocol ActorRefFactory {
    func spawn<Message>(_ props: Props<Message>, named name: String) -> ActorRef<Message>
}

struct Props<Message> {

}

struct ActorRef<Message> {

}