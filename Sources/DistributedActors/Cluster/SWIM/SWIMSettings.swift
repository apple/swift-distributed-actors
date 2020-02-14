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
        .init()
    }

    // var timeSource: TimeSource // TODO would be nice?

    /// Allows for completely disabling the SWIM distributed failure detector.
    /// - Warning: disabling this means that no reachability events will be created automatically,
    ///   which also means that most `DowningStrategy` implementations will not be able to act and `.down` members!
    ///   Use with great caution, ONLY if you knowingly provide a different method of detecting cluster member node failures.
    public var disabled: Bool = false

    public var gossip: SWIMGossipSettings = .default

    public var failureDetector: SWIMFailureDetectorSettings = .default

    /// Optional "SWIM instance name" to be included in log statements,
    /// useful when multiple instances of SWIM are run on the same node (e.g. for debugging).
    internal var name: String?

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
// MARK: SWIM Gossip Settings

public struct SWIMGossipSettings {
    public static var `default`: SWIMGossipSettings {
        .init()
    }

    // TODO: investigate size of messages and find good default
    /// Max number of messages included in any gossip payload
    public var maxNumberOfMessages: Int = 20

    public var maxGossipCountPerMessage: Int = 6
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM FailureDetector Settings

public struct SWIMFailureDetectorSettings {
    public static var `default`: SWIMFailureDetectorSettings {
        .init()
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

    /// Suspicion timeouts are specified as number of probe intervals.
    /// E.g. a `probeInterval = .milliseconds(300)` and `suspicionTimeoutMin = 3` means that a suspicious node
    /// will be escalated as `.unreachable`  at least after approximately 900ms. Suspicion timeout will decay logarithmically to `suspicionTimeoutPeriodsMin`
    /// with additional confirmations of suspicion arriving. When no additional confrmation present, suspicion timeout will equal `suspicionTimeoutPeriodsMax`
    ///
    /// Once it is confirmed dead by the high-level membership (e.g. immediately, or after an additional grace period, or vote), it will be marked `.dead` in swim,
    /// and `.down` in the high-level membership.
    public var suspicionTimeoutPeriodsMax: Int = 30 {
        willSet {
            precondition(newValue >= self.suspicionTimeoutPeriodsMin, "`suspicionTimeoutPeriodsMax` MUST BE >= `suspicionTimeoutPeriodsMin`")
        }
    }

    /// Suspicion timeouts are specified as number of probe intervals.
    /// E.g. a `probeInterval = .milliseconds(300)` and `suspicionTimeoutPeriodsMax = 3` means that a suspicious node
    /// will be escalated as `.unreachable` at most after approximately 900ms. Suspicion timeout will decay logarithmically from `suspicionTimeoutPeriodsMax`
    /// with additional confirmations of suspicion arriving. When number of confirmations reach `maxIndependentSuspicions`, suspicion timeout will equal `suspicionTimeoutPeriodsMin`
    ///
    /// Once it is confirmed dead by the high-level membership (e.g. immediately, or after an additional grace period, or vote), it will be marked `.dead` in swim,
    /// and `.down` in the high-level membership.
    public var suspicionTimeoutPeriodsMin: Int = 10 {
        willSet {
            precondition(newValue <= self.suspicionTimeoutPeriodsMax, "`suspicionTimeoutPeriodsMin` MUST BE <= `suspicionTimeoutPeriodsMax`")
        }
    }

    /// Interval at which gossip messages should be issued.
    /// Every `interval` a `fanout` number of gossip messages will be sent. // TODO which fanout?
    public var probeInterval: TimeAmount = .seconds(1)

    /// Time amount after which a sent ping without ack response is considered timed-out.
    /// This drives how a node becomes a suspect, by missing such ping/ack rounds.
    ///
    /// Note that after an initial ping/ack timeout, secondary indirect probes are issued,
    /// and only after exceeding `suspicionTimeoutPeriodsMax` shall the node be declared as `.unreachable`,
    /// which results in an `Cluster.MemberReachabilityChange` `Cluster.Event` which downing strategies may act upon.
    public var pingTimeout: TimeAmount = .milliseconds(300)

    /// A Lifegurad suspicion extension to SWIM protocol.
    /// A number of independent suspicions required for a suspicion timeout to fully decay to a minimal value.
    /// When set to 1 will effectively disable LHA-suspicion
    public var maxIndependentSuspicions = 4 {
        willSet {
            precondition(newValue >= 0, "`maxIndependentSuspicions` MUST BE > 0")
        }
    }
}
