//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _PrettyLogHandler
import Distributed
import DistributedCluster
import Logging
import NIO
import OpenTelemetry
import OtlpGRPCSpanExporting
import Tracing

// TODO: we want to support "member roles" in membership, this would be then a built in query, and not hardcoded by port either.
extension ClusterSystem {
    var isBuildLeader: Bool {
        self.cluster.endpoint.port == 7330
    }

    var isBuildWorker: Bool {
        self.cluster.endpoint.port > 7330
    }
}
