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
// MARK: ActorInstrumentation

// TODO: all these to accept trace context or something similar
public protocol ActorInstrumentation {
    init(id: AnyObject, address: ActorAddress)

    func actorSpawned()
    func actorStopped()
    func actorFailed(failure: Supervision.Failure)

    func actorTold(message: Any, from: ActorAddress?)

    // TODO: Those read bad, make one that is from/to in params?
    func actorAsked(message: Any, from: ActorAddress?)
    func actorAskReplied(reply: Any?, error: Error?)

    func actorReceivedStart(message: Any, from: ActorAddress?)
    func actorReceivedEnd(error: Error?)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Noop ActorInstrumentation

struct NoopActorInstrumentation: ActorInstrumentation {
    public init(id: AnyObject, address: ActorAddress) {}

    public func actorSpawned() {}

    public func actorStopped() {}

    public func actorFailed(failure: Supervision.Failure) {}

    public func actorMailboxRunStarted(mailboxCount: Int) {}

    public func actorMailboxRunCompleted(processed: Int) {}

    public func actorTold(message: Any, from: ActorAddress?) {}

    public func actorAsked(message: Any, from: ActorAddress?) {}

    public func actorAskReplied(reply: Any?, error: Error?) {}

    public func actorReceivedStart(message: Any, from: ActorAddress?) {}

    public func actorReceivedEnd(error: Error?) {}
}
