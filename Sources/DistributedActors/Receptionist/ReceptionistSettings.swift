//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public struct ReceptionistSettings {
    public static var `default`: ReceptionistSettings {
        .init()
    }

    /// In order to avoid high churn when thousands of actors are registered (or removed) at once,
    /// listing notifications are sent after a pre-defined delay.
    ///
    /// This optimizes for the following scenario:
    /// When a group of registered actors terminates they all will be removed from the receptionist via their individual
    /// Terminated singles being received by the receptionist. The receptionist will want to update any subscribers to keys
    /// that those terminated actors were registered with. However if it were to eagerly push updated listings for each received
    /// terminated signal this could cause a lot of message traffic, i.e. a listing with 100 actors, followed by a listing with 99 actors,
    /// followed by a listing with 98 actors, and so on. It is more efficient, and equally as acceptable for listing updates to rather
    /// be delayed for moments, and the listing then be flushed with the updated listing, saving a lot of collection copies as a result.
    ///
    /// The same applies for spawning thousands of actors at once which are all registering themselves with a key upon spawning.
    /// It is more efficient to sent a bulk updated listing to other peers rather than it is to send thousands of one by one
    /// updated listings.
    ///
    /// Note that this also makes the "local" receptionist "feel like" the distributed one, where there is a larger delay in
    /// spreading the information between peers. In a way, this is desirable -- if two actors necessarily need to talk to one another
    /// as soon as possible they SHOULD NOT be using the receptionist to discover each other, but should rather know about each other
    /// thanks to e.g. one of them being "well known" or implementing a direct "introduction" pattern between them.
    ///
    /// The simplest pattern to introduce two actors is to have one be the parent of the other, then the parent can
    /// _immediately_ send messages to the child, even as it's still being started.
    public var listingFlushDelay: TimeAmount = .milliseconds(250)
}
