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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Settings

public struct SWIMSettings {

    public static var `default`: SWIMSettings {
        return .init()
    }

    /// Optional "SWIM instance name" to be included in log statements,
    /// useful when multiple instances of SWIM are run on the same process (e.g. for debugging).
    var name: String?

    // var timeSource: TimeSource // TODO would be nice?

    var gossip: SWIMGossipSettings = .default

    var failureDetector: SWIMFailureDetectorSettings = .default

}

extension SWIM {
    public typealias Settings = SWIMSettings
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossip Settings

public struct SWIMGossipSettings {

    public static var `default`: SWIMGossipSettings {
        return .init()
    }

    /// Interval at which gossip messages should be issued.
    /// Every `interval` a `fanout` number of gossip messages will be sent.
    var probeInterval: TimeAmount = .milliseconds(300)

    // FIXME: investigate size of messages and find good default
    //
    // max number of messages included in any gossip payload
    var maxNumberOfMessages: Int = 20

    var maxGossipCountPerMessage: Int = 6
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: FailureDetector Settings

public struct SWIMFailureDetectorSettings {

    public static var `default`: SWIMFailureDetectorSettings {
        return .init()
    }

    /// Number of indirect probes that will be issued once a direct ping probe has failed to reply in time with an ack.
    ///
    /// In case of small clusters where nr. of neighbors is smaller than this value, the most neighbors available will
    /// be asked to issue an indirect probe. E.g. a 3 node cluster, configured with `indirectChecks = 3` has only `1`
    /// remaining node it can ask for an indirect probe (since 1 node is ourselves, and 1 node is the potentially suspect node itself).
    var indirectProbeCount: Int = 3 {
        willSet {
            precondition(newValue >= 0, "`indirectChecks` MUST NOT be < 0. It is recommended to have it be no lower than 3.")
        }
    }

    // FIXME: those timeouts are not the actual timeout, the actual timeout is recalculated each time when we get more `suspect` information

    /// Suspicion timeouts are specified as number of probe intervals. E.g. a `probeInterval`
    /// of 300 milliseconds and `suspicionTimeoutMax` means that a suspicious node will be
    /// marked `.dead` after approx. 900ms.
    var suspicionTimeoutMax: Int = 3
    var suspicionTimeoutMin: Int = 3

    var probeInterval: TimeAmount = .milliseconds(300)
    var pingTimeout: TimeAmount = .milliseconds(100)
}
