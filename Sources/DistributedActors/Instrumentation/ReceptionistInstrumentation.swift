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
// MARK: _ReceptionistInstrumentation

protocol _ReceptionistInstrumentation: Sendable {
    init()

    func actorSubscribed(key: AnyReceptionKey, id: ActorID)

    func actorRegistered(key: AnyReceptionKey, id: ActorID)
    func actorRemoved(key: AnyReceptionKey, id: ActorID)

    // TODO: lookup separately?
    func listingPublished(key: AnyReceptionKey, subscribers: Int, registrations: Int)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Noop ReceptionistInstrumentation

struct NoopReceptionistInstrumentation: _ReceptionistInstrumentation {
    public init() {}

    func actorSubscribed(key: AnyReceptionKey, id: ActorID) {}

    func actorRegistered(key: AnyReceptionKey, id: ActorID) {}

    func actorRemoved(key: AnyReceptionKey, id: ActorID) {}

    func listingPublished(key: AnyReceptionKey, subscribers: Int, registrations: Int) {}
}
