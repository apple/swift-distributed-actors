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

import DistributedActors

let system = ActorSystem("SampleReceptionist") { settings in
    settings.cluster.enabled = true
}

extension Reception.Key {
    static var guests: Reception.Key<HotelGuest.Ref> {
        "*"
    }
}

let actors = 10000

enum HotelGuest {
    typealias Ref = _ActorRef<String>

    static var behavior: _Behavior<String> = .setup { context in
        context.receptionist.registerMyself(with: .guests)

        return .receiveMessage { _ in
            .same
        }
    }
}

enum HotelOwner {
    static var behavior: _Behavior<Int> = .receiveMessage { message in
        let guests = try (1 ... message).map { id in
            try system._spawn("guest-\(id)", HotelGuest.behavior)
        }

        return .receive { _, _ in
            .same
        }
    }
}

enum GuestListener {
    static var behavior: _Behavior<Reception.Listing<_ActorRef<String>>> = .setup { context in

        context.receptionist.subscribeMyself(to: .guests)

        let startAll = Deadline.now().uptimeNanoseconds
        var startLast = Deadline.now().uptimeNanoseconds

        return .receiveMessage { listing in
            let stop = Deadline.now().uptimeNanoseconds
            if listing.count % 100 == 0 {
                context.log.info("Listing @ \(listing.count), time since last update: \(TimeAmount.nanoseconds(Int64(stop - startLast)).prettyDescription)")
            }
            startLast = stop

            if listing.count == actors {
                context.log.notice("Listing updated [\(listing.count)] within: \(TimeAmount.nanoseconds(Int64(stop - startAll)).prettyDescription)")
                for ref in listing.refs.prefix(20) {
                    context.log.info("ref: \(ref)")
                }
            }
            return .same
        }
    }
}

try system._spawn("listener", GuestListener.behavior)

let owner = try system._spawn("owner", HotelOwner.behavior)
owner.tell(actors)

Thread.sleep(.seconds(100))

print("~~~~~~~~~~~~~~~ SHUTTING DOWN ~~~~~~~~~~~~~~~")
