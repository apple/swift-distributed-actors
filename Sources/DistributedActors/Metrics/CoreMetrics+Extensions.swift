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

import Dispatch
import DistributedActorsConcurrencyHelpers
import Metrics

extension CoreMetrics.Timer {
    /// Records time interval between the passed in `since` dispatch time and `now`.
    func recordInterval(since: DispatchTime?, now: DispatchTime = .now()) {
        if let since = since {
            self.recordNanoseconds(now.uptimeNanoseconds - since.uptimeNanoseconds)
        }
    }
}
