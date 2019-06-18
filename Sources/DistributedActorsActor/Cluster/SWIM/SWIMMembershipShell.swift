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

/// TODO ...
internal enum SWIMMembershipShell {

    public static let name: String = "membership-swim" // TODO String -> ActorName

    struct Gossip {
        // TODO: keep around prio-queue here to "what to send"
        // TODO: keep around "where to send" if we do round robin, or random generator for random
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Behaviors

    // TODO: Behaviors are interpreters of the fd-state-machine, they interpret and issue message sends etc

    public static func behavior(_ settings: SWIM.Settings, observer: FailureObserver) -> Behavior<SWIM.Message> {
        return .setup { context in

            // when we decide a node is "really down" we should trigger, etc:
            //
            // so we have the system reacting to the membership changes IN the system, and the detection is on the side and just lets it know
            // this way we can plug in any other failure detector -- also based on something external or whichever people want.
            //
            // observer.onMembershipChanged(.init(member: someone, toStatus: .down))

            return .same
        }
    }

}

extension SWIM {
    typealias MembershipShell = SWIMMembershipShell
}
