//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-distributed-actors open source project
//
// Copyright (c) 2022 Apple Inc. and the swift-distributed-actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of swift-distributed-actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedCluster

public struct MultiNodeTestSettings {
    public init() {}

    /// Total deadline for an 'exec' run of a test to complete running.
    /// After this deadline is exceeded the process is KILLED, harshly, without any error collecting or reporting.
    /// This is to prevent hanging nodes/tests lingering around.
    public var execRunHardTimeout: Duration = .seconds(120)

    /// Install a pretty print logger which prints metadata as multi-line comment output and also includes source location of log statements
    public var installPrettyLogger: Bool = false

    /// How long to wait after the node process has been initialized,
    /// and before initializing the actor system on the child system.
    ///
    /// Useful when necessary to attach a debugger to a process before
    /// kicking off the actor system etc.
    public var waitBeforeBootstrap: Duration? = .seconds(10)

    /// How long the initial join of the nodes is allowed to take.
    public var initialJoinTimeout: Duration = .seconds(30)

    public var logCapture: MultiNodeLogCaptureSettings = .init()
    public struct MultiNodeLogCaptureSettings {
        /// Do not capture log messages which include the following strings.
        public var excludeGrep: Set<String> = []
    }

    /// Configure when to dump logs from nodes
    public var dumpNodeLogs: DumpNodeLogSettings = .onFailure
    public enum DumpNodeLogSettings {
        case onFailure
        case always
    }

    /// Wait time on entering a ``MultiNode/Checkpoint``.
    /// After exceeding the allocated wait time, all waiters are failed.
    ///
    /// I.e. "all nodes must reach this checkpoint within 30 seconds".
    public var checkPointWaitTime: Duration = .seconds(30)
}
