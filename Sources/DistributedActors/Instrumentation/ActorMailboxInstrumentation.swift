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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorMailboxInstrumentation

// TODO: all these to accept trace context or something similar
public protocol ActorMailboxInstrumentation {
    init(id: AnyObject, address: ActorAddress)

    func actorMailboxRunStarted(mailboxCount: Int)
    func actorMailboxRunCompleted(processed: Int, error: Error?)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Noop ActorMailboxInstrumentation

struct NoopActorMailboxInstrumentation: ActorMailboxInstrumentation {
    public init(id: AnyObject, address: ActorAddress) {}

    public func actorMailboxRunStarted(mailboxCount: Int) {}

    public func actorMailboxRunCompleted(processed: Int, error: Error?) {}
}
