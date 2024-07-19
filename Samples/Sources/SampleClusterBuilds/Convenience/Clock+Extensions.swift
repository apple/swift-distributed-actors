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

// Sleep, with adding a little bit of noise (additional delay) to the duration.
func noisySleep(for duration: ContinuousClock.Duration) async {
    var duration = duration + .milliseconds(Int.random(in: 200 ..< 500))
    try? await Task.sleep(until: ContinuousClock.now + duration, clock: .continuous)
}
