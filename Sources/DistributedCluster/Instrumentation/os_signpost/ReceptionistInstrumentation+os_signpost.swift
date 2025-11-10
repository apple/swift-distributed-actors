//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS) || os(visionOS)
import Foundation
import os.log
import os.signpost

@available(OSX 10.14, *)
@available(iOS 12.0, *)
@available(tvOS 12.0, *)
@available(watchOS 3.0, *)
internal struct OSSignpostReceptionistInstrumentation: _ReceptionistInstrumentation {
    static let subsystem: StaticString = "com.apple.actors"

    static let category: StaticString = "Receptionist"

    static let nameRegistered: StaticString = "Registered"
    static let nameSubscribed: StaticString = "Subscribed"
    static let nameRemoved: StaticString = "Removed"
    static let namePublished: StaticString = "Published"

    static let log = OSLog(subsystem: "\(Self.subsystem)", category: "\(Self.category)")

    init() {}
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrumentation: Receptionist

@available(OSX 10.14, *)
@available(iOS 12.0, *)
@available(tvOS 12.0, *)
@available(watchOS 3.0, *)
extension OSSignpostReceptionistInstrumentation {
    static let subscribedFormat: StaticString =
        """
        sub;\
        key:%{public}s;\
        type:%{public}s
        """

    func actorSubscribed(key: AnyReceptionKey, id: ActorID) {
        guard Self.log.signpostsEnabled else {
            return
        }

        os_signpost(
            .event,
            log: Self.log,
            name: Self.nameSubscribed,
            signpostID: .exclusive,
            Self.subscribedFormat,
            "\(key.id)",
            "\(key.guestType)"
        )
    }

    static let registeredFormat: StaticString =
        """
        reg;\
        key:%{public}s;\
        type:%{public}s
        """

    func actorRegistered(key: AnyReceptionKey, id: ActorID) {
        guard Self.log.signpostsEnabled else {
            return
        }

        os_signpost(
            .event,
            log: Self.log,
            name: Self.nameRegistered,
            signpostID: .exclusive,
            Self.registeredFormat,
            "\(key.id)",
            "\(key.guestType)"
        )
    }

    static let removedFormat: StaticString =
        """
        rm;\
        key:%{public}s;\
        type:%{public}s
        """

    func actorRemoved(key: AnyReceptionKey, id: ActorID) {
        guard Self.log.signpostsEnabled else {
            return
        }

        os_signpost(
            .event,
            log: Self.log,
            name: Self.nameRemoved,
            signpostID: .exclusive,
            Self.removedFormat,
            "\(key.id)",
            "\(key.guestType)"
        )
    }

    static let listingPublishedFormat: StaticString =
        """
        pub;\
        key:%{public}s;\
        type:%{public}s;\
        subs:%{public}ld;\
        regs:%{public}ld
        """

    func listingPublished(key: AnyReceptionKey, subscribers: Int, registrations: Int) {
        guard Self.log.signpostsEnabled else {
            return
        }

        os_signpost(
            .event,
            log: Self.log,
            name: Self.namePublished,
            signpostID: .exclusive,
            Self.listingPublishedFormat,
            "\(key.id)",
            "\(key.guestType)",
            subscribers,
            registrations
        )
    }
}
#endif
