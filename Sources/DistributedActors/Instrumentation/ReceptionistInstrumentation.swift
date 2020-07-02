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
// MARK: ReceptionistInstrumentation

public protocol ReceptionistInstrumentation {
    init()

    func actorSubscribed(key: AnyReceptionKey, address: ActorAddress)

    func actorRegistered(key: AnyReceptionKey, address: ActorAddress)
    func actorRemoved(key: AnyReceptionKey, address: ActorAddress)

    // TODO: lookup separately?
    func listingPublished(key: AnyReceptionKey, subscribers: Int, registrations: Int)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Noop ReceptionistInstrumentation

struct NoopReceptionistInstrumentation: ReceptionistInstrumentation {
    public init() {}

    func actorSubscribed(key: AnyReceptionKey, address: ActorAddress) {}

    func actorRegistered(key: AnyReceptionKey, address: ActorAddress) {}

    func actorRemoved(key: AnyReceptionKey, address: ActorAddress) {}

    func listingPublished(key: AnyReceptionKey, subscribers: Int, registrations: Int) {}
}
