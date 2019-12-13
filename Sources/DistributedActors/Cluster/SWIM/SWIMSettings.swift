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

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Settings

public struct SWIMSettings {
    public static var `default`: SWIMSettings {
        return .init()
    }

    /// Optional "SWIM instance name" to be included in log statements,
    /// useful when multiple instances of SWIM are run on the same process (e.g. for debugging).
    public var name: String?

    // var timeSource: TimeSource // TODO would be nice?

    public var gossip: SWIMGossipSettings = .default

    public var failureDetector: SWIMFailureDetectorSettings = .default

    /// When enabled traces _all_ incoming SWIM protocol communication (remote messages).
    /// These logs will contain SWIM.Instance metadata, as offered by `SWIM.Instance.metadata`.
    /// All logs will be prefixed using `[tracelog:SWIM]`, for easier grepping and inspecting only logs related to the SWIM instance.
    // TODO: how to make this nicely dynamically changeable during runtime
    #if SACT_TRACELOG_SWIM
    public var traceLogLevel: Logger.Level? = .warning
    #else
    public var traceLogLevel: Logger.Level?
    #endif
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
    /// Every `interval` a `fanout` number of gossip messages will be sent. // TODO which fanout?
    public var probeInterval: TimeAmount = .seconds(1)

    // FIXME: investigate size of messages and find good default
    //
    // max number of messages included in any gossip payload
    public var maxNumberOfMessages: Int = 20

    public var maxGossipCountPerMessage: Int = 6
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
    public var indirectProbeCount: Int = 3 {
        willSet {
            precondition(newValue >= 0, "`indirectChecks` MUST NOT be < 0. It is recommended to have it be no lower than 3.")
        }
    }

    // FIXME: those timeouts are not the actual timeout, the actual timeout is recalculated each time when we get more `suspect` information

    /// Suspicion timeouts are specified as number of probe intervals. E.g. a `probeInterval`
    /// of 300 milliseconds and `suspicionTimeoutMax` means that a suspicious node will be
    /// marked `.dead` after approx. 900ms.
    public var suspicionTimeoutPeriodsMax: Int = 10
    public var suspicionTimeoutPeriodsMin: Int = 10

    public var probeInterval: TimeAmount = .seconds(1)
    public var pingTimeout: TimeAmount = .milliseconds(300)
}
